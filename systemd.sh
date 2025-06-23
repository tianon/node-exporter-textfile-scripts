#!/usr/bin/env bash
set -Eeuo pipefail

systemctl list-units --state failed --output json --no-pager | jq -r '
	def obj_to_labels:
		to_entries
		| map(.key + "=" + (.value | tostring | tojson))
		| join(",")
		| "{" + . + "}"
	;
	map(
		"systemd_unit_info" + ({unit, load, description} | obj_to_labels) + " 1",
		"systemd_unit_failed" + ({unit} | obj_to_labels) + " 1"
	)
	| join("\n")
'
