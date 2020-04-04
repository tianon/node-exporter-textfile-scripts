#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v smartctl > /dev/null; then
	export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
fi
# "smartctl: command not found"
smartctl --version > /dev/null
# "jq: command not found"
jq --version > /dev/null

# requires at least smartctl 7.0+ for --json (https://www.smartmontools.org/ticket/766)
# requires at least bash 4.4+ (for mapfile)

validate_smartctl_json() {
	# sanity check the smartctl format version
	local json_format_version
	json_format_version="$(jq -r '.json_format_version | map(tostring) | join(".")')" || return 1

	# TODO handle 1.1?  2.0?  need to see what the future holds for smartctl + JSON
	[ "$json_format_version" = '1.0' ] || return 1

	return 0
}

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}
escape_label() {
	sed -e 's/["\\]/\\&/g' -e '$!s/$/\\n/' <<<"$*" | tr -d '\n'
}
labels() {
	local labels=()
	while [ "$#" -ge 2 ]; do
		local label="$1"; shift
		local value="$1"; shift
		value="$(escape_label "$value")" || return 1
		labels+=( "$label=\"$value\"" )
	done
	join ',' "${labels[@]}"
}

devices_json="$(smartctl --nocheck=standby,0 --json=c --scan)"
validate_smartctl_json <<<"$devices_json"

info_labels="$(jq <<<"$devices_json" -r '[
	"version", (.smartctl.version | map(tostring) | join(".")),
	"svn_revision", .smartctl.svn_revision,
	"platform_info", .smartctl.platform_info,
	"build_info", .smartctl.build_info
] | @sh')"
info_labels="$(eval "labels $info_labels")"

echo "smartctl_version{$info_labels} 1"

devices_shell="$(jq -r '.devices[] | .name | @sh' <<<"$devices_json")"
eval "devices=( $devices_shell )"

declare -A info_map=(
	['ata_version']='.ata_version.string'
	['firmware_version']='.firmware_version'
	['form_factor']='.form_factor.name'
	['interface_speed']='.interface_speed.current.string'
	['model_family']='.model_family'
	['model_name']='.model_name'
	['name']='.device.info_name'
	['nvme_controller_id']='.nvme_controller_id'
	['protocol']='.device.protocol'
	['rotation_rate']='.rotation_rate'
	['sata_version']='.sata_version.string'
	['sata_version']='.sata_version.string'
	['serial_number']='.serial_number'
	['type']='.device.type'
	# TODO interface_speed.max.string ?
	# TODO nvme_ieee_oui_identifier?
	# TODO nvme_pci_vendor? (.nvme_pci_vendor.id, .nvme_pci_vendor.subsystem_id)
	# TODO wwn? (.wwn.id, .wwn.naa, .wwn.oui) - https://en.wikipedia.org/wiki/World_Wide_Name
)
mapfile -d '' info_map_keys < <(printf '%s\0' "${!info_map[@]}" | sort -z)

# TODO metrics:
# .ata_smart_data (lots of data)
# .ata_smart_error_log.summary.count (int) -- .revision also??
# .ata_smart_selective_self_test_log
# .ata_smart_self_test_log
# .interface_speed? (how dynamic are these values?)
# .logical_block_size (int, bytes)
# .nvme_namespaces (https://unix.stackexchange.com/a/520256/153467)
# .nvme_smart_health_information_log -- https://www.percona.com/blog/2017/02/09/using-nvme-command-line-tools-to-check-nvme-flash-health/ (useful reference for units)
# .nvme_smart_health_information_log.available_spare_threshold
# .physical_block_size (int, bytes)
# .rotation_rate (int, rpms)
declare -A simple_metrics_map=(
	['nvme_available_spare_ratio']='.nvme_smart_health_information_log.available_spare | values | . / 100'
	['nvme_controller_busy_minutes']='.nvme_smart_health_information_log.controller_busy_time'
	['nvme_critical_temp_minutes']='.nvme_smart_health_information_log.critical_comp_time'
	['nvme_critical_warning']='.nvme_smart_health_information_log.critical_warning' # Critical Warning: This field indicates critical warnings for the state of the controller. Each bit corresponds to a critical warning type; multiple bits may be set. If a bit is cleared to ‘0’, then that critical warning does not apply. Critical warnings may result in an asynchronous event notification to the host. Bits in this field represent the current associated state and are not persistent.
	['nvme_data_read_bytes']='.nvme_smart_health_information_log.data_units_read | values | . * 512000'
	['nvme_data_written_bytes']='.nvme_smart_health_information_log.data_units_written | values | . * 512000'
	['nvme_err_log_entries']='.nvme_smart_health_information_log.num_err_log_entries'
	['nvme_host_reads']='.nvme_smart_health_information_log.host_reads'
	['nvme_host_writes']='.nvme_smart_health_information_log.host_writes'
	['nvme_media_errors']='.nvme_smart_health_information_log.media_errors'
	['nvme_namespaces']='.nvme_number_of_namespaces'
	['nvme_percentage_used_ratio']='.nvme_smart_health_information_log.percentage_used | values | . / 100'
	['nvme_unsafe_shutdowns']='.nvme_smart_health_information_log.unsafe_shutdowns'
	['nvme_warning_temp_minutes']='.nvme_smart_health_information_log.warning_temp_time'
	['power_cycle_count']='.power_cycle_count'
	['power_on_hours']='.power_on_time.hours'
	['smart_status_passed']='.smart_status.passed | values | if . then 1 else 0 end'
	['temperature_celsius']='.temperature.current'
	['user_capacity_blocks']='.user_capacity.blocks'
	['user_capacity_bytes']='.user_capacity.bytes'
)
mapfile -d '' simple_metrics_map_keys < <(printf '%s\0' "${!simple_metrics_map[@]}" | sort -z)

for device in "${devices[@]}"; do
	smartctl=( smartctl --nocheck=standby,0 --json=c --all "$device" )
	if [ ! -r "$device" ]; then
		# opportunistic sudo, when necessary
		smartctl=( sudo "${smartctl[@]}" )
	fi

	echo
	echo "# $device"

	json="$("${smartctl[@]}")" && exit_code=0 || exit_code="$?" # the exit code is non-zero when .smart_status.passed is false 😅
	[ -n "$json" ] || continue
	validate_smartctl_json <<<"$json"

	labels="$(labels device "${device#/dev/}")"

	info_labels="$labels"
	for label_key in "${info_map_keys[@]}"; do
		label_val="$(jq <<<"$json" -r "(${info_map["$label_key"]}) | values")"
		[ -n "$label_val" ] || continue
		label_esc="$(labels "$label_key" "$label_val")"
		info_labels+=",$label_esc"
	done
	echo "smartctl_info{$info_labels} $exit_code"

	for simple_metric_key in "${simple_metrics_map_keys[@]}"; do
		simple_metric_val="$(jq <<<"$json" -r "(${simple_metrics_map["$simple_metric_key"]}) | values")"
		[ -n "$simple_metric_val" ] || continue
		echo "smartctl_$simple_metric_key{$labels} $simple_metric_val"
	done
done
