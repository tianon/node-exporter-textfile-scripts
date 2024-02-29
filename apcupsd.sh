#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v apcaccess > /dev/null; then
	export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
fi
if ! command -v apcaccess > /dev/null; then
	echo >&2 'apcaccess: command not found'
	exit 1
fi

if [ "$#" -eq 0 ]; then
	set -- ''
fi

declare -A labelMap=(
	['cable']='CABLE'
	['driver']='DRIVER'
	['hostname']='HOSTNAME'
	['mode']='UPSMODE'
	['model']='MODEL'
	['serial']='SERIALNO'
	['status']='STATUS'
	['version']='VERSION'
)
declare -A metricMap=(
	['line_voltage']='LINEV'
	['load_percent']='LOADPCT'
	['battery_charge_percent']='BCHARGE'
	['remaining_minutes']='TIMELEFT'
	['output_voltage']='OUTPUTV'
	# TODO somehow do something useful with STATUS (normally "ONLINE ")
)

for host; do
	apc=( apcaccess -h "$host" -u )
	if [ -n "$host" ]; then
		labels="$(printf 'host="%s"' "$host")"
	else
		labels=
	fi
	infoLabels="$labels"
	for key in "${!labelMap[@]}"; do
		val="$("${apc[@]}" -p "${labelMap["$key"]}")"
		label="$(printf '%s="%s"' "$key" "$val")"
		infoLabels+="${infoLabels:+,}$label"
		if [ "$key" = 'serial' ]; then
			labels+="${labels:+,}$label"
		fi
	done
	echo "apcupsd_info{$infoLabels} 1"
	for key in "${!metricMap[@]}"; do
		val="$("${apc[@]}" -p "${metricMap["$key"]}")"
		echo "apcupsd_$key{$labels} $val"
		# TODO validate that "$val" is numeric /o\
	done
done
