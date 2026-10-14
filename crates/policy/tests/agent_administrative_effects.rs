#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_core::Environment;
use tablepro_policy::{Decision, PolicyConfig, Principal, WritePolicy, classify, evaluate};

fn evaluate_agent(sql: &str, driver_id: &str) -> Decision {
    let mut config = PolicyConfig::default();
    let local = config.environments.entry("local".into()).or_default();
    local.agent_writes = Some(WritePolicy::Allow);
    evaluate(
        &Principal::Agent {
            token: "test-token".into(),
            client: None,
            model: None,
        },
        Environment::Local,
        &classify(sql, driver_id),
        false,
        &config.for_environment(Environment::Local),
        None,
    )
}

#[test]
fn permissive_agent_write_policy_does_not_allow_administrative_mysql_effects() {
    for sql in [
        "SELECT GET_LOCK('bookie', 1)",
        "DELETE FROM jobs WHERE GET_LOCK('bookie', 1)",
    ] {
        assert!(
            matches!(evaluate_agent(sql, "mysql"), Decision::Deny { .. }),
            "administrative effects must remain denied: {sql}"
        );
    }

    assert!(matches!(
        evaluate_agent("SELECT id FROM jobs", "mysql"),
        Decision::Allow { .. }
    ));
}
