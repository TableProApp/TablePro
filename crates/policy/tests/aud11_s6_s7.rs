#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Environment;
use tablepro_policy::{Decision, PolicyConfig, Principal, classify, evaluate};

fn human_decision(sql: &str, environment: Environment, policy: &tablepro_policy::EnvPolicy) -> Decision {
    evaluate(
        &Principal::human_gui(),
        environment,
        &classify(sql, "postgres"),
        false,
        policy,
        None,
    )
}

fn requires_approval(decision: &Decision) -> bool {
    matches!(decision, Decision::RequireApproval { .. })
}

#[test]
fn malformed_writes_still_need_approval_when_write_approval_is_on() {
    let mut policy = PolicyConfig::default().for_environment(Environment::Prod);
    policy.human_approve_unparseable = false;
    assert!(policy.human_approve_writes);

    for sql in [
        "DELETE;",
        "DELET FROM payments",
        "DELETE FROM payments; SELECCT 1",
        "SELECCT 1; DELETE FROM payments",
    ] {
        let decision = human_decision(sql, Environment::Prod, &policy);
        assert!(requires_approval(&decision), "{sql}: {decision:?}");
    }
}

#[test]
fn unparseable_sql_needs_approval_even_when_local_writes_and_ddl_are_permissive() {
    let mut policy = PolicyConfig::default().for_environment(Environment::Local);
    policy.human_approve_unparseable = false;
    assert!(!policy.human_approve_writes);
    assert!(!policy.human_approve_ddl);

    let decision = human_decision("SELECCT 1", Environment::Local, &policy);
    assert!(requires_approval(&decision), "{decision:?}");
}

#[test]
fn administrative_host_access_needs_human_approval_in_local_and_staging() {
    for environment in [Environment::Local, Environment::Staging] {
        let policy = PolicyConfig::default().for_environment(environment);
        let decision = human_decision("COPY users TO PROGRAM 'echo unsafe'", environment, &policy);
        assert!(requires_approval(&decision), "{environment:?}: {decision:?}");
    }
}

#[test]
fn merge_delete_needs_human_approval_in_local_and_staging() {
    let sql = "MERGE INTO users USING staged ON users.id = staged.id WHEN MATCHED THEN DELETE";
    for environment in [Environment::Local, Environment::Staging] {
        let policy = PolicyConfig::default().for_environment(environment);
        let decision = human_decision(sql, environment, &policy);
        assert!(requires_approval(&decision), "{environment:?}: {decision:?}");
    }
}

#[test]
fn truncate_needs_human_approval_even_when_local_ddl_is_permissive() {
    let policy = PolicyConfig::default().for_environment(Environment::Local);
    assert!(!policy.human_approve_ddl);
    let decision = human_decision("TRUNCATE TABLE users", Environment::Local, &policy);
    assert!(requires_approval(&decision), "{decision:?}");
}

#[test]
fn ordinary_local_create_table_stays_allowed_without_ddl_approval() {
    let policy = PolicyConfig::default().for_environment(Environment::Local);
    let decision = human_decision("CREATE TABLE users(id INTEGER)", Environment::Local, &policy);
    assert!(matches!(decision, Decision::Allow { .. }), "{decision:?}");
}
