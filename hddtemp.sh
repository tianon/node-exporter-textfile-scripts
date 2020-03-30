#!/usr/bin/env bash
set -Eeuo pipefail

# this script assumes hddtemp is already running as a TCP-connectable daemon
# (on Debian, this is accomplished via editing "/etc/default/hddtemp" to set `RUN_DAEMON="true"` and doing "systemctl restart hddtemp")

host='localhost'
port='7634'
separator='|'

getoptLongOptions=(
	'host:'
	'port:'
	'separator:'

	'help'
)

# prints "$2$1$3$1...$N"
join() {
	local sep="$1"; shift
	local out; printf -v out "${sep//%/%%}%s" "$@"
	echo "${out#$sep}"
}

if ! opts="$(getopt --options 'h?' --long "$(join ',' "${getoptLongOptions[@]}")" -- "$@")"; then
	# TODO usage >&2
	exit 1
fi
eval set -- "$opts"

while true; do
	flag="$1"; shift
	case "$flag" in
		--host) host="$1"; shift ;;
		--port) port="$1"; shift ;;
		--separator) separator="$1"; shift ;;

		-h | '-?' | --help)
			# TODO usage
			exit 0
			;;

		--) break ;;

		*)
			echo >&2 "error: unknown flag: $flag"
			# TODO usage >&2
			exit 1
			;;
	esac
done

cat <<-'EOH'
	# TYPE hddtemp_celsius gauge
	# HELP hddtemp_celsius Hard drive temperature (from hddtemp daemon).
EOH

escape_label() {
	sed -e 's/["\\]/\\&/g' -e '$!s/$/\\n/' <<<"$*" | tr -d '\n'
}

data="$(cat < "/dev/tcp/$host/$port")"
while [ -n "$data" ]; do
	disk="$(cut -d"$separator" -f2 <<<"$data")"
	model="$(cut -d"$separator" -f3 <<<"$data")"
	temp="$(cut -d"$separator" -f4 <<<"$data")"
	unit="$(cut -d"$separator" -f5 <<<"$data")"
	data="$(cut -d"$separator" -f6- <<<"$data")"

	unit="${unit^^}"
	display="$disk: $model: $temp°$unit"

	case "$unit" in
		F)
			# convert to C
			(( (temp - 32) * 5 / 9 )) || :
			;;

		C) ;;

		*)
			echo >&2 "error: unknown unit: '$unit' ($display)"
			exit 1
			;;
	esac

	cat <<-EOD
		# $display
		hddtemp_celsius{disk="$(escape_label "$disk")",model="$(escape_label "$model")"} $temp
	EOD
done
