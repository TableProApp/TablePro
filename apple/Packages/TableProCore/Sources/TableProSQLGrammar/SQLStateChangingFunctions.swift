import Foundation

public enum SQLStateChangingFunctions {
    public static func contains(_ name: String) -> Bool {
        names.contains(name.lowercased())
    }

    // SQLite runs a table-valued pragma named as a table source too, so `SELECT * FROM main.pragma_optimize` runs
    // ANALYZE. A call is the call scanner's; a column or alias of that name runs nothing.
    public static func namesStateChangingTable(in statement: String, grammar: SQLLexicalGrammar) -> Bool {
        guard tableFunctions.contains(where: { statement.range(of: $0, options: .caseInsensitive) != nil }) else {
            return false
        }
        let text = statement as NSString
        var listsTables: [Int: Bool] = [:]
        var expectsTable = false
        var namesTable = false
        for token in TSQLTokens.read(text, grammar: grammar) {
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

    private static let names: Set<String> = serverSignals
        .union(sessionControl)
        .union(recoveryAndBackup)
        .union(replication)
        .union(sequences)
        .union(advisoryLocks)
        .union(settingsAndStatistics)
        .union(largeObjects)
        .union(filesAndExtensions)
        .union(indexMaintenance)
        .union(sqlTextRunners)

    private static let serverSignals: Set<String> = [
        "pg_cancel_backend", "pg_terminate_backend", "pg_reload_conf", "pg_rotate_logfile",
        "pg_log_backend_memory_contexts"
    ]

    private static let sessionControl: Set<String> = [
        "system$abort_session", "system$cancel_query", "system$cancel_all_queries", "system$abort_transaction",
        "abortsessions"
    ]

    private static let recoveryAndBackup: Set<String> = [
        "pg_promote", "pg_wal_replay_pause", "pg_wal_replay_resume", "pg_backup_start", "pg_backup_stop",
        "pg_switch_wal", "pg_create_restore_point", "pg_log_standby_snapshot", "pg_start_backup", "pg_stop_backup",
        "pg_switch_xlog", "pg_xlog_replay_pause", "pg_xlog_replay_resume"
    ]

    private static let replication: Set<String> = [
        "pg_create_physical_replication_slot", "pg_create_logical_replication_slot",
        "pg_copy_physical_replication_slot", "pg_copy_logical_replication_slot", "pg_drop_replication_slot",
        "pg_replication_slot_advance", "pg_sync_replication_slots", "pg_logical_slot_get_changes",
        "pg_logical_slot_get_binary_changes", "pg_logical_emit_message", "pg_replication_origin_create",
        "pg_replication_origin_drop", "pg_replication_origin_advance", "pg_replication_origin_session_setup",
        "pg_replication_origin_session_reset", "pg_replication_origin_xact_setup",
        "pg_replication_origin_xact_reset"
    ]

    private static let sequences: Set<String> = ["nextval", "setval"]

    private static let advisoryLocks: Set<String> = [
        "pg_advisory_lock", "pg_advisory_lock_shared", "pg_advisory_unlock", "pg_advisory_unlock_shared",
        "pg_advisory_unlock_all", "pg_advisory_xact_lock", "pg_advisory_xact_lock_shared", "pg_try_advisory_lock",
        "pg_try_advisory_lock_shared", "pg_try_advisory_xact_lock", "pg_try_advisory_xact_lock_shared", "get_lock",
        "release_lock", "release_all_locks"
    ]

    private static let settingsAndStatistics: Set<String> = [
        "set_config", "pg_notify", "pg_stat_reset", "pg_stat_reset_shared", "pg_stat_reset_single_table_counters",
        "pg_stat_reset_single_function_counters", "pg_stat_reset_slru", "pg_stat_reset_replication_slot",
        "pg_stat_reset_subscription_stats", "pg_stat_statements_reset", "pg_restore_relation_stats",
        "pg_restore_attribute_stats", "pg_clear_relation_stats", "pg_clear_attribute_stats"
    ]

    private static let largeObjects: Set<String> = [
        "lo_create", "lo_creat", "lo_unlink", "lo_from_bytea", "lo_put", "lowrite", "lo_truncate", "lo_truncate64"
    ]

    // The Mac flags these through its file markers too; iOS has only this list.
    private static let filesAndExtensions: Set<String> = [
        "lo_import", "lo_export", "pg_file_write", "writefile", "load_extension"
    ]

    // SQLite's pragma_optimize table function runs ANALYZE, measured on 3.54.0. No other pragma function takes a value.
    private static let indexMaintenance: Set<String> = [
        "brin_summarize_new_values", "brin_summarize_range", "brin_desummarize_range", "gin_clean_pending_list",
        "pragma_optimize"
    ]

    // SQL Server's OPENQUERY and OPENROWSET hand their last argument to a linked server, or back to this one through
    // a loopback link, as a batch of its own: a SELECT from either can carry a DELETE, as a SELECT from dblink can.
    private static let sqlTextRunners: Set<String> = [
        "query_to_xml", "query_to_xml_and_xmlschema", "ts_stat", "ts_rewrite", "dblink", "dblink_exec",
        "dblink_send_query", "dblink_open", "openquery", "openrowset"
    ]
}
