use super::*;

#[test]
fn select_is_read() {
    let f = classify("SELECT * FROM users WHERE id = 1", "postgres");
    assert!(!f.writes());
    assert_eq!(f.class, StatementClass::Select);
    assert!(f.tables.iter().any(|t| t.contains("users")));
}

#[test]
fn guard_analysis_supplies_classification_masking_and_blast_radius_from_one_parse() {
    let patterns = vec!["pan".to_owned()];
    let read = analyze_statement("SELECT pan AS p FROM cards", "postgres", &patterns);
    assert!(read.facts.effects.contains(Effects::READS));
    assert_eq!(read.sensitive_positions, Some(vec![true]));
    assert!(read.blast_radius.is_none());

    let mutation = analyze_statement("UPDATE cards SET pan = 'x' WHERE id = 1", "postgres", &patterns);
    assert!(mutation.facts.effects.contains(Effects::WRITES_ROWS));
    assert!(mutation.sensitive_positions.is_none());
    assert!(matches!(
        mutation.blast_radius,
        Some(blast_radius::BlastRadiusRewrite::CountQuery(_))
    ));
    assert_eq!(mutation.known_statement_rows, vec![None]);

    let insert = analyze_statement("INSERT INTO cards (pan) VALUES ('x')", "postgres", &patterns);
    assert_eq!(insert.known_statement_rows, vec![Some(1)]);
    assert_eq!(insert.blast_radius, Some(blast_radius::BlastRadiusRewrite::Known(1)));
}

#[test]
fn insert_is_mutating_dml() {
    let f = classify("INSERT INTO t (a) VALUES (1)", "postgres");
    assert!(f.writes());
    assert_eq!(f.class, StatementClass::Insert);
    assert!(
        f.contains_mutating_dml(),
        "an unbounded INSERT ... SELECT must still be subject to a blast-radius check"
    );
}

#[test]
fn grant_copy_and_merge_name_their_targets() {
    let grant = classify("GRANT ALL ON payments TO evil", "postgres");
    assert_eq!(grant.tables, vec!["payments".to_string()]);
    assert_eq!(grant.class, StatementClass::Ddl);

    let revoke = classify("REVOKE ALL ON payments FROM evil", "postgres");
    assert_eq!(revoke.tables, vec!["payments".to_string()]);

    let copy_from = classify("COPY payments FROM '/tmp/x.csv'", "postgres");
    assert_eq!(copy_from.tables, vec!["payments".to_string()]);

    let copy_to = classify("COPY payments TO STDOUT", "postgres");
    assert_eq!(copy_to.tables, vec!["payments".to_string()]);

    let merge = classify(
        "MERGE INTO payments USING staged ON payments.id = staged.id WHEN MATCHED THEN DELETE",
        "postgres",
    );
    assert_eq!(merge.tables, vec!["payments".to_string()]);
    assert!(
        merge.contains_unknown_write(),
        "MERGE stays on the fail-closed catch-all"
    );

    let create_fn = classify(
        "CREATE FUNCTION audit_hook() RETURNS void AS $$ SELECT 1 $$ LANGUAGE sql",
        "postgres",
    );
    assert_eq!(create_fn.tables, vec!["audit_hook".to_string()]);
}

#[test]
fn delete_without_where() {
    let f = classify("DELETE FROM payments", "postgres");
    assert!(f.writes());
    assert_eq!(f.class, StatementClass::Delete);
    assert!(!f.has_where);
}

#[test]
fn update_with_where() {
    let f = classify("UPDATE payments SET status = 'ok' WHERE id = 1", "postgres");
    assert!(f.writes());
    assert_eq!(f.class, StatementClass::Update);
    assert!(f.has_where);
}

#[test]
fn data_modifying_cte_is_write() {
    let sql = "WITH d AS (DELETE FROM payments WHERE id = 1 RETURNING *) SELECT * FROM d";
    let f = classify(sql, "postgres");
    assert!(f.writes(), "data-modifying CTE must report writes=true: {f:?}");
}

#[test]
fn values_and_recursive_values_cte_are_reads() {
    for sql in [
        "VALUES (1), (2)",
        "WITH RECURSIVE counter(value) AS (VALUES(0) UNION ALL SELECT value + 1 FROM counter WHERE value < 10) SELECT sum(value) FROM counter",
    ] {
        let facts = classify(sql, "sqlite");
        assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}, facts: {facts:?}");
        assert!(!facts.writes(), "SQL: {sql}, facts: {facts:?}");
    }
}

#[test]
fn insert_select_cte_write() {
    let sql = "WITH x AS (INSERT INTO t(a) VALUES (1) RETURNING a) SELECT * FROM x";
    let f = classify(sql, "postgres");
    assert!(f.writes());
}

#[test]
fn multi_statement_flagged() {
    let f = classify("SELECT 1; DELETE FROM t", "postgres");
    assert!(f.is_multi_statement);
    assert!(f.writes());
}

#[test]
fn mixed_script_preserves_ddl_in_both_orders() {
    for sql in [
        "DROP TABLE protected_data; INSERT INTO audit_log VALUES (1)",
        "INSERT INTO audit_log VALUES (1); DROP TABLE protected_data",
    ] {
        let facts = classify(sql, "postgres");
        assert!(facts.contains_ddl(), "SQL: {sql}");
    }
}

#[test]
fn mixed_script_preserves_unknown_writes_in_both_orders() {
    for sql in [
        "SET session_replication_role = replica; INSERT INTO jobs(id) VALUES (1)",
        "INSERT INTO jobs(id) VALUES (1); SET session_replication_role = replica",
    ] {
        let facts = classify(sql, "postgres");
        assert!(facts.contains_unknown_write(), "SQL: {sql}");
    }
}

#[test]
fn mixed_script_preserves_unscoped_dml_in_both_orders() {
    for sql in [
        "DELETE FROM protected_data; CREATE TABLE replacement(id integer)",
        "CREATE TABLE replacement(id integer); DELETE FROM protected_data",
    ] {
        let facts = classify(sql, "postgres");
        assert!(facts.contains_mutating_dml(), "SQL: {sql}");
        assert!(facts.contains_unscoped_dml, "SQL: {sql}");
    }
}

#[test]
fn parse_failure_fail_closed() {
    let f = classify("SELECCT * FROM", "postgres");
    assert_eq!(f.class, StatementClass::Unparseable);
    assert!(f.writes());
    assert!(f.parse_error.is_some());
}

#[test]
fn truncate_is_ddl_write() {
    let f = classify("TRUNCATE TABLE payments", "postgres");
    assert!(f.writes() && f.contains_mutating_dml() && f.contains_unscoped_dml);
    assert_eq!(f.class, StatementClass::Ddl);
}

#[test]
fn broader_schema_and_privilege_changes_are_ddl() {
    for sql in [
        "CREATE SCHEMA reporting",
        "CREATE SEQUENCE job_ids",
        "CREATE FUNCTION answer() RETURNS integer LANGUAGE SQL AS 'SELECT 42'",
        "GRANT SELECT ON TABLE jobs TO analyst",
        "REVOKE SELECT ON TABLE jobs FROM analyst",
    ] {
        let facts = classify(sql, "postgres");
        assert!(facts.contains_ddl(), "SQL: {sql}, facts: {facts:?}");
    }
}

#[test]
fn mysql_delete() {
    let f = classify("DELETE FROM t WHERE id = 1", "mysql");
    assert_eq!(f.class, StatementClass::Delete);
    assert!(f.has_where);
}

#[test]
fn mysql_executable_comment_cannot_hide_a_file_write_from_policy() {
    for sql in [
        "SELECT 'payload' /*! INTO OUTFILE '/tmp/bookiee-policy.csv' */",
        "SELECT 1 /*M!100100 INTO OUTFILE '/tmp/bookiee-policy.csv' */",
    ] {
        let facts = classify(sql, "mysql");
        assert_eq!(facts.class, StatementClass::Unparseable, "SQL: {sql}, facts: {facts:?}");
        assert!(facts.writes(), "SQL: {sql}, facts: {facts:?}");
    }

    for sql in [
        "SELECT '/*! INTO OUTFILE ''/tmp/file'' */'",
        "SELECT 1 /* INTO OUTFILE '/tmp/file' */",
    ] {
        let facts = classify(sql, "mysql");
        assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}, facts: {facts:?}");
        assert!(!facts.writes(), "SQL: {sql}, facts: {facts:?}");
    }
}

#[test]
fn mssql_update() {
    let f = classify("UPDATE dbo.t SET a = 1 WHERE a = 2", "mssql");
    assert_eq!(f.class, StatementClass::Update);
    assert!(f.has_where);
}

#[test]
fn postgres_terminate_backend_is_administrative() {
    let facts = classify("SELECT pg_terminate_backend(42)", "postgres");
    assert_eq!(facts.class, StatementClass::Administrative);
    assert!(facts.writes());
}

#[test]
fn postgres_side_effecting_functions_are_administrative() {
    for sql in [
        "SELECT pg_promote()",
        "SELECT nextval('jobs_id_seq')",
        "SELECT setval('jobs_id_seq', 10)",
        "SELECT pg_advisory_lock(42)",
        "SELECT pg_try_advisory_lock(42)",
        "SELECT pg_wal_replay_pause()",
        "SELECT pg_wal_replay_resume()",
        "SELECT set_config('work_mem', '64MB', false)",
        "SELECT pg_file_write('/tmp/x', 'y', false)",
        "SELECT pg_file_unlink('/tmp/x')",
        "SELECT dblink_open('c', 'select 1')",
        "SELECT dblink_fetch('c', 10)",
        "SELECT dblink_connect_u('c', 'dbname=x')",
        "SELECT pg_stat_statements_reset()",
    ] {
        let facts = classify(sql, "postgres");
        assert_eq!(facts.class, StatementClass::Administrative, "SQL: {sql}");
        assert!(facts.writes(), "SQL: {sql}");
    }
}

#[test]
fn sqlite_fileio_functions_are_administrative() {
    for sql in [
        "SELECT writefile('/home/user/.bashrc', 'evil')",
        "SELECT readfile('/etc/shadow')",
        "SELECT load_extension('/tmp/evil.so')",
    ] {
        let facts = classify(sql, "sqlite");
        assert_eq!(facts.class, StatementClass::Administrative, "SQL: {sql}");
        assert!(facts.writes(), "SQL: {sql}");
    }
    let facts = classify("SELECT writefile(a, b) FROM t", "postgres");
    assert_ne!(facts.class, StatementClass::Administrative);
}

#[test]
fn administrative_function_nested_in_expression_is_detected() {
    let facts = classify("SELECT coalesce(pg_cancel_backend(42), false)", "postgres");
    assert_eq!(facts.class, StatementClass::Administrative);
    assert!(facts.writes());
}

#[test]
fn administrative_function_in_predicate_is_detected() {
    let facts = classify("SELECT 1 WHERE pg_terminate_backend(42)", "postgres");
    assert_eq!(facts.class, StatementClass::Administrative);
    assert!(facts.writes());
}

#[test]
fn administrative_function_name_in_literal_or_comment_is_not_a_call() {
    for sql in [
        "SELECT 'pg_terminate_backend(42)'",
        "SELECT 1 -- pg_terminate_backend(42)",
        "SELECT 1 /* pg_terminate_backend(42) */",
    ] {
        let facts = classify(sql, "postgres");
        assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}");
        assert!(!facts.writes(), "SQL: {sql}");
    }
}

#[test]
fn mysql_kill_is_administrative() {
    let facts = classify("KILL 42", "mysql");
    assert_eq!(facts.class, StatementClass::Administrative);
    assert!(facts.writes());
}

#[test]
fn plain_explain_of_a_select_is_a_read() {
    let facts = classify("EXPLAIN SELECT id FROM users", "postgres");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
    assert!(!facts.contains_unknown_write());
    assert_eq!(facts.tables, vec!["users".to_string()]);
}

#[test]
fn plain_explain_of_a_write_does_not_execute_it() {
    let facts = classify("EXPLAIN DELETE FROM users", "postgres");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
    assert!(!facts.contains_mutating_dml());
    assert!(!facts.contains_unscoped_dml);
}

#[test]
fn explain_verbose_of_a_select_is_a_read() {
    let facts = classify("EXPLAIN (VERBOSE) SELECT id FROM users", "postgres");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
}

#[test]
fn explain_analyze_keeps_the_inner_statement_facts() {
    let facts = classify("EXPLAIN ANALYZE DELETE FROM users", "postgres");
    assert_eq!(facts.class, StatementClass::Delete);
    assert!(facts.writes());
    assert!(facts.contains_mutating_dml());
    assert!(facts.contains_unscoped_dml);
    assert_eq!(facts.tables, vec!["users".to_string()]);
}

#[test]
fn explain_with_a_parenthesized_analyze_option_is_a_write() {
    let facts = classify("EXPLAIN (ANALYZE) UPDATE users SET name = 'x'", "postgres");
    assert_eq!(facts.class, StatementClass::Update);
    assert!(facts.writes());
    assert!(facts.contains_unscoped_dml);
}

#[test]
fn explain_with_analyze_disabled_is_a_read() {
    for sql in [
        "EXPLAIN (ANALYZE false) DELETE FROM users",
        "EXPLAIN (ANALYZE off) DELETE FROM users",
        "EXPLAIN (ANALYZE 0) DELETE FROM users",
    ] {
        let facts = classify(sql, "postgres");
        assert_eq!(facts.class, StatementClass::Select, "SQL: {sql}");
        assert!(!facts.writes(), "SQL: {sql}");
    }
}

#[test]
fn describe_table_is_a_read() {
    let facts = classify("DESCRIBE users", "mysql");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
}

#[test]
fn only_a_provable_read_skips_the_write_capability_check() {
    for sql in ["SELECT 1", "SELECT id FROM t WHERE id = 1"] {
        assert!(!statement_requires_write_capability(sql, "postgres"), "{sql}");
    }
    for sql in [
        "DELETE FROM t WHERE id = 1",
        "CREATE TABLE t (id int)",
        "SELECT pg_read_file('/etc/passwd')",
        "COPY t TO PROGRAM 'sh'",
        "this is not sql at all",
        "",
    ] {
        assert!(statement_requires_write_capability(sql, "postgres"), "{sql}");
    }
}
