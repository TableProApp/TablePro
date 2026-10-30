//! Built-in functions that change state from inside a SELECT, by family.
//!
//! A read-only transaction stops none of them on PostgreSQL 15 and
//! earlier: they signal other sessions, take locks, run SQL text on
//! another connection or write large objects. A function the user wrote
//! is beyond what the words show.

const SERVER_SIGNALS: &[&str] = &[
    "pg_cancel_backend",
    "pg_terminate_backend",
    "pg_reload_conf",
    "pg_rotate_logfile",
    "pg_log_backend_memory_contexts",
];

const SESSION_CONTROL: &[&str] = &[
    "system$abort_session",
    "system$cancel_query",
    "system$cancel_all_queries",
    "system$abort_transaction",
    "abortsessions",
];

const RECOVERY_AND_BACKUP: &[&str] = &[
    "pg_promote",
    "pg_wal_replay_pause",
    "pg_wal_replay_resume",
    "pg_backup_start",
    "pg_backup_stop",
    "pg_switch_wal",
    "pg_create_restore_point",
    "pg_log_standby_snapshot",
    "pg_start_backup",
    "pg_stop_backup",
    "pg_switch_xlog",
    "pg_xlog_replay_pause",
    "pg_xlog_replay_resume",
];

const REPLICATION: &[&str] = &[
    "pg_create_physical_replication_slot",
    "pg_create_logical_replication_slot",
    "pg_copy_physical_replication_slot",
    "pg_copy_logical_replication_slot",
    "pg_drop_replication_slot",
    "pg_replication_slot_advance",
    "pg_sync_replication_slots",
    "pg_logical_slot_get_changes",
    "pg_logical_slot_get_binary_changes",
    "pg_logical_emit_message",
    "pg_replication_origin_create",
    "pg_replication_origin_drop",
    "pg_replication_origin_advance",
    "pg_replication_origin_session_setup",
    "pg_replication_origin_session_reset",
    "pg_replication_origin_xact_setup",
    "pg_replication_origin_xact_reset",
];

const SEQUENCES: &[&str] = &["nextval", "setval"];

const ADVISORY_LOCKS: &[&str] = &[
    "pg_advisory_lock",
    "pg_advisory_lock_shared",
    "pg_advisory_unlock",
    "pg_advisory_unlock_shared",
    "pg_advisory_unlock_all",
    "pg_advisory_xact_lock",
    "pg_advisory_xact_lock_shared",
    "pg_try_advisory_lock",
    "pg_try_advisory_lock_shared",
    "pg_try_advisory_xact_lock",
    "pg_try_advisory_xact_lock_shared",
    "get_lock",
    "release_lock",
    "release_all_locks",
];

const SETTINGS_AND_STATISTICS: &[&str] = &[
    "set_config",
    "pg_notify",
    "pg_stat_reset",
    "pg_stat_reset_shared",
    "pg_stat_reset_single_table_counters",
    "pg_stat_reset_single_function_counters",
    "pg_stat_reset_slru",
    "pg_stat_reset_replication_slot",
    "pg_stat_reset_subscription_stats",
    "pg_stat_statements_reset",
    "pg_restore_relation_stats",
    "pg_restore_attribute_stats",
    "pg_clear_relation_stats",
    "pg_clear_attribute_stats",
];

const LARGE_OBJECTS: &[&str] = &[
    "lo_create",
    "lo_creat",
    "lo_unlink",
    "lo_from_bytea",
    "lo_put",
    "lowrite",
    "lo_truncate",
    "lo_truncate64",
    "lo_import",
    "lo_export",
];

const INDEX_MAINTENANCE: &[&str] = &[
    "brin_summarize_new_values",
    "brin_summarize_range",
    "brin_desummarize_range",
    "gin_clean_pending_list",
];

/// Functions that run SQL text: what that text does is not in the words.
const SQL_TEXT_RUNNERS: &[&str] = &[
    "query_to_xml",
    "query_to_xml_and_xmlschema",
    "ts_stat",
    "ts_rewrite",
    "dblink",
    "dblink_exec",
    "dblink_send_query",
    "dblink_open",
];

const EXTENSIONS: &[&str] = &["load_extension"];

const FAMILIES: [&[&str]; 11] = [
    SERVER_SIGNALS,
    SESSION_CONTROL,
    RECOVERY_AND_BACKUP,
    REPLICATION,
    SEQUENCES,
    ADVISORY_LOCKS,
    SETTINGS_AND_STATISTICS,
    LARGE_OBJECTS,
    INDEX_MAINTENANCE,
    SQL_TEXT_RUNNERS,
    EXTENSIONS,
];

/// Whether a call of `name` can change state, compared without regard
/// to case.
pub(crate) fn changes_state(name: &str) -> bool {
    FAMILIES
        .iter()
        .flat_map(|family| family.iter())
        .any(|known| name.eq_ignore_ascii_case(known))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_family_is_matched_whatever_the_case() {
        for name in [
            "PG_TERMINATE_BACKEND",
            "dblink",
            "DBLINK_EXEC",
            "lo_creat",
            "lowrite",
            "query_to_xml",
            "ts_stat",
            "pg_notify",
            "pg_advisory_lock",
            "GET_LOCK",
            "pg_logical_slot_get_changes",
            "pg_replication_origin_create",
            "gin_clean_pending_list",
            "load_extension",
        ] {
            assert!(changes_state(name), "{name}");
        }
        for name in [
            "currval",
            "pg_backend_pid",
            "lo_get",
            "count",
            "dblink_build_sql_insert",
        ] {
            assert!(!changes_state(name), "{name}");
        }
    }

    #[test]
    fn no_name_is_listed_twice() {
        let mut names: Vec<String> = FAMILIES
            .iter()
            .flat_map(|family| family.iter())
            .map(|name| name.to_ascii_lowercase())
            .collect();
        let listed = names.len();
        names.sort();
        names.dedup();
        assert_eq!(names.len(), listed);
    }
}
