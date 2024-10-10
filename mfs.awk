# really hacky parser of "mfscli" output for use in Prometheus

# mfscli -p -n -SIN -S... | gawk -f mfs.awk > mfs.prom

BEGIN {
	FS = "\t"
}

# despite the name, this is actually master servers (on Pro, there should be multiple)
$1 == "metadata servers:" {
	ip = $2
	version = $3
	state = $4 # "-" (Pro?)
	localtime = $5 # unix timestamp
	metadata_version = $6
	metadata_delay = $7 # "not available" (Pro?)
	ram_used = $8 # bytes
	cpu_used = $9 # "all:0.7310232% sys:0.3154687% user:0.4155545%"
	last_successful_metadata_save = $10 # unix timestamp
	last_metadata_save_duration = $11 # fractional seconds
	last_metadata_save_status = $12 # "Saved in background"
	exports_checksum = $13 # "FFCCFD8ADEFBE2DE"

	printf "\n"
	printf "mfs_master_info{ip=\"%s\",version=\"%s\"} 1\n", ip, version

	metric_labels = sprintf("ip=\"%s\"", ip)
	printf "mfs_master_local_timestamp{%s} %d\n", metric_labels, 1000 * localtime
	printf "mfs_master_memory_usage_bytes{%s} %d\n", metric_labels, ram_used
	printf "mfs_master_metadata_version{%s} %d\n", metric_labels, metadata_version
	printf "mfs_master_metadata_save_timestamp{%s} %d\n", metric_labels, 1000 * last_successful_metadata_save
	printf "mfs_master_metadata_save_seconds{%s} %s\n", metric_labels, last_metadata_save_duration
	printf "mfs_master_exports_info{%s,exports_checksum=\"%s\"} 1\n", metric_labels, exports_checksum
	printf "\n"
}

$1 == "master info:" {
	switch ($2) {
		case / space$/: # free, avail, trash, etc.
			gsub(/ space$/, "", $2)
			gsub(/[[:space:]]+/, "_", $2)
			printf "mfs_%s_bytes %s\n", $2, $3
			break

		case "all fs objects":
		case "chunks":
		case "directories":
		case /(^| )files$/:
			gsub(/[[:space:]]+/, "_", $2)
			printf "mfs_%s %s\n", $2, $3
			break

		case / chunk copies$/:
			gsub(/ chunk copies$/, "", $2)
			gsub(/[[:space:]]+/, "_", $2)
			printf "mfs_%s_chunks %s\n", $2, $3
			break
	}
}

$1 == "all chunks matrix:" {
	switch ($2) {
		case "goal/copies/chunks:":
			goal = $3
			copies = $4
			chunks = $5
			# TODO figure out how to represent this matrix in prometheus
			break

		case /^chunkclass /:
			gsub(/^chunkclass |:$/, "", $2)
			gsub(/[[:space:]]+/, "_", $2)
			printf "mfs_class_%s_chunks %s\n", $2, $3
			break
	}
}

$1 == "chunk servers:" {
	ip = $2
	port = $3
	id = $4
	labels = $5
	version = $6
	load = $7
	maintenance = $8 # https://github.com/moosefs/moosefs/blob/a77b173450034d5debe5ca9a748a3b0d151b0eeb/mfsscripts/mfscli.py.in#L4328-L4336
	chunks = $9
	used_bytes = $10
	total_bytes = $11
	for_removal_status = $12 # https://github.com/moosefs/moosefs/blob/a77b173450034d5debe5ca9a748a3b0d151b0eeb/mfsscripts/mfscli.py.in#L4338-L4346
	for_removal_chunks = $13
	for_removal_used_bytes = $14
	for_removal_total_bytes = $15

	printf "\n"
	printf "mfs_chunkserver_info{id=\"%s\",ip=\"%s\",port=\"%s\",labels=\"%s\",version=\"%s\"} 1\n", id, ip, port, labels, version

	metric_labels = sprintf("id=\"%s\"", id)
	printf "mfs_chunkserver_load{%s} %d\n", metric_labels, load
	printf "mfs_chunkserver_maintenance{%s,maintenance=\"%s\"} %d\n", metric_labels, maintenance, (maintenance != "maintenance_off")
	printf "mfs_chunkserver_chunks{%s} %d\n", metric_labels, chunks
	printf "mfs_chunkserver_used_bytes{%s} %d\n", metric_labels, used_bytes
	printf "mfs_chunkserver_total_bytes{%s} %d\n", metric_labels, total_bytes
	printf "mfs_chunkserver_for_removal_status{%s,status=\"%s\"} %d\n", metric_labels, for_removal_status, (for_removal_status == "-" ? 0 : (for_removal_status == "READY" ? 1 : -1))
	printf "mfs_chunkserver_for_removal_chunks{%s} %d\n", metric_labels, for_removal_chunks
	printf "mfs_chunkserver_for_removal_used_bytes{%s} %d\n", metric_labels, for_removal_used_bytes
	printf "mfs_chunkserver_for_removal_total_bytes{%s} %d\n", metric_labels, for_removal_total_bytes
	printf "\n"
}

$1 == "metadata backup loggers:" {
	printf "mfs_metalogger_info{ip=\"%s\",version=\"%s\"} 1\n", $2, $3
}

$1 == "disks:" {
	ip_port_path = $2
	chunks = $3
	last_error = $4 # https://github.com/moosefs/moosefs/blob/a77b173450034d5debe5ca9a748a3b0d151b0eeb/mfsscripts/mfscli.py.in#L4848-L4858 ("no errors" or a unix timestamp in seconds)
	status = $5 # https://github.com/moosefs/moosefs/blob/a77b173450034d5debe5ca9a748a3b0d151b0eeb/mfsscripts/mfscli.py.in#L4832-L4846 ("ok" or a comma+space-separated list of status strings)
	last_minute_read_bytes = $6
	last_minute_write_bytes = $7
	last_minute_max_time_read_microseconds = $8
	last_minute_max_time_write_microseconds = $9
	last_minute_max_time_fsync_microseconds = $10
	last_minute_num_read_ops = $11
	last_minute_num_write_ops = $12
	last_minute_num_fsync_ops = $13
	used_bytes = $14
	total_bytes = $15

	fields = split(ip_port_path, parts, ":")
	ip = parts[1]
	port = parts[2]
	path = parts[3]
	# if fields > 3, add the remaining bits of parts back to path (for paths with colons)
	for (i = 4; i <= fields; ++i) {
		path = path ":" parts[i]
	}

	metric_labels = sprintf("ip=\"%s\",port=\"%s\",path=\"%s\"", ip, port, path)

	printf "\n"
	printf "mfs_disk_info{%s} 1\n", metric_labels

	printf "mfs_disk_chunks{%s} %d\n", metric_labels, chunks
	printf "mfs_disk_error{%s} %d\n", metric_labels, (last_error == "no errors" ? 0 : (last_error + 0 == last_error ? last_error : -1)) # TODO if last_error is not "no errors" but is also not numeric, we should probably do something different (add an "error" label or something and set the value to the current timestamp? MAX_INT? -1?)
	printf "mfs_disk_status{%s,status=\"%s\"} %d\n", metric_labels, status, (status == "ok" ? 1 : (status == "marked for removal (ready)" ? 2 : 0))
	# TODO more metrics? (last_minute_* period changes with a CLI flag D:)
	printf "mfs_disk_used_bytes{%s} %d\n", metric_labels, used_bytes
	printf "mfs_disk_total_bytes{%s} %d\n", metric_labels, total_bytes
	printf "\n"
}

# TODO "exports:" ? (no stats, only configuration data)

$1 == "active mounts, parameters:" {
	session_id = $2
	ip = $3
	mountpoint = $4
	open_files = $5
	num_conn = $6
	version = $7
	root = $8
	ro = $9
	restricted_ip = $10
	ignore_gid = $11
	admin = $12
	map_root_uid = $13
	map_root_gid = $14
	map_users_uid = $15
	map_users_gid = $16
	goal_limits_min = $17
	goal_limits_max = $18
	trashtime_limits_min = $19
	trashtime_limits_max = $20
	global_umask = $21
	disables_mask = $22

	# TODO
}
$1 == "inactive mounts, parameters:" {
	session_id = $2
	ip = $3
	mountpoint = $4
	open_files = $5
	expires = $6

	# TODO
}

$1 == "storage classes:" {
	id = $2
	name = $3
	admin_only = $4
	mode = $5
	files = $6
	dirs = $7
	under = $8
	exact = $9
	over = $10
	archived_under = $11
	archived_exact = $12
	archived_over = $13
	create_can_be_fulfilled = $14
	create_goal = $15
	create_labels = $16
	keep_can_be_fulfilled = $17
	keep_goal = $18
	keep_labels = $19
	archive_can_be_fulfilled = $20
	archive_goal = $21
	archive_labels = $22
	archive_delay = $23

	printf "\n"
	printf "mfs_storage_class_info{id=\"%s\",name=\"%s\",admin_only=\"%s\",mode=\"%s\",create_goal=\"%s\",create_labels=\"%s\",keep_goal=\"%s\",keep_labels=\"%s\",archive_goal=\"%s\",archive_labels=\"%s\",archive_delay=\"%s\"} 1\n", id, name, admin_only, mode, create_goal, create_labels, keep_goal, keep_labels, archive_goal, archive_labels, archive_delay

	metric_labels = sprintf("id=\"%s\"", id)
	printf "mfs_storage_class_can_be_fulfilled{%s} %d\n", metric_labels, (create_can_be_fulfilled == "YES") + (keep_can_be_fulfilled == "YES") + (archive_can_be_fulfilled == "YES")
	printf "mfs_storage_class_files{%s} %d\n", metric_labels, files
	printf "mfs_storage_class_directories{%s} %d\n", metric_labels, dirs
	printf "mfs_storage_class_under_chunks{%s} %d\n", metric_labels, under
	printf "mfs_storage_class_exact_chunks{%s} %d\n", metric_labels, exact
	printf "mfs_storage_class_over_chunks{%s} %d\n", metric_labels, over
	printf "mfs_storage_class_archived_under_chunks{%s} %d\n", metric_labels, archived_under
	printf "mfs_storage_class_archived_exact_chunks{%s} %d\n", metric_labels, archived_exact
	printf "mfs_storage_class_archived_over_chunks{%s} %d\n", metric_labels, archived_over
	printf "\n"
}
