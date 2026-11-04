import Foundation

public enum SQLStateChangingFunctions {
    public static func contains(_ name: String) -> Bool {
        // MariaDB looks `releaſe_lock` up as `RELEASE_LOCK` (measured on 13.0.2), so the name is folded upper first.
        let lowered = name.uppercased().lowercased()
        // KingbaseES ships each pg_ function under a sys_ name too, such as sys_terminate_backend (measured on V9R1C10).
        if lowered.hasPrefix("sys_") { return names.contains("pg_" + lowered.dropFirst(4)) }
        return names.contains(lowered)
    }

    static func isDuckDBCall(_ name: String) -> Bool {
        duckDBCalls.contains(name.uppercased().lowercased())
    }

    // SQLite runs a table-valued pragma named as a table source too, so `SELECT * FROM main.pragma_optimize` runs
    // ANALYZE. A call is the call scanner's; a column or alias of that name runs nothing.
    static func namesStateChangingTable(in text: NSString, tokens: [TSQLTokens.Token], grammar: SQLLexicalGrammar) -> Bool {
        var listsTables: [Int: Bool] = [:]
        var expectsTable = false
        var namesTable = false
        for token in tokens {
            let expected = expectsTable
            let qualifies = namesTable
            expectsTable = false
            namesTable = false
            switch token.kind {
            case .word(let word):
                if expected, tableFunctions.contains(word.lowercased()) { return true }
                namesTable = expected
                if tableIntroducers.contains(word) {
                    listsTables[token.depth] = true
                    expectsTable = true
                } else if tableListEnders.contains(word) {
                    listsTables[token.depth] = false
                }
            case .quoted:
                guard expected else { break }
                guard let span = SQLNonCodeSpan.span(at: token.location, in: text, grammar: grammar) else { return true }
                let body = NSRange(location: span.start + 1, length: max(0, span.contentEnd - span.start - 1))
                if tableFunctions.contains(text.substring(with: body).lowercased()) { return true }
                namesTable = true
            case .name:
                namesTable = expected
            case .comma:
                expectsTable = listsTables[token.depth] == true
            case .other where text.character(at: token.location) == period:
                expectsTable = qualifies
            default:
                break
            }
        }
        return false
    }

    private static let period = UInt16(UnicodeScalar(".").value)

    private static let tableIntroducers: Set<String> = ["FROM", "JOIN"]

    private static let tableListEnders: Set<String> = [
        "WHERE", "GROUP", "HAVING", "WINDOW", "ORDER", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "RETURNING",
        "ON", "USING", "SELECT",
    ]

    private static let tableFunctions: Set<String> = ["pragma_optimize"]

    static let names: Set<String> = serverSignals
        .union(sessionControl)
        .union(recoveryAndBackup)
        .union(replication)
        .union(sequences)
        .union(advisoryLocks)
        .union(settingsAndStatistics)
        .union(largeObjects)
        .union(filesAndExtensions)
        .union(catalogAndStorage)
        .union(indexMaintenance)
        .union(sqlTextRunners)
        .union(scheduledJobs)
        .union(hypertablesAndChunks)
        .union(rolesAndGrants)

    static let serverSignals: Set<String> = [
        "pg_cancel_backend", "pg_terminate_backend", "pg_reload_conf", "pg_rotate_logfile",
        "pg_log_backend_memory_contexts"
    ]

    // dblink_close commits the remote transaction dblink_open began, with whatever dblink_exec ran in it, and
    // pg_background's cancels stop a worker before it commits.
    static let sessionControl: Set<String> = [
        "system$abort_session", "system$cancel_query", "system$cancel_all_queries", "system$abort_transaction",
        "abortsessions", "dblink_cancel_query", "dblink_close", "pg_background_cancel", "pg_background_cancel_v2",
        "pg_background_cancel_all", "pg_background_cancel_all_v2", "pg_background_cancel_by_label",
        "pg_background_cancel_by_label_v2", "pg_background_cancel_v2_grace"
    ]

    static let recoveryAndBackup: Set<String> = [
        "pg_promote", "pg_wal_replay_pause", "pg_wal_replay_resume", "pg_backup_start", "pg_backup_stop",
        "pg_switch_wal", "pg_create_restore_point", "pg_log_standby_snapshot", "pg_start_backup", "pg_stop_backup",
        "pg_switch_xlog", "pg_xlog_replay_pause", "pg_xlog_replay_resume", "timescaledb_pre_restore",
        "timescaledb_post_restore"
    ]

    static let replication: Set<String> = [
        "pg_create_physical_replication_slot", "pg_create_logical_replication_slot",
        "pg_copy_physical_replication_slot", "pg_copy_logical_replication_slot", "pg_drop_replication_slot",
        "pg_replication_slot_advance", "pg_sync_replication_slots", "pg_logical_slot_get_changes",
        "pg_logical_slot_get_binary_changes", "pg_logical_emit_message", "pg_replication_origin_create",
        "pg_replication_origin_drop", "pg_replication_origin_advance", "pg_replication_origin_session_setup",
        "pg_replication_origin_session_reset", "pg_replication_origin_xact_setup",
        "pg_replication_origin_xact_reset"
    ]

    static let sequences: Set<String> = ["nextval", "setval"]

    static let advisoryLocks: Set<String> = [
        "pg_advisory_lock", "pg_advisory_lock_shared", "pg_advisory_unlock", "pg_advisory_unlock_shared",
        "pg_advisory_unlock_all", "pg_advisory_xact_lock", "pg_advisory_xact_lock_shared", "pg_try_advisory_lock",
        "pg_try_advisory_lock_shared", "pg_try_advisory_xact_lock", "pg_try_advisory_xact_lock_shared", "get_lock",
        "release_lock", "release_all_locks"
    ]

    static let settingsAndStatistics: Set<String> = [
        "set_config", "pg_notify", "pg_stat_reset", "pg_stat_reset_shared", "pg_stat_reset_single_table_counters",
        "pg_stat_reset_single_function_counters", "pg_stat_reset_slru", "pg_stat_reset_replication_slot",
        "pg_stat_reset_subscription_stats", "pg_stat_statements_reset", "pg_restore_relation_stats",
        "pg_restore_attribute_stats", "pg_clear_relation_stats", "pg_clear_attribute_stats",
        "pg_stat_reset_backend_stats"
    ]

    static let largeObjects: Set<String> = [
        "lo_create", "lo_creat", "lo_unlink", "lo_from_bytea", "lo_put", "lowrite", "lo_truncate", "lo_truncate64"
    ]

    static let filesAndExtensions: Set<String> = [
        "lo_import", "lo_export", "pg_file_write", "pg_file_rename", "pg_file_unlink", "writefile", "load_extension"
    ]

    // Writes to the catalog, or straight to a table's pages, that a read-only transaction does not stop (measured on
    // PostgreSQL 17.11).
    static let catalogAndStorage: Set<String> = [
        "pg_import_system_collations", "heap_force_kill", "heap_force_freeze", "pg_truncate_visibility_map"
    ]

    // SQLite's pragma_optimize table function runs ANALYZE, measured on 3.54.0. No other pragma function takes a value.
    static let indexMaintenance: Set<String> = [
        "brin_summarize_new_values", "brin_summarize_range", "brin_desummarize_range", "gin_clean_pending_list",
        "pragma_optimize"
    ]

    // SQL Server's OPENQUERY and OPENROWSET hand their last argument to a linked server, or back to this one through
    // a loopback link, as a batch of its own: a SELECT from either can carry a DELETE, as a SELECT from dblink can.
    // crosstab, connectby and xpath_table paste their text arguments into the SQL they run. pg_background runs its
    // text in a worker that commits on its own, and pg_cron's schedule, schedule_in_database and alter_job store a
    // command its worker runs later; TimescaleDB's alter_job shares the name.
    static let sqlTextRunners: Set<String> = [
        "query_to_xml", "query_to_xml_and_xmlschema", "ts_stat", "ts_rewrite", "dblink", "dblink_exec",
        "dblink_send_query", "dblink_open", "openquery", "openrowset", "crosstab", "crosstab2", "crosstab3", "crosstab4",
        "connectby", "xpath_table", "pg_background_launch", "pg_background_launch_v2", "pg_background_submit",
        "pg_background_submit_v2", "pg_background_run", "pg_background_run_v2", "pg_background_run_query",
        "pg_background_run_query_v2", "schedule", "schedule_in_database", "alter_job", "subscription_exec"
    ]

    // pg_cron's unschedule, and TimescaleDB's jobs and the policies that add or remove one.
    static let scheduledJobs: Set<String> = [
        "unschedule", "add_job", "delete_job", "add_retention_policy", "remove_retention_policy", "add_reorder_policy",
        "remove_reorder_policy", "add_compaction_policy", "remove_compaction_policy", "add_compression_policy",
        "remove_compression_policy", "add_continuous_aggregate_policy", "remove_continuous_aggregate_policy",
        "add_policies", "alter_policies", "remove_policies", "remove_all_policies"
    ]

    // TimescaleDB's functions that change a hypertable, or drop, move or rewrite its chunks. The data node ones are
    // gone since 2.14, and set_adaptive_chunking since 2.28, but older servers still have them.
    static let hypertablesAndChunks: Set<String> = [
        "create_hypertable", "add_dimension", "set_chunk_time_interval", "set_partitioning_interval",
        "set_number_partitions", "set_integer_now_func", "set_adaptive_chunking", "enable_chunk_skipping",
        "disable_chunk_skipping", "attach_tablespace", "detach_tablespace", "detach_tablespaces", "drop_chunks",
        "drop_chunk", "create_chunk", "compress_chunk", "decompress_chunk", "reorder_chunk", "move_chunk",
        "block_new_chunks", "allow_new_chunks", "create_distributed_hypertable", "add_data_node", "attach_data_node",
        "detach_data_node", "delete_data_node", "alter_data_node", "set_replication_factor",
        "create_distributed_restore_point"
    ]

    static let rolesAndGrants: Set<String> = [
        "pg_background_grant_privileges", "pg_background_revoke_privileges", "grant_pg_background_privileges",
        "revoke_pg_background_privileges", "pg_background_drop_executor_role"
    ]

    // DuckDB's query() and json_execute_serialized_sql() run the SELECT in their text, which can take a value from a
    // sequence; the second does so outside a read-only transaction (both measured on 2.0.0). The postgres, mysql and
    // sqlite extensions' query and execute functions run any statement on an attached database, and dbgen and dsdgen
    // create and fill tables. Elsewhere `query` is any function's name.
    static let duckDBCalls: Set<String> = [
        "query", "json_execute_serialized_sql", "postgres_query", "postgres_execute", "mysql_query", "mysql_execute",
        "sqlite_query", "dbgen", "dsdgen"
    ]
}
