#!/usr/bin/env bash
set -Eeuo pipefail

# see "speedtest --servers" for useful server numbers
if [ "$#" -eq 0 ]; then
	# an empty server-id will query the "closest"
	set -- ''
fi

# example document:
#
# {
#   "type": "result",
#   "timestamp": "2022-09-23T22:31:15Z",
#   "ping": {
#     "jitter": 0.554,
#     "latency": 3.96,
#     "low": 2.943,
#     "high": 4.066
#   },
#   "download": {
#     "bandwidth": 117023452,
#     "bytes": 953334240,
#     "elapsed": 8206,
#     "latency": {
#       "iqm": 20.592,
#       "low": 3.207,
#       "high": 26.074,
#       "jitter": 1.146
#     }
#   },
#   "upload": {
#     "bandwidth": 93708753,
#     "bytes": 717183164,
#     "elapsed": 7706,
#     "latency": {
#       "iqm": 6.855,
#       "low": 3.121,
#       "high": 18.721,
#       "jitter": 1.018
#     }
#   },
#   "packetLoss": 0,
#   "isp": "XX",
#   "interface": {
#     "internalIp": "XX.XX.XX.XX",
#     "name": "XX",
#     "macAddr": "XX:XX:XX:XX:XX:XX",
#     "isVpn": false,
#     "externalIp": "XX.XX.XX.XX"
#   },
#   "server": {
#     "id": 39524,
#     "host": "lg.dc07.dedicontrol.com",
#     "port": 8080,
#     "name": "DediPath",
#     "location": "Las Vegas, NV",
#     "country": "United States",
#     "ip": "5.104.78.10"
#   },
#   "result": {
#     "id": "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
#     "url": "https://www.speedtest.net/result/c/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX",
#     "persisted": true
#   }
# }
#

for server; do
	docker=(
		docker run --rm --network host --init --log-driver none

		--mount 'type=volume,src=speedtest-home,dst=/root'

		'tianon/speedtest:1.2'

		--accept-license
		--format=json

		--server-id="$server"
	)
	json="$("${docker[@]}")"

	jq <<<"$json" -r '
		def flat_map(prefix):
			to_entries | map(
				.key = prefix + .key
				| .key as $key
				| if (.value | type) == "object" then
					.value | flat_map($key + "_") | to_entries[]
				else . end
			) | from_entries
			;
		def labels:
			"{" + (
				flat_map("")
				| to_entries
				| map(.key + "=" + (.value | tostring | tojson))
				| join(",")
			) + "}"
			;
		"speedtest_info" + (
			{
				server: .server,
				interface: .interface,
				isp: .isp,
			} | labels
		) + " 1",
		"speedtest_result_info" + (
			{
				server_id: .server.id,
				result: .result,
			} | labels
		) + " 1",
		"speedtest_interface_info" + (
			{
				server_id: .server.id,
				interface: .interface,
			} | labels
		) + " 1",
		({ "server_id": .server.id } | labels) as $labels
		| . as $doc
		| reduce ["ping", "download", "upload"][] as $section (
			{}; . + ($doc[$section] | flat_map($section + "_"))
		)
		| to_entries
		| map("speedtest_" + .key + $labels + " " + (.value | tostring))[]
	'
done
