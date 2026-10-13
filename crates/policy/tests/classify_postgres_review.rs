#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_policy::{StatementClass, classify};

fn class(sql: &str) -> StatementClass {
    classify(sql, "postgres").class
}

#[test]
fn explain_analyse_runs_the_statement_so_it_classifies_like_it() {
    for (sql, expected) in [
        ("EXPLAIN (ANALYSE) DELETE FROM t", StatementClass::Delete),
        (
            "EXPLAIN (ANALYSE, VERBOSE) UPDATE t SET a = 1 WHERE id = 1",
            StatementClass::Update,
        ),
        ("EXPLAIN (ANALYZE) DELETE FROM t", StatementClass::Delete),
        ("EXPLAIN (analyse true) DELETE FROM t", StatementClass::Delete),
    ] {
        assert_eq!(class(sql), expected, "{sql}");
    }
}

#[test]
fn explain_analyse_switched_off_or_plain_explain_stays_a_read() {
    for sql in [
        "EXPLAIN (ANALYSE off) DELETE FROM t",
        "EXPLAIN (ANALYSE false) DELETE FROM t",
        "EXPLAIN DELETE FROM t",
        "EXPLAIN (VERBOSE) SELECT 1",
    ] {
        assert_eq!(class(sql), StatementClass::Select, "{sql}");
    }
}

#[test]
fn dynamic_sql_and_side_effect_functions_are_administrative() {
    for sql in [
        "SELECT query_to_xml_and_xmlschema('select 1', true, false, '')",
        "SELECT query_to_xmlschema('select 1', true, false, '')",
        "SELECT query_to_xml('select 1', true, false, '')",
        "SELECT pg_notify('c', 'x')",
        "SELECT pg_logical_emit_message(true, 'a', 'b')",
        "SELECT pg_stat_reset()",
        "SELECT pg_stat_reset_shared('bgwriter')",
        "SELECT lo_creat(-1)",
        "SELECT lo_from_bytea(0, 'x')",
        "SELECT pg_replication_slot_advance('s', '0/0')",
        "SELECT * FROM pg_logical_slot_get_changes('s', NULL, NULL)",
        "SELECT pg_ls_logicalsnapdir()",
        "SELECT pg_ls_replslotdir('x')",
        "SELECT pg_catalog.pg_ls_future_builtin()",
        "SELECT PG_CATALOG.pg_ls_future_builtin()",
        "SELECT pg_ls_future_builtin()",
        "SELECT * FROM crosstab('select 1, 2')",
        "SELECT * FROM public.crosstab('select 1, 2')",
        "SELECT public.PG_NOTIFY('c', 'x')",
    ] {
        assert_eq!(class(sql), StatementClass::Administrative, "{sql}");
    }
}

#[test]
fn ordinary_reads_stay_reads() {
    for sql in [
        "SELECT now()",
        "SELECT lower('A')",
        "SELECT count(*) FROM pg_stat_activity",
        "SELECT * FROM pg_stat_database",
        "SELECT pg_size_pretty(pg_database_size(current_database()))",
    ] {
        assert_eq!(class(sql), StatementClass::Select, "{sql}");
    }
}

#[test]
fn schema_qualified_user_functions_with_admin_prefixes_stay_reads() {
    for sql in [
        "SELECT public.pg_ls_customer_data()",
        "SELECT app.pg_logical_report()",
        "SELECT reporting.pg_replication_status()",
        "SELECT app.pg_stat_reset_report()",
        "SELECT app.crosstab_report()",
        "SELECT \"PG_CATALOG\".pg_ls_customer_data()",
    ] {
        assert_eq!(class(sql), StatementClass::Select, "{sql}");
    }
}
