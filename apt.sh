#!/usr/bin/env bash
set -Eeuo pipefail

# initial version based heavily on https://github.com/prometheus-community/node-exporter-textfile-collector-scripts/blob/48aaf1cba1309214d30a23a9f4c01816f20ff955/apt.sh

upgrades="$(
	apt-get --just-print dist-upgrade \
		| awk -F'[()]' '
			/^Inst/ {
				sub("^[^ ]+ ", "", $2)
				sub("\\[", " ", $2)
				sub(" ", "", $2)
				sub("\\]", "", $2)
				print $2
			}
		' \
		| sort \
		| uniq -c \
		| awk '
			{
				gsub(/\\\\/, "\\\\", $2)
				gsub(/\"/, "\\\"", $2)
				gsub(/\[/, "", $3)
				gsub(/\]/, "", $3)
				gsub(/Debian:/, "", $2)
				gsub(/Debian-Security:/, "SECURITY:", $2)
				print "apt_upgrades_pending{origin=\"" $2 "\",arch=\"" $3 "\"} " $1
			}
		'
)"

echo '# HELP apt_upgrades_pending Apt package pending updates by origin.'
echo '# TYPE apt_upgrades_pending gauge'
if [ -n "$upgrades" ] ; then
	echo "$upgrades"
else
	echo 'apt_upgrades_pending{origin="",arch=""} 0'
fi

aptMarkManual="$(apt-mark showmanual | wc -l)"
aptMarkAuto="$(apt-mark showauto | wc -l)"
echo '# HELP apt_mark_count Count of packages in "apt-mark" database.'
echo '# TYPE apt_mark_count gauge'
echo 'apt_mark_count{type="manual"}' "$aptMarkManual"
echo 'apt_mark_count{type="auto"}' "$aptMarkAuto"

dpkgSource="$(dpkg-query --show --showformat='${source:Package}\n' | sort -u | wc -l)"
dpkgBinary="$(dpkg-query --show --showformat='${Package}\n' | sort -u | wc -l)"
echo '# HELP dpkg_count Count of unique packages in "dpkg" database.'
echo '# TYPE dpkg_count gauge'
echo 'dpkg_count{type="source"}' "$dpkgSource"
echo 'dpkg_count{type="binary"}' "$dpkgBinary"

echo '# HELP node_reboot_required Node reboot is required for software updates.'
echo '# TYPE node_reboot_required gauge'
rebootRequired=0
for f in {,/var}/run/reboot-required{.pkgs,}; do
	if [ -f "$f" ]; then
		rebootRequired=1
		if base="$(basename "$f")" &&
			[ "$base" = 'reboot-required.pkgs' ] &&
			numPkgs="$(wc -l < "$f")" &&
			[ "$numPkgs" -gt 0 ]
		then
			rebootRequired="$numPkgs"
		fi
		break
	fi
done
echo "node_reboot_required $rebootRequired"
