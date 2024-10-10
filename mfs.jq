# MooseFS 4 added a "-j" flag to "mfscli" which produces official JSON output!

# mfscli -j -SIN -SCS -SMB -SHD -SMS -SSC -SQU ... | jq -rf mfs.jq > mfs.prom

# version: 4.56.6
#
# ...
#	-j : print result in JSON format
# ...
#	-S data set : defines data set to be displayed
#		-SIN : show full master info
#		-SIM : show only masters states
#		-SIG : show only general master info
#		-SMU : show only master memory usage
#		-SIC : show only chunks info (target/current redundancy level matrices)
#		-SIL : show only loop info (with messages)
#		-SMF : show only missing chunks/files
#		-SCS : show connected chunk servers
#		-SMB : show connected metadata backup servers
#		-SHD : show hdd data
#		-SEX : show exports
#		-SMS : show active mounts
#		-SRS : show resources (storage classes,open files,acquired locks)
#		-SSC : show storage classes
#		-SPA : show patterns override data
#		-SOF : show only open files
#		-SAL : show only acquired locks
#		-SMO : show operation counters
#		-SQU : show quota info
#		-SMC : show master charts data
#		-SCC : show chunkserver charts data
# ...

def obj_to_labels:
	to_entries
	| map(.key + "=" + (.value | tostring | tojson))
	| if length > 0 then
		join(",")
		| "{" + . + "}"
	else "" end
;

def metric($name; $value; $labels):
	if $labels | has("HELP") then
		"# HELP \($name) \($labels.HELP)"
	else empty end,
	if $labels | has("TYPE") then
		"# TYPE \($name) \($labels.TYPE)"
	else empty end,
	"\($name)\($labels | del(.HELP, .TYPE) | map_values(values) | obj_to_labels) \($value)"
;
def metric($name; $value):
	metric($name; $value; {})
;

metric("mfs_cli_info"; 1; {
	version: .version,
}),
metric("mfs_cli_timestamp"; .timestamp * 1000),
# .shifted_timestamp contains timestamp, but shifted by the offset of the current mfscli timezone 😬

# -SIM : show only masters states
# -SIG : show only general master info
(
	.dataset.info.masters[]? // .dataset.info.general? // empty
	| { ip: .ip } as $labels |

	metric("mfs_master_info"; 1; $labels + {
		version: .version,
		state: .state, # "MASTER", etc; https://github.com/moosefs/moosefs/blob/5afd7b57c065d6b36ebe755ccffd17adf33b1975/mfsscripts/mfscli.py.in#L2603-L2718 ("statestr")
		#pro: .pro, # false, true
	}),

	if .localtime then
		metric("mfs_master_local_timestamp"; .localtime * 1000; $labels)
	else empty end,

	(
		{
			memory_usage_bytes: .memory_usage,

			cpu_usage_percent: .cpu_usage_percent,
			cpu_system_percent: .cpu_system_percent,
			cpu_user_percent: .cpu_user_percent,

			metadata_version: .metadata_version,
			metadata_save_timestamp: (.last_metadata_save_time * 1000),
			metadata_save_seconds: .last_metadata_save_duration,
			# TODO .last_metadata_save_status (0; "Saved in background")
			# TODO .metadata_id (null)
			# TODO .metadata_delay (null)
			# TODO .last_metadata_save_version (null)
			# TODO .last_metadata_save_checksum (null)
		}
		| map_values(values) # filter nulls
		| to_entries[]
		| metric("mfs_master_\(.key)"; .value; $labels)
	),

	if .exports_checksum then
		metric("mfs_master_exports_info"; 1; $labels + { exports_checksum: .exports_checksum })
	else empty end,

	empty
),

# -SIG : show only general master info
# (for data *not* in -SIM)
(
	.dataset.info.general? // empty
	| {} as $labels |

	(
		to_entries[]
		| .key as $k
		| .value as $v
		| .key
		| if endswith("_space") then
			metric("mfs_\(rtrimstr("_space"))_bytes"; $v; $labels)
		elif endswith("_files") or IN("chunks", "directories", "files") then
			metric("mfs_\(.)"; $v; $labels)
		elif endswith("_copies") then
			metric("mfs_\(rtrimstr("_copies"))_chunks"; $v; $labels)
		else
			{
				filesystem_objects: "all_fs_objects",
			}[$k]
			// empty
			| metric("mfs_\(.)"; $v; $labels)
		end
	),

	empty
),

# TODO -SMU : show only master memory usage

# -SIC : show only chunks info (target/current redundancy level matrices)
(
	.dataset.info.chunks? // empty
	| {} as $labels |

	(
		{
			all: .allchunks,
			regular: (.regularchuks // .regularchunks), # TODO https://github.com/moosefs/moosefs/pull/596
		}
		| to_entries[]
		| .key as $type
		| .value[]
		| metric("mfs_chunks_\($type)"; .chunks; $labels + {
			target: .target,
			current: .current,
		}) | empty # TODO make sure this is *really* how you want to present this information
	),

	# TODO "summary" data too

	empty
),

# TODO -SIL : show only loop info (with messages)
# TODO -SMF : show only missing chunks/files

# -SCS : show connected chunk servers
(
	.dataset.chunkservers[]? // empty
	| { id: .csid } as $labels |

	metric("mfs_chunkserver_info"; 1; $labels + {
		ip: .ip,
		hostname: .hostname,
		port: .port,
		labels: (.labels | join(",")), # this is probably what ends up in "labels_str" anyhow 😅
		version: .version,
		#pro: .pro, # false, true
	}),

	metric("mfs_chunkserver_maintenance"; if .maintenance_mode == "off" then 0 else 1 end; $labels + {
		maintenance: .maintenance_mode,
	}),

	(
		{
			up: (if .connected then 1 else 0 end),
			load: .load,

			used_bytes: .hdd_regular_used,
			total_bytes: .hdd_regular_total,
			chunks: .hdd_regular_chunks,

			for_removal_used_bytes: .hdd_removal_used,
			for_removal_total_bytes: .hdd_removal_total,
			for_removal_chunks: .hdd_removal_chunks,
		}
		| map_values(values) # ignore nulls
		| to_entries[]
		| metric("mfs_chunkserver_\(.key)"; .value; $labels)
	),

	metric("mfs_chunkserver_for_removal_status"; .hdd_removal_stat | if . == "-" then 0 elif . == "READY" then 1 else -1 end; $labels + {
		status: .hdd_removal_stat,
	}),

	empty
),

# -SMB : show connected metadata backup servers
(
	.dataset.metaloggers[]? // empty
	| { ip: .ip } as $labels |

	metric("mfs_metalogger_info"; 1; $labels + {
		hostname: .hostname,
		version: .version,
		#pro: .pro, # false, true
	})
),

# -SHD : show hdd data
(
	.dataset.disks[]? // empty
	| { ip: .ip, port: .port, path: .path } as $labels |

	metric("mfs_disk_info"; 1; $labels + {
		hostname: .hostname,
	}),

	metric("mfs_disk_error"; if .last_error_time == 0 then 0 else 1 end; $labels + {
		error: .last_error_time_str,
	}),

	metric("mfs_disk_status"; .status_str | if . == "ok" then 1 elif . == "marked for removal (ready)" then 2 else 0 end; $labels + {
		status: .status_str,
	}),

	(
		{
			chunks: .chunks,
			error_timestamp: (.last_error_time * 1000),
			used_bytes: .used,
			total_bytes: .total,
			scan_percent: (.scan_progress / 100),
		}
		| map_values(values) # ignore nulls
		| to_entries[]
		| metric("mfs_disk_\(.key)"; .value; $labels)
	),

	empty
),

# TODO -SEX : show exports
# (no stats, only configuration data)

# -SMS : show active mounts
(
	.dataset.mounts[]? // empty
	| { session: .session_id } as $labels |

	metric("mfs_mount_info"; 1; $labels + {
		ip: .ip,
		hostname: .hostname,
		mount_point: .mount_point,
		path: .path,
		version: .version,
		#pro: .pro,
	}),

	(
		{
			up: (if .connected then 1 else 0 end),
			# TODO temporary: (if .temporary then 1 else 0 end), # (what does this mean? 👀)
			open_files: .open_files,
			sockets: .number_of_sockets,
			expire_seconds: .seconds_to_expire,
		}
		| map_values(values) # ignore nulls
		| to_entries[]
		| metric("mfs_mount_\(.key)"; .value; $labels)
	),

	empty
),

# TODO -SRS : show resources (storage classes,open files,acquired locks)
# (specific open inodes -- might be too high cardinality)

# -SSC : show storage classes
(
	.dataset.storage_classes[]? // empty
	| { id: .sclassid } as $labels |

	metric("mfs_storage_class_info"; 1; $labels + {
		name: .sclassname,
	}),

	(
		{
			admin_only: (if .admin_only then 1 else 0 end),
			# TODO archive_delay_hours: .arch_delay,
			# TODO archive_min_bytes: .arch_min_size,
			files: .files,
			directories: .dirs,
			can_be_fulfilled: (if [ .storage_modes[].can_be_fulfilled_str == "YES" ] | all then 1 else 0 end),
			under_chunks: ([ .storage_modes[].chunks_undergoal_copy ] | add),
			exact_chunks: ([ .storage_modes[].chunks_exactgoal_copy ] | add),
			over_chunks: ([ .storage_modes[].chunks_overgoal_copy ] | add),
		}
		| map_values(values) # ignore nulls
		| to_entries[]
		| metric("mfs_storage_class_\(.key)"; .value; $labels)
	),

	(
		.storage_modes
		| to_entries[]
		| .key as $mode
		| ($labels + { mode: $mode }) as $labels
		| .value |

		metric("mfs_storage_class_mode_info"; 1; $labels + {
			labels: .labels_str,
			can_be_fulfilled: .can_be_fulfilled_str,
		}),

		(
			{
				can_be_fulfilled: (if .can_be_fulfilled_str == "YES" then 1 else 0 end),
				goal: .full_copies,
				under_chunks: .chunks_undergoal_copy,
				exact_chunks: .chunks_exactgoal_copy,
				over_chunks: .chunks_overgoal_copy,
			}
			| map_values(values) # ignore nulls
			| to_entries[]
			| metric("mfs_storage_class_mode_\(.key)"; .value; $labels)
		),

		empty
	),

	empty
),

# -SPA : show patterns override data (???)
# -SOF : show only open files (cardinality)
# -SAL : show only acquired locks (cardinality)

# TODO -SMO : show operation counters

# -SQU : show quota info
(
	.dataset.quotas[]? // empty
	| { path: .path } as $labels |

	(
		{
			exceeded: (if .exceeded then 1 else 0 end),
			grace_seconds: .grace_period,
			# TODO more fields, especially soft limits, "realsize", "length"?  maybe "hard" vs "soft" should be labels instead of different metrics?
			limit_bytes: .hard_quota_size,
			limit_files: .hard_quota_inodes,
			bytes: .current_quota_size,
			files: .current_quota_inodes,
		}
		| map_values(values) # ignore nulls
		| to_entries[]
		| metric("mfs_quota_\(.key)"; .value; $labels)
	),

	empty
),

# TODO -SMC : show master charts data (??? possibly high cardinality)
# TODO -SCC : show chunkserver charts data (??? possibly high cardinality)

empty # trailing comma
