#!/usr/bin/env bash
set -Eeuo pipefail

target="$1"; shift # "/path/to/textfile/exporter/directory/"

script="$1"; shift # "apt.sh", "/path/to/apt.sh"
base="$(basename "$script")" # "apt.sh"
base="${base%.*}" # "apt"

targetProm="$target/$base.prom"
trap "$(printf 'rm -f %q' "$targetProm.$$")" EXIT

if [ ! -x "$script" ]; then
	thisScript="$BASH_SOURCE"
	scriptDir="$(dirname "$thisScript")"
	if [ ! -x "$scriptDir/$script" ]; then
		thisScript="$(readlink -f "$thisScript")"
		scriptDir="$(dirname "$thisScript")"
	fi
	script="$scriptDir/$script"
fi

"$script" "$@" > "$targetProm.$$"
mv "$targetProm.$$" "$targetProm"
