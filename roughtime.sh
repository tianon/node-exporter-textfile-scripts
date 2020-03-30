#!/usr/bin/env bash
set -Eeuo pipefail

# TODO convert this to Go and use the real roughtime client library instead

# https://blog.cloudflare.com/roughtime/
# https://developers.cloudflare.com/roughtime/
# cloudflare-domain.example.com/cdn-cgi/trace -- standard place to scrape cloudflare's roughtime value

if [ "$#" -eq 0 ]; then
	set -- cloudflare.com
fi

echo '# TYPE roughtime_delta gauge'
echo '# HELP Rough difference between current system time and CloudFlare "Roughtime" in seconds'

for domain; do
	diff="$(wget -qO- "https://$domain/cdn-cgi/trace" | awk -F= '$1 == "ts" { "date +%s.%N" | getline ts; print ts - $2 }')"
	echo "roughtime_delta{domain=\"$domain\"} $diff"
done
