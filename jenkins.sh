#!/usr/bin/env bash
set -Eeuo pipefail

# have to be careful with this value because we generate a recursive tree expression thanks to Jenkins API being sorta horrible (we work around this by going recursive when necessary, but hopefully our value is high enough that we don't really ever have to recurse)
maxDepth=10

tree="$(
	jq --raw-output --null-input --argjson depth "$maxDepth" '
		def tokenize:
			gsub("^\\s+|\\s+$"; "")
			| split("\\s+"; "")
		;
		def treeize:
			tokenize
			| join(",")
		;
		"
			name
			fullName
			url
			nextBuildNumber
			buildable
			color
		"
		| tokenize
		| . + [
			(
				"last\(
					"",
					"Completed",
					"Successful", "Unsuccessful",
					"Stable", "Failed", "Unstable",
					empty
				)Build[\(
					"
						url
						number
						timestamp
						duration
						result
						inProgress
					"
					| tokenize
					| join(",")
				)]"
			)
		]
		| join(",")
		| . as $orig
		| reduce range($depth) as $i ("url"; # if we get all the way down, query *just* "url" so we can query deeper
			"\($orig),jobs[\(.)]"
		)
		| @uri
	'
)"
path="/api/json?tree=$tree"

urls=( "$@" )
while [ "${#urls[@]}" -gt 0 ]; do
	urls=( "${urls[@]%/}" )
	urls=( "${urls[@]/%/$path}" )

	# this jq parses the API URLs we query and returns a list of either string (for scraped metrics) or an array (with a single string item) for URLs we need to query to go deeper
	json="$(wget -qO- "${urls[@]}" | jq -c '
		def metric($name; $labels):
			"jenkins_\($name){\(
				$labels
				| to_entries
				| map(.key + "=" + (.value | tostring | tojson))
				| join(",")
			)}"
		;
		., (.. | .jobs?[]?)
		| ._class as $class
		| {
			# surely, there has to be a better way??
			"hudson.model.Hudson": "root",
			"hudson.model.ListView": "view",
			"com.cloudbees.hudson.plugins.folder.Folder": "folder",
			"org.jenkinsci.plugins.workflow.job.WorkflowJob": "job",
			"org.jenkinsci.plugins.workflow.multibranch.WorkflowMultiBranchProject": "job",
		}[$class] as $type
		| if keys == ["_class","url"] then
			# if we get here, we hit the recursion limit and need to go DEEPER
			[ .url ]
			# we output arrays to notify us we have URLs we need to continue querying
		else
			{
				# TODO qualify "name" by instance somehow (so two different Jenkins instances get unique values)
				name: (
					if $type == "root" then
						"/"
					elif $type == "view" then
						# TODO what to do for views? (.name is only the last component, they have no "fullName")
						.name
					else
						.fullName
					end
				),
			} as $labels
			| (
				if [ "root", "folder", "view", "job" ] | index($type) then
					metric("info"; $labels + { type: $type, url: .url, class: $class }) + " 1"
				else empty end,

				if has("nextBuildNumber") then
					metric("next_build_number"; $labels) + " \(.nextBuildNumber)"
				else empty end,

				metric("buildable"; $labels) + " \(if .buildable then 1 else 0 end)",
				#metric("enabled"; $labels) + " \(if .color == "disabled" then 0 else 1 end)",
				# TODO more with color

				(
					[ "last_build", .lastBuild ],
					[ "last_completed_build", .lastCompletedBuild ],
					[ "last_failed_build", .lastFailedBuild ],
					[ "last_stable_build", .lastStableBuild ],
					[ "last_unstable_build", .lastUnstableBuild ],
					[ "last_successful_build", .lastSuccessfulBuild ],
					[ "last_unsuccessful_build", .lastUnsuccessfulBuild ],
					empty

					| .[0] as $prefix
					| .[1] | select(.)
					|
					metric("\($prefix)_info"; $labels + { url: .url }) + " 1",
					metric("\($prefix)_number"; $labels) + " \(.number)",
					metric("\($prefix)_timestamp"; $labels) + " \((.timestamp) / 1000)",
					metric("\($prefix)_duration"; $labels) + " \(.duration)",
					metric("\($prefix)_result"; $labels + { result: (.result // empty) }) + " \({"SUCCESS": 0, "UNSTABLE": 1, "FAILURE": 2}[.result // empty] // -1)",
					if $prefix == "last_build" then
						metric("\($prefix)_in_progress"; $labels) + " \(if .inProgress then 1 else 0 end)"
					else empty end,

					empty
				),

				empty
			)
		end
	')"
	jq <<<"$json" --raw-output 'strings'
	urls="$(jq <<<"$json" --raw-output --slurp 'map(arrays | map(@sh)) | flatten | join(" ")')"
	eval "urls=( $urls )"
done
