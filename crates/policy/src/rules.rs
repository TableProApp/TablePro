use tablepro_core::Environment;

use crate::classify::{StatementClass, StatementFacts};
use crate::config::EnvPolicy;
use crate::effects::Effects;
use crate::principal::Principal;
use crate::transaction_control::{TransactionControl, has_implicit_transaction_starter, transaction_control};
pub use crate::verdict::Decision;

pub fn evaluate(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    connection_read_only: bool,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Decision {
    evaluate_with_effects(
        principal,
        environment,
        facts,
        connection_read_only,
        env_policy,
        estimated_rows,
    )
}

pub(crate) fn evaluate_with_effects(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    connection_read_only: bool,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Decision {
    let effects = facts.effects;
    let mut decisions = evaluate_categorical_decisions(principal, environment, facts, connection_read_only, env_policy);
    if effects.writes()
        || facts.class == StatementClass::Unparseable
        || effects.contains(Effects::ADMIN)
        || effects.contains(Effects::HOST_OR_FILE_ACCESS)
        || effects.contains(Effects::UNKNOWN)
    {
        decisions.extend(evaluate_eligible_write_decisions(
            principal,
            environment,
            facts,
            env_policy,
            estimated_rows,
        ));
    }

    Decision::join_all(decisions).unwrap_or_else(|| Decision::Deny {
        rule: "no_policy_rules_applied".into(),
        message: "policy evaluation produced no verdict".into(),
    })
}

pub(crate) fn shared_connection_decision(sql: &str, driver_id: &str, facts: &StatementFacts) -> Option<Decision> {
    if (facts.class == StatementClass::Transaction && !facts.is_multi_statement)
        || has_implicit_transaction_starter(sql, driver_id)
        || has_unclosed_shared_transaction(sql, driver_id)
    {
        return Some(Decision::Deny {
            rule: "transaction_control_needs_session".into(),
            message: "BEGIN, COMMIT and ROLLBACK cannot run on a shared connection, because the transaction would not \
                      cover the statements after it. Turn on Session for this editor tab to keep a transaction \
                      open between statements, or send the whole transaction as one batch"
                .into(),
        });
    }
    None
}

fn has_unclosed_shared_transaction(sql: &str, driver_id: &str) -> bool {
    let statements = tablepro_core::sql_lex::split_statements(sql, driver_id);
    if statements.len() < 2 {
        return false;
    }

    let mut open = false;
    for statement in statements {
        match transaction_control(&statement, driver_id) {
            Some(
                TransactionControl::Begin
                | TransactionControl::BeginReadOnly
                | TransactionControl::BeginReadOnlySnapshot,
            ) if open => return true,
            Some(
                TransactionControl::Begin
                | TransactionControl::BeginReadOnly
                | TransactionControl::BeginReadOnlySnapshot,
            ) => open = true,
            Some(TransactionControl::Commit { chain } | TransactionControl::Rollback { chain }) => {
                if !open || chain {
                    return true;
                }
                open = false;
            }
            None if open => {
                let facts = crate::classify::classify(&statement, driver_id);
                if facts.class == StatementClass::Unparseable || (driver_id == "mysql" && facts.contains_ddl()) {
                    return true;
                }
            }
            None => {}
        }
    }
    open
}

pub(crate) fn evaluate_categorical(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    connection_read_only: bool,
    env_policy: &EnvPolicy,
) -> Option<Decision> {
    Decision::join_all(evaluate_categorical_decisions(
        principal,
        environment,
        facts,
        connection_read_only,
        env_policy,
    ))
}

fn evaluate_categorical_decisions(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    connection_read_only: bool,
    env_policy: &EnvPolicy,
) -> Vec<Decision> {
    let effects = facts.effects;
    let mut decisions = Vec::new();
    if connection_read_only && effects.writes() {
        decisions.push(Decision::Deny {
            rule: "connection_read_only".into(),
            message: "connection is marked read-only; statements that may write are not permitted".into(),
        });
    }

    if facts.class == StatementClass::Unparseable {
        return evaluate_unparseable_decisions(decisions, principal, environment, facts, env_policy);
    }

    if facts.is_multi_statement && principal.is_agent() && !env_policy.agent_allow_multi_statement {
        decisions.push(Decision::Deny {
            rule: "agent_no_multi_statement".into(),
            message: "agents may not run multi-statement scripts".into(),
        });
    }

    if facts.class == StatementClass::Administrative && principal.is_agent() {
        decisions.push(Decision::Deny {
            rule: "agent_admin_denied".into(),
            message: "agents may not run administrative database operations".into(),
        });
    }

    if !effects.writes() && !effects.contains(Effects::HOST_OR_FILE_ACCESS) {
        decisions.push(Decision::Allow {
            rule: "read_allow".into(),
        });
        return decisions;
    }

    if principal.is_agent() {
        decisions.extend(evaluate_agent_write_categorical(environment, facts, env_policy));
    } else {
        decisions.extend(evaluate_human_dangerous_effects(environment, facts, env_policy));
    }
    decisions
}

fn evaluate_unparseable_decisions(
    mut decisions: Vec<Decision>,
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
) -> Vec<Decision> {
    let unparseable = decide_unparseable(principal, env_policy);
    let explicitly_allowed = unparseable.is_allow();
    decisions.push(unparseable);
    if principal.is_agent() {
        return decisions;
    }
    if explicitly_allowed {
        decisions.extend(evaluate_human_dangerous_effects(environment, facts, env_policy));
    } else if env_policy.human_approve_writes {
        decisions.push(Decision::RequireApproval {
            rule: "human_write_approve".into(),
            reason: format!("writes require approval in {}", environment.as_str()),
            preview: None,
        });
    }
    decisions
}

fn evaluate_human_dangerous_effects(
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
) -> Vec<Decision> {
    let effects = facts.effects;
    let dangerous_effect = effects.contains(Effects::ADMIN)
        || effects.contains(Effects::HOST_OR_FILE_ACCESS)
        || effects.contains(Effects::UNKNOWN);
    if !dangerous_effect {
        return Vec::new();
    }

    let mut decisions = vec![Decision::RequireApproval {
        rule: "human_dangerous_effect_approval".into(),
        reason: "administrative, host-access or unknown write effects require confirmation".into(),
        preview: Some(table_preview(facts)),
    }];
    if env_policy.human_approve_writes {
        decisions.push(Decision::RequireApproval {
            rule: "human_write_approve".into(),
            reason: format!("writes require approval in {}", environment.as_str()),
            preview: Some(table_preview(facts)),
        });
    }
    decisions
}

pub(crate) fn evaluate_eligible_write(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Decision {
    Decision::join_all(evaluate_eligible_write_decisions(
        principal,
        environment,
        facts,
        env_policy,
        estimated_rows,
    ))
    .unwrap_or_else(|| Decision::Deny {
        rule: "no_policy_rules_applied".into(),
        message: "policy evaluation produced no verdict".into(),
    })
}

fn evaluate_eligible_write_decisions(
    principal: &Principal,
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Vec<Decision> {
    if facts.class == StatementClass::Unparseable {
        return vec![decide_unparseable(principal, env_policy)];
    }

    if principal.is_agent() {
        return evaluate_agent_write_decisions(environment, facts, env_policy, estimated_rows);
    }

    evaluate_human_write_decisions(environment, facts, env_policy, estimated_rows)
}

fn decide_unparseable(principal: &Principal, env_policy: &EnvPolicy) -> Decision {
    if principal.is_agent() {
        Decision::Deny {
            rule: "fail_closed_unparseable".into(),
            message: "SQL could not be parsed; agents are denied".into(),
        }
    } else if env_policy.human_approve_unparseable {
        Decision::RequireApproval {
            rule: "fail_closed_unparseable".into(),
            reason: "SQL could not be parsed; confirm before running".into(),
            preview: None,
        }
    } else {
        Decision::Allow {
            rule: "unparseable_human_allow".into(),
        }
    }
}

fn table_preview(facts: &StatementFacts) -> String {
    let mut tables = facts.tables.clone();
    tables.sort_unstable();
    tables.dedup();
    format!("tables: {}", tables.join(", "))
}

fn evaluate_agent_write_categorical(
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
) -> Vec<Decision> {
    let effects = facts.effects;
    let mut decisions = Vec::new();
    if effects.contains(Effects::HOST_OR_FILE_ACCESS) {
        decisions.push(Decision::Deny {
            rule: "agent_host_access_denied".into(),
            message: "agents may not access host files or external programs".into(),
        });
    }

    if env_policy.agent_writes == crate::config::WritePolicy::Deny {
        decisions.push(Decision::Deny {
            rule: "agent_writes_denied".into(),
            message: format!("agent writes are denied in {}", environment.as_str()),
        });
    }

    if facts.contains_ddl() && !env_policy.agent_allow_ddl {
        decisions.push(Decision::Deny {
            rule: "agent_ddl_denied".into(),
            message: "agents may not run DDL".into(),
        });
    }

    if facts.contains_unknown_write() {
        decisions.push(Decision::Deny {
            rule: "agent_unknown_write_denied".into(),
            message: "agents may not run writes whose safety category cannot be determined".into(),
        });
    }

    if facts.contains_unscoped_dml {
        decisions.push(Decision::Deny {
            rule: "agent_no_unscoped_dml".into(),
            message: "agents may not run unscoped UPDATE/DELETE or TRUNCATE".into(),
        });
    }

    decisions
}

fn evaluate_agent_write_decisions(
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Vec<Decision> {
    let mut decisions = evaluate_agent_write_categorical(environment, facts, env_policy);

    if let Some(limit) = env_policy.blast_radius_max_rows
        && facts.contains_mutating_dml()
    {
        match estimated_rows {
            Some(rows) if rows > limit => {
                decisions.push(Decision::Deny {
                    rule: "blast_radius_exceeded".into(),
                    message: format!("would affect {rows} rows; limit is {limit}"),
                });
            }
            Some(_) => {}
            None => {
                decisions.push(Decision::Deny {
                    rule: "blast_radius_unknown".into(),
                    message: "could not estimate affected rows; agents are denied when a blast-radius limit is set"
                        .into(),
                });
            }
        }
    }

    decisions.push(match env_policy.agent_writes {
        crate::config::WritePolicy::Allow => Decision::Allow {
            rule: "agent_write_allow".into(),
        },
        crate::config::WritePolicy::Approve => Decision::RequireApproval {
            rule: "agent_write_approve".into(),
            reason: format!("{:?} requires approval for agent writes", facts.class),
            preview: Some(table_preview(facts)),
        },
        crate::config::WritePolicy::Deny => Decision::Deny {
            rule: "agent_writes_denied".into(),
            message: format!("agent writes are denied in {}", environment.as_str()),
        },
    });
    decisions
}

fn evaluate_human_write_categorical(
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
) -> Vec<Decision> {
    let mut decisions = Vec::new();
    if facts.contains_unscoped_dml {
        decisions.push(Decision::RequireApproval {
            rule: "human_unscoped_dml".into(),
            reason: "unscoped UPDATE/DELETE or TRUNCATE".into(),
            preview: Some(table_preview(facts)),
        });
    }

    if facts.contains_ddl() && env_policy.human_approve_ddl {
        decisions.push(Decision::RequireApproval {
            rule: "human_ddl_approve".into(),
            reason: format!("DDL on {}", environment.as_str()),
            preview: Some(table_preview(facts)),
        });
    }

    decisions
}

fn evaluate_human_write_decisions(
    environment: Environment,
    facts: &StatementFacts,
    env_policy: &EnvPolicy,
    estimated_rows: Option<u64>,
) -> Vec<Decision> {
    let effects = facts.effects;
    let mut decisions = evaluate_human_write_categorical(environment, facts, env_policy);

    if let Some(limit) = env_policy.blast_radius_max_rows
        && facts.contains_mutating_dml()
    {
        match estimated_rows {
            Some(rows) if rows > limit => {
                decisions.push(Decision::RequireApproval {
                    rule: "blast_radius_approve".into(),
                    reason: format!("would affect {rows} rows (limit {limit})"),
                    preview: None,
                });
            }
            Some(_) => {}
            None => {
                decisions.push(Decision::RequireApproval {
                    rule: "blast_radius_unknown".into(),
                    reason: "could not estimate affected rows; confirm before running".into(),
                    preview: None,
                });
            }
        }
    }

    if env_policy.human_approve_writes {
        decisions.push(Decision::RequireApproval {
            rule: "human_write_approve".into(),
            reason: format!("writes require approval in {}", environment.as_str()),
            preview: Some(table_preview(facts)),
        });
    } else if effects.contains(Effects::ADMIN)
        || effects.contains(Effects::HOST_OR_FILE_ACCESS)
        || effects.contains(Effects::UNKNOWN)
    {
        decisions.push(Decision::RequireApproval {
            rule: "human_dangerous_effect_approval".into(),
            reason: "administrative, host-access or unknown write effects require confirmation".into(),
            preview: Some(table_preview(facts)),
        });
    }

    decisions.push(Decision::Allow {
        rule: "human_write_allow".into(),
    });
    decisions
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::classify::classify;
    use crate::config::{PolicyConfig, WritePolicy};

    fn env_policy(environment: Environment) -> EnvPolicy {
        PolicyConfig::default().for_environment(environment)
    }

    fn has_rule(decision: &Decision, expected: &str) -> bool {
        decision.rule_name().split('+').any(|rule| rule == expected)
    }

    #[test]
    fn blast_radius_limit_is_inclusive_and_unknown_estimates_are_not_allowed() {
        let policy = EnvPolicy {
            agent_writes: WritePolicy::Allow,
            blast_radius_max_rows: Some(10),
            human_approve_writes: false,
            ..env_policy(Environment::Local)
        };
        let facts = classify("UPDATE items SET value = 1 WHERE id > 0", "postgres");
        let agent = Principal::Agent {
            token: "test".into(),
            client: None,
            model: None,
        };
        for (rows, agent_rule, human_rule) in [
            (Some(9), "agent_write_allow", "human_write_allow"),
            (Some(10), "agent_write_allow", "human_write_allow"),
            (Some(11), "blast_radius_exceeded", "blast_radius_approve"),
            (None, "blast_radius_unknown", "blast_radius_unknown"),
        ] {
            let agent_decision = evaluate(&agent, Environment::Local, &facts, false, &policy, rows);
            let human_decision = evaluate(
                &Principal::human_gui(),
                Environment::Local,
                &facts,
                false,
                &policy,
                rows,
            );
            assert_eq!(agent_decision.rule_name(), agent_rule);
            assert_eq!(human_decision.rule_name(), human_rule);
            let within_limit = rows.is_some_and(|rows| rows <= 10);
            assert_eq!(agent_decision.is_allow(), within_limit);
            assert_eq!(human_decision.is_allow(), within_limit);
            if !within_limit {
                assert!(matches!(agent_decision, Decision::Deny { .. }));
                assert!(matches!(human_decision, Decision::RequireApproval { .. }));
            }
        }
    }

    #[test]
    fn dangerous_effects_join_with_write_rules_instead_of_being_skipped() {
        let human = Principal::human_gui();
        let local = env_policy(Environment::Local);
        let staging = env_policy(Environment::Staging);
        for sql in [
            "COPY items TO PROGRAM 'echo unsafe'",
            "MERGE INTO items USING staged ON items.id = staged.id WHEN MATCHED THEN DELETE",
        ] {
            for (environment, policy) in [(Environment::Local, &local), (Environment::Staging, &staging)] {
                let decision = evaluate(&human, environment, &classify(sql, "postgres"), false, policy, None);
                assert!(
                    matches!(decision, Decision::RequireApproval { .. }),
                    "{environment:?}: {sql}: {decision:?}"
                );
            }
        }

        let local_truncate = evaluate(
            &human,
            Environment::Local,
            &classify("TRUNCATE TABLE items", "postgres"),
            false,
            &local,
            None,
        );
        assert!(matches!(local_truncate, Decision::RequireApproval { .. }));
        assert!(has_rule(&local_truncate, "human_unscoped_dml"));
        let Decision::RequireApproval { reason, .. } = local_truncate else {
            panic!("TRUNCATE must require approval in Local");
        };
        assert!(reason.contains("TRUNCATE"), "{reason}");
        assert!(matches!(
            evaluate(
                &human,
                Environment::Staging,
                &classify("TRUNCATE TABLE items", "postgres"),
                false,
                &staging,
                None,
            ),
            Decision::RequireApproval { .. }
        ));

        let policies = PolicyConfig::default().for_environment(Environment::Local);
        let scripts = [
            "COPY items TO PROGRAM 'echo unsafe'; MERGE INTO items USING staged ON items.id = staged.id WHEN MATCHED THEN DELETE",
            "MERGE INTO items USING staged ON items.id = staged.id WHEN MATCHED THEN DELETE; COPY items TO PROGRAM 'echo unsafe'",
        ];
        let decisions = scripts.map(|sql| {
            let analysis = classify(sql, "postgres");
            evaluate_with_effects(&human, Environment::Local, &analysis, false, &policies, None)
        });
        assert_eq!(decisions[0], decisions[1]);
        assert_eq!(decisions[0].rule_name(), "human_dangerous_effect_approval");
    }

    #[test]
    fn dangerous_effect_verdict_keeps_the_blast_radius_rule_and_reason() {
        let analysis = classify("DELETE FROM items WHERE pg_terminate_backend(pid)", "postgres");
        assert!(analysis.effects.contains(Effects::ADMIN));
        assert!(analysis.contains_mutating_dml());

        let policy = EnvPolicy {
            human_approve_writes: false,
            blast_radius_max_rows: Some(1),
            ..env_policy(Environment::Local)
        };
        let decision = evaluate_with_effects(
            &Principal::human_gui(),
            Environment::Local,
            &analysis,
            false,
            &policy,
            Some(10),
        );

        assert!(matches!(decision, Decision::RequireApproval { .. }), "{decision:?}");
        assert_eq!(
            decision.rule_name(),
            "blast_radius_approve+human_dangerous_effect_approval"
        );
        let Decision::RequireApproval { reason, .. } = decision else {
            panic!("the joined verdict must require approval");
        };
        assert!(reason.contains("would affect 10 rows"), "{reason}");
        assert!(
            reason.contains("administrative, host-access or unknown write effects"),
            "{reason}"
        );
    }

    #[test]
    fn host_file_reads_do_not_take_the_plain_read_allow_path() {
        let analysis = classify("SELECT read_text('/etc/passwd')", "duckdb");
        assert!(analysis.effects.contains(Effects::HOST_OR_FILE_ACCESS));
        assert!(!analysis.effects.writes());
        assert!(!analysis.writes());

        let local = EnvPolicy {
            human_approve_writes: false,
            ..env_policy(Environment::Local)
        };
        let decision = evaluate_with_effects(
            &Principal::human_gui(),
            Environment::Local,
            &analysis,
            false,
            &local,
            None,
        );
        assert!(matches!(decision, Decision::RequireApproval { .. }), "{decision:?}");
        assert_eq!(decision.rule_name(), "human_dangerous_effect_approval");

        let agent_policy = EnvPolicy {
            agent_writes: WritePolicy::Allow,
            ..local
        };
        let agent = Principal::Agent {
            token: "test".into(),
            client: None,
            model: None,
        };
        let agent_decision = evaluate_with_effects(&agent, Environment::Local, &analysis, false, &agent_policy, None);
        assert!(
            matches!(
                agent_decision,
                Decision::Deny { ref rule, .. } if rule == "agent_host_access_denied"
            ),
            "agents with database-write access still may not read host files: {agent_decision:?}"
        );
    }

    #[test]
    fn joined_verdict_is_independent_of_rule_evaluation_order_and_keeps_rule_names() {
        let allow = Decision::Allow {
            rule: "read_allow".into(),
        };
        let require_a = Decision::RequireApproval {
            rule: "human_ddl_approve".into(),
            reason: "DDL requires confirmation".into(),
            preview: Some("tables: a".into()),
        };
        let require_b = Decision::RequireApproval {
            rule: "human_write_approve".into(),
            reason: "writes require confirmation".into(),
            preview: None,
        };
        let deny = Decision::Deny {
            rule: "connection_read_only".into(),
            message: "connection is read-only".into(),
        };
        let orders = [
            vec![allow.clone(), require_a.clone(), require_b.clone(), deny.clone()],
            vec![deny.clone(), require_b.clone(), allow.clone(), require_a.clone()],
            vec![require_a.clone(), deny.clone(), require_b.clone(), allow.clone()],
            vec![require_b, allow, deny, require_a],
        ];
        let decisions = orders.map(|order| {
            Decision::join_all(order).unwrap_or(Decision::Allow {
                rule: "missing_join_result".into(),
            })
        });
        assert!(decisions.iter().all(|decision| decision == &decisions[0]));
        assert_eq!(decisions[0].rule_name(), "connection_read_only");
        assert!(matches!(decisions[0], Decision::Deny { .. }));

        let first = Decision::RequireApproval {
            rule: "human_ddl_approve".into(),
            reason: "DDL requires confirmation".into(),
            preview: Some("tables: a".into()),
        };
        let second = Decision::RequireApproval {
            rule: "human_write_approve".into(),
            reason: "writes require confirmation".into(),
            preview: None,
        };
        let forward = Decision::join_all([first.clone(), second.clone()]).unwrap_or(Decision::Allow {
            rule: "missing_join_result".into(),
        });
        let reverse = Decision::join_all([second, first]).unwrap_or(Decision::Allow {
            rule: "missing_join_result".into(),
        });
        assert_eq!(forward, reverse);
        assert_eq!(forward.rule_name(), "human_ddl_approve+human_write_approve");
    }

    #[test]
    fn a_lone_transaction_statement_is_refused_and_a_whole_transaction_batch_is_not() {
        for (sql, driver) in [
            ("BEGIN", "postgres"),
            ("START TRANSACTION", "mysql"),
            ("COMMIT", "postgres"),
            ("ROLLBACK", "sqlite"),
            ("BEGIN TRANSACTION", "mssql"),
        ] {
            let decision = shared_connection_decision(sql, driver, &classify(sql, driver));
            assert_eq!(
                decision.map(|d| d.rule_name().to_string()).as_deref(),
                Some("transaction_control_needs_session"),
                "{driver}: {sql}"
            );
        }
        let batch = classify(
            "BEGIN TRANSACTION; UPDATE items SET v = 1 WHERE id = 1; ROLLBACK",
            "mssql",
        );
        assert!(
            shared_connection_decision(
                "BEGIN TRANSACTION; UPDATE items SET v = 1 WHERE id = 1; ROLLBACK",
                "mssql",
                &batch
            )
            .is_none()
        );
        assert!(shared_connection_decision("SELECT 1", "postgres", &classify("SELECT 1", "postgres")).is_none());
    }

    #[test]
    fn shared_batches_must_not_leave_an_explicit_transaction_open() {
        let cases = [
            ("BEGIN; UPDATE items SET v = 1 WHERE id = 1", "postgres", true),
            ("BEGIN; SELECT 1", "postgres", true),
            ("BEGIN; UPDATE items SET v = 1 WHERE id = 1; COMMIT", "postgres", false),
            (
                "BEGIN; UPDATE items SET v = 1 WHERE id = 1; ROLLBACK",
                "postgres",
                false,
            ),
            ("BEGIN; SELECT 1; COMMIT AND CHAIN", "postgres", true),
            (
                "BEGIN; UPDATE items SET v = 1 WHERE id = 1; BEGIN; COMMIT",
                "postgres",
                true,
            ),
            ("UPDATE items SET v = 1 WHERE id = 1; COMMIT", "postgres", true),
            ("BEGIN; SELECT 'COMMIT; BEGIN'; COMMIT", "postgres", false),
            ("BEGIN; /* COMMIT */ SELECT 1; COMMIT", "postgres", false),
            (
                "START TRANSACTION; CREATE TABLE transaction_ddl (id INT); COMMIT",
                "mysql",
                true,
            ),
        ];
        for (sql, driver, denied) in cases {
            let decision = shared_connection_decision(sql, driver, &classify(sql, driver));
            assert_eq!(decision.is_some(), denied, "{driver}: {sql}");
        }
    }

    #[test]
    fn human_unscoped_and_ddl_approval_survive_permissive_write_defaults() {
        let policy = EnvPolicy {
            human_approve_writes: false,
            human_approve_ddl: true,
            blast_radius_max_rows: None,
            ..env_policy(Environment::Local)
        };
        for (sql, expected) in [
            ("DELETE FROM items", "human_unscoped_dml"),
            ("DROP TABLE items", "human_ddl_approve"),
        ] {
            let decision = evaluate(
                &Principal::human_gui(),
                Environment::Local,
                &classify(sql, "postgres"),
                false,
                &policy,
                Some(1),
            );
            assert!(matches!(decision, Decision::RequireApproval { .. }));
            assert!(!decision.is_allow());
            assert_eq!(decision.rule_name(), expected);
        }
    }

    #[test]
    fn deny_write_policy_denies_every_agent_write_route() {
        let policy = EnvPolicy {
            agent_writes: WritePolicy::Deny,
            ..env_policy(Environment::Prod)
        };
        for sql in [
            "UPDATE t SET a = 1 WHERE id = 1",
            "DELETE FROM t WHERE id = 1",
            "CREATE TABLE t (id int)",
            "INSERT INTO t VALUES (1)",
        ] {
            let facts = classify(sql, "postgres");
            let Some(decision) = Decision::join_all(evaluate_agent_write_decisions(
                Environment::Prod,
                &facts,
                &policy,
                Some(1),
            )) else {
                panic!("{sql} produced no verdict");
            };
            let Decision::Deny { rule, .. } = &decision else {
                panic!("{sql} produced {decision:?}");
            };
            assert!(
                rule.split('+').any(|name| name == "agent_writes_denied"),
                "{sql}: {rule}"
            );
            if facts.contains_ddl() {
                assert!(rule.split('+').any(|name| name == "agent_ddl_denied"), "{sql}: {rule}");
            }
        }
    }

    #[test]
    fn agent_denied_on_prod_write() {
        let facts = classify("DELETE FROM t WHERE id = 1", "postgres");
        let d = evaluate(
            &Principal::Agent {
                token: "tok".into(),
                client: Some("cursor".into()),
                model: None,
            },
            Environment::Prod,
            &facts,
            false,
            &env_policy(Environment::Prod),
            Some(1),
        );
        assert!(matches!(d, Decision::Deny { .. }), "{d:?}");
    }

    #[test]
    fn human_allowed_local_write() {
        let facts = classify("UPDATE t SET a = 1 WHERE id = 1", "postgres");
        let d = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &facts,
            false,
            &env_policy(Environment::Local),
            Some(1),
        );
        assert!(d.is_allow(), "{d:?}");
        assert_eq!(d.rule_name(), "human_write_allow");
    }

    #[test]
    fn read_only_connection_blocks_write() {
        let facts = classify("DELETE FROM t WHERE id = 1", "postgres");
        let d = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &facts,
            true,
            &env_policy(Environment::Local),
            None,
        );
        assert!(matches!(d, Decision::Deny { ref rule, .. } if rule == "connection_read_only"));
        assert!(!d.is_allow(), "denial is not authorization");
        assert_eq!(d.rule_name(), "connection_read_only");
    }

    #[test]
    fn read_only_connection_denies_select_into() {
        let facts = classify("SELECT * INTO backup FROM accounts", "postgres");
        let read_only = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &facts,
            true,
            &env_policy(Environment::Local),
            None,
        );
        assert_eq!(read_only.rule_name(), "connection_read_only");
        assert!(!read_only.is_allow(), "{read_only:?}");
    }

    #[test]
    fn agent_unparseable_denied() {
        let facts = classify("NOT SQL AT ALL !!!", "postgres");
        let d = evaluate(
            &Principal::Agent {
                token: "t".into(),
                client: None,
                model: None,
            },
            Environment::Dev,
            &facts,
            false,
            &env_policy(Environment::Dev),
            None,
        );
        assert!(matches!(d, Decision::Deny { .. }));
    }

    #[test]
    fn read_only_human_cannot_approve_unparseable_sql() {
        let facts = classify("NOT SQL AT ALL !!!", "postgres");
        let decision = evaluate(
            &Principal::human_gui(),
            Environment::Prod,
            &facts,
            true,
            &env_policy(Environment::Prod),
            None,
        );
        assert!(matches!(decision, Decision::Deny { ref rule, .. } if rule == "connection_read_only"));
    }

    #[test]
    fn agent_cannot_terminate_postgres_session() {
        let facts = classify("SELECT pg_terminate_backend(42)", "postgres");
        let decision = evaluate(
            &Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            &facts,
            false,
            &env_policy(Environment::Local),
            None,
        );
        assert!(matches!(decision, Decision::Deny { ref rule, .. } if rule == "agent_admin_denied"));
    }

    #[test]
    fn agent_cannot_call_postgres_side_effecting_function() {
        let facts = classify("SELECT nextval('jobs_id_seq')", "postgres");
        let decision = evaluate(
            &Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            &facts,
            false,
            &env_policy(Environment::Local),
            None,
        );
        assert!(matches!(decision, Decision::Deny { ref rule, .. } if rule == "agent_admin_denied"));
    }

    #[test]
    fn read_only_connection_blocks_postgres_side_effecting_function() {
        let facts = classify("SELECT nextval('jobs_id_seq')", "postgres");
        let decision = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &facts,
            true,
            &env_policy(Environment::Local),
            None,
        );
        assert!(matches!(decision, Decision::Deny { ref rule, .. } if rule == "connection_read_only"));
    }

    #[test]
    fn agent_cannot_hide_ddl_in_mixed_script() {
        let facts = classify(
            "DROP TABLE protected_data; INSERT INTO audit_log VALUES (1)",
            "postgres",
        );
        let mut policy = EnvPolicy::local_defaults();
        policy.agent_writes = WritePolicy::Allow;
        policy.agent_allow_multi_statement = true;
        policy.agent_allow_ddl = false;
        let decision = evaluate(
            &Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            &facts,
            false,
            &policy,
            None,
        );
        assert!(matches!(decision, Decision::Deny { .. }));
        assert!(has_rule(&decision, "agent_ddl_denied"), "{decision:?}");
    }

    #[test]
    fn agent_cannot_hide_scoped_dml_blast_radius_in_mixed_script() {
        let facts = classify(
            "UPDATE protected_data SET value = 'x' WHERE tenant_id = 42; INSERT INTO audit_log VALUES (1)",
            "postgres",
        );
        let mut policy = EnvPolicy::local_defaults();
        policy.agent_writes = WritePolicy::Allow;
        policy.agent_allow_multi_statement = true;
        let decision = evaluate(
            &Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            &facts,
            false,
            &policy,
            None,
        );
        assert!(matches!(decision, Decision::Deny { ref rule, .. } if rule == "blast_radius_unknown"));
    }

    #[test]
    fn human_scoped_dml_blast_radius_in_mixed_script_requires_approval() {
        let facts = classify(
            "UPDATE protected_data SET value = 'x' WHERE tenant_id = 42; INSERT INTO audit_log VALUES (1)",
            "postgres",
        );
        let decision = evaluate(
            &Principal::human_gui(),
            Environment::Local,
            &facts,
            false,
            &env_policy(Environment::Local),
            None,
        );
        assert!(matches!(decision, Decision::RequireApproval { ref rule, .. } if rule == "blast_radius_unknown"));
    }

    #[test]
    fn agent_cannot_hide_unscoped_dml_in_mixed_script() {
        let facts = classify(
            "CREATE TABLE replacement(id integer); DELETE FROM protected_data",
            "postgres",
        );
        let mut policy = EnvPolicy::local_defaults();
        policy.agent_writes = WritePolicy::Allow;
        policy.agent_allow_multi_statement = true;
        policy.agent_allow_ddl = true;
        let decision = evaluate(
            &Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            Environment::Local,
            &facts,
            false,
            &policy,
            None,
        );
        assert!(matches!(decision, Decision::Deny { .. }));
        assert!(has_rule(&decision, "agent_no_unscoped_dml"), "{decision:?}");
    }

    #[test]
    fn agent_cannot_run_or_hide_unclassified_write() {
        for sql in [
            "SET application_name = 'agent'",
            "SET session_replication_role = replica; INSERT INTO jobs(id) VALUES (1)",
            "INSERT INTO jobs(id) VALUES (1); SET session_replication_role = replica",
        ] {
            let facts = classify(sql, "postgres");
            let mut policy = EnvPolicy::local_defaults();
            policy.agent_writes = WritePolicy::Allow;
            policy.agent_allow_multi_statement = true;
            let decision = evaluate(
                &Principal::Agent {
                    token: "token".into(),
                    client: None,
                    model: None,
                },
                Environment::Local,
                &facts,
                false,
                &policy,
                None,
            );
            assert!(
                matches!(decision, Decision::Deny { .. }),
                "SQL: {sql}, decision: {decision:?}"
            );
            assert!(
                has_rule(&decision, "agent_unknown_write_denied"),
                "SQL: {sql}, decision: {decision:?}"
            );
        }
    }

    #[test]
    fn agent_denied_when_blast_radius_unknown() {
        let facts = classify("DELETE FROM t WHERE id = 1", "postgres");
        let d = evaluate(
            &Principal::Agent {
                token: "tok".into(),
                client: None,
                model: None,
            },
            Environment::Dev,
            &facts,
            false,
            &env_policy(Environment::Dev),
            None,
        );
        assert!(
            matches!(d, Decision::Deny { ref rule, .. } if rule == "blast_radius_unknown"),
            "{d:?}"
        );
    }

    #[test]
    fn human_requires_approval_when_blast_radius_unknown() {
        let facts = classify("DELETE FROM t WHERE id = 1", "postgres");
        let d = evaluate(
            &Principal::human_gui(),
            Environment::Staging,
            &facts,
            false,
            &env_policy(Environment::Staging),
            None,
        );
        assert!(
            matches!(d, Decision::RequireApproval { ref rule, .. } if rule == "blast_radius_unknown"),
            "{d:?}"
        );
    }

    #[test]
    fn connection_override_policy_is_used_directly() {
        let facts = classify("DELETE FROM t WHERE id = 1", "postgres");
        let mut override_policy = EnvPolicy::prod_defaults();
        override_policy.agent_writes = WritePolicy::Allow;
        let d = evaluate(
            &Principal::Agent {
                token: "tok".into(),
                client: None,
                model: None,
            },
            Environment::Prod,
            &facts,
            false,
            &override_policy,
            Some(1),
        );
        assert!(d.is_allow(), "{d:?}");
    }
}
