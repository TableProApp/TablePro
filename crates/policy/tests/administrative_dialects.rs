#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::Environment;
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan};
use tablepro_policy::{Decision, PolicyConfig, Principal, StatementClass, classify, evaluate};

fn agent() -> Principal {
    Principal::Agent {
        token: "token".into(),
        client: None,
        model: None,
    }
}

fn agent_decision(sql: &str, driver_id: &str) -> Decision {
    let facts = classify(sql, driver_id);
    evaluate(
        &agent(),
        Environment::Local,
        &facts,
        false,
        &PolicyConfig::default().for_environment(Environment::Local),
        None,
    )
}

fn assert_admin_denied(sql: &str, driver_id: &str) {
    let facts = classify(sql, driver_id);
    assert_eq!(
        facts.class,
        StatementClass::Administrative,
        "{driver_id} must classify as administrative: {sql}"
    );
    assert!(
        facts.writes(),
        "{driver_id} administrative calls must count as writes: {sql}"
    );
    let decision = agent_decision(sql, driver_id);
    let Decision::Deny { ref rule, .. } = decision else {
        panic!("{driver_id} must deny an agent: {sql}, got {decision:?}");
    };
    assert!(
        rule.split('+').any(|name| name == "agent_admin_denied"),
        "{driver_id} must retain the admin rule: {sql}, got {decision:?}"
    );
}

#[test]
fn mysql_server_control_functions_are_administrative() {
    for sql in [
        "SELECT sleep(30)",
        "SELECT benchmark(1000000, md5('x'))",
        "SELECT load_file('/etc/passwd')",
        "SELECT * FROM orders WHERE id = 1 AND sleep(5)",
    ] {
        assert_admin_denied(sql, "mysql");
    }
}

#[test]
fn sql_server_extended_and_system_procedures_are_administrative() {
    for sql in [
        "EXEC xp_cmdshell 'dir'",
        "EXECUTE xp_regread 'HKEY_LOCAL_MACHINE'",
        "EXEC sp_configure 'show advanced options', 1",
        "EXEC sp_who",
    ] {
        assert_admin_denied(sql, "mssql");
    }
}

#[test]
fn kill_is_administrative_on_every_engine_that_parses_it() {
    for driver_id in ["mysql", "mssql"] {
        assert_admin_denied("KILL 42", driver_id);
    }
}

#[test]
fn an_ordinary_read_stays_a_read_on_every_engine() {
    for driver_id in ["postgres", "mysql", "mssql", "sqlite", "clickhouse"] {
        let facts = classify("SELECT id, name FROM customers WHERE id = 1", driver_id);
        assert_eq!(facts.class, StatementClass::Select, "driver {driver_id}");
        assert!(!facts.writes(), "driver {driver_id}");
    }
}

#[test]
fn corrected_lexer_keeps_reads_intact_and_following_mutations_denied() {
    for (driver, read) in [
        ("mysql", "SELECT 'a\\';b'"),
        ("postgres", "SELECT 1 /* outer /* inner */ ; outer */"),
    ] {
        let sql = format!("{read}; DELETE FROM protected_items");
        let statements = tablepro_core::sql_lex::split_statements(&sql, driver);
        assert_eq!(statements, vec![read, "DELETE FROM protected_items"]);
        assert_eq!(classify(&statements[0], driver).class, StatementClass::Select);
        let decision = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &classify(&statements[1], driver),
            true,
            &PolicyConfig::default().for_environment(Environment::Local),
            None,
        );
        assert!(matches!(decision, Decision::Deny { .. }));
    }
}

#[test]
fn postgres_script_consumers_agree_across_crlf_comments_and_formatting() {
    let source = "-- lead :ignored ;\r\nSELECT :shown AS payload /* :hidden ; */, 'semi; :literal' AS quoted;\r\n-- between :ignored2 ;\r\nUPDATE items SET name = :name WHERE id = :id -- tail :ignored3 ;\r\n-- final :ignored4 ;\r\n";
    let grammar = SqlGrammar::PostgreSql;
    let settings = LexicalSettings::default_for(grammar);
    let original = ScriptPlan::build(source, grammar, settings);

    assert!(original.diagnostics().is_empty(), "{:?}", original.diagnostics());
    assert_eq!(original.statements().len(), 2);
    let original_statements = original
        .statements()
        .iter()
        .map(|statement| statement.text(source))
        .collect::<Vec<_>>();
    let expected_names = [vec!["shown"], vec!["name", "id"]];
    let expected_classes = [StatementClass::Select, StatementClass::Update];
    for (index, statement) in original_statements.iter().enumerate() {
        let parameters = tablepro_core::extract_named_parameters(statement, "postgres");
        assert_eq!(parameters.names, expected_names[index]);
        assert_eq!(classify(&parameters.sql, "postgres").class, expected_classes[index]);
    }

    let formatted = tablepro_core::sql_format::format_script(source, grammar, settings);
    for comment in [
        "-- lead :ignored ;",
        "/* :hidden ; */",
        "-- between :ignored2 ;",
        "-- tail :ignored3 ;",
        "-- final :ignored4 ;",
    ] {
        assert!(
            formatted.contains(comment),
            "formatter changed comment {comment:?}: {formatted}"
        );
    }
    let reformatted = ScriptPlan::build(&formatted, grammar, settings);
    assert!(reformatted.diagnostics().is_empty(), "{:?}", reformatted.diagnostics());
    assert_eq!(reformatted.statements().len(), 2);
    for (index, statement) in reformatted.statements().iter().enumerate() {
        let sql = statement.text(&formatted);
        let parameters = tablepro_core::extract_named_parameters(sql, "postgres");
        assert_eq!(parameters.names, expected_names[index]);
        let facts = classify(&parameters.sql, "postgres");
        assert_eq!(facts.class, expected_classes[index]);
        if expected_classes[index] == StatementClass::Update {
            assert_eq!(facts.tables, ["items"]);
            assert!(facts.has_where);
        }
    }
}

#[test]
fn an_engine_procedure_name_inside_a_literal_is_not_administrative() {
    let facts = classify("SELECT 'xp_cmdshell is not called here' AS note", "mssql");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
}

#[test]
fn a_column_named_like_a_control_function_is_not_administrative() {
    let facts = classify("SELECT sleep FROM naps WHERE id = 1", "mysql");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
}

#[test]
fn postgres_host_and_network_functions_are_administrative() {
    for sql in [
        "SELECT pg_read_file('/etc/passwd')",
        "SELECT pg_read_binary_file('/etc/shadow')",
        "SELECT pg_stat_file('/etc/passwd')",
        "SELECT pg_ls_dir('/')",
        "SELECT pg_ls_waldir()",
        "SELECT dblink('dbname=x', 'DELETE FROM t')",
        "SELECT query_to_xml('DELETE FROM t', true, true, '')",
        "SELECT id FROM t WHERE name = pg_read_file('/etc/passwd')",
        "SELECT pg_file_write('/tmp/x', 'payload', false)",
        "SELECT pg_file_unlink('/tmp/x')",
        "SELECT dblink_open('conn', 'cur', 'SELECT 1')",
        "SELECT dblink_fetch('conn', 'cur', 10)",
        "SELECT dblink_connect_u('conn', 'dbname=x')",
        "SELECT pg_stat_statements_reset()",
    ] {
        assert_admin_denied(sql, "postgres");
    }
}

#[test]
fn sqlite_fileio_functions_are_administrative() {
    for sql in [
        "SELECT writefile('/home/user/.bashrc', 'evil')",
        "SELECT readfile('/etc/shadow')",
        "SELECT load_extension('/tmp/evil.so')",
    ] {
        assert_admin_denied(sql, "sqlite");
    }
}

#[test]
fn a_read_only_connection_denies_a_postgres_host_read() {
    let facts = classify("SELECT pg_read_file('/etc/passwd')", "postgres");
    let decision = evaluate(
        &Principal::human_gui(),
        Environment::Local,
        &facts,
        true,
        &PolicyConfig::default().for_environment(Environment::Local),
        None,
    );
    assert!(
        matches!(decision, Decision::Deny { ref rule, .. } if rule == "connection_read_only"),
        "{decision:?}"
    );
}

#[test]
fn copy_that_reaches_the_host_is_administrative() {
    for sql in [
        "COPY t TO PROGRAM 'curl http://example.com'",
        "COPY t FROM PROGRAM 'sh -c whoami'",
        "COPY t TO '/tmp/exfiltrated.csv'",
        "COPY t FROM '/etc/passwd'",
    ] {
        assert_admin_denied(sql, "postgres");
    }
}

#[test]
fn copy_through_the_client_is_a_write_but_not_administrative() {
    for sql in ["COPY t TO STDOUT", "COPY t FROM STDIN"] {
        let facts = classify(sql, "postgres");
        assert_ne!(facts.class, StatementClass::Administrative, "{sql}");
        assert!(facts.writes(), "{sql}");
    }
}

#[test]
fn pg_sleep_stays_an_ordinary_read_because_timeouts_already_bound_it() {
    let facts = classify("SELECT pg_sleep(30)", "postgres");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
}

#[test]
fn a_column_named_like_a_host_function_is_not_administrative() {
    let facts = classify("SELECT pg_read_file FROM audit_log", "postgres");
    assert_ne!(facts.class, StatementClass::Administrative);
    assert!(!facts.writes());
}
