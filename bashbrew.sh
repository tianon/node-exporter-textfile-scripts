#!/usr/bin/env bash
set -Eeuo pipefail

# args: [namespace]:[library directory]

if [ "$#" -eq 0 ]; then
	set -- ':'
fi

for namespaceLibrary; do
	[[ "$namespaceLibrary" == *:* ]]

	export BASHBREW_NAMESPACE="${namespaceLibrary%%:*}"
	[ "$BASHBREW_NAMESPACE" != "$namespaceLibrary" ]

	export BASHBREW_LIBRARY="${namespaceLibrary#$BASHBREW_NAMESPACE:}"
	[ "$BASHBREW_LIBRARY" != "$namespaceLibrary" ]

	if [ -z "$BASHBREW_LIBRARY" ]; then
		unset BASHBREW_LIBRARY
	fi

	labels="namespace=\"$BASHBREW_NAMESPACE\""

	repos="$(bashbrew list --all --repos)"

	repo_count="$(wc -l <<<"$repos")"
	echo "bashbrew_repo_count{$labels} $repo_count"

	for repo in --all $repos; do (
		if [ "$repo" != '--all' ]; then
			labels="$labels,repo=\"$repo\""
			repoName="$(basename "$repo")"
		else
			repoName="$repo"
		fi

		if lastCommitTime="$(git -C "${BASHBREW_LIBRARY:-$HOME/docker/official-images/library}" log -1 --format='format:%ct' -- "$([ "$repoName" = '--all' ] && echo '.' || echo "$repoName")" 2>/dev/null)" && [ -n "$lastCommitTime" ]; then
			echo "bashbrew_commit_timestamp_seconds{$labels} $lastCommitTime"
		fi

		arches="$(bashbrew cat --format '{{ range .Entries }}{{ .Architectures | join "\n" }}{{ "\n" }}{{ end }}' "$repoName" | sort -u)"

		archCount="$(wc -l <<<"$arches")"
		echo "bashbrew_arch_count{$labels} $archCount"

		for arch in '' $arches; do (
			args=()
			if [ -n "$arch" ]; then
				labels="$labels,arch=\"$arch\""
				export BASHBREW_ARCH="$arch"
				args+=( --arch-filter )
			fi

			uniq="$(bashbrew list "${args[@]}" --uniq "$repoName" | wc -l)"
			echo "bashbrew_uniq_count{$labels} $uniq"

			tags="$(bashbrew list "${args[@]}" "$repoName" | sort -u | wc -l)"
			echo "bashbrew_tag_count{$labels} $tags"
		) done
	) done
done
