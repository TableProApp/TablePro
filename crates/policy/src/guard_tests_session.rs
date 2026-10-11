use super::*;

#[derive(Default)]
struct SessionScript {
    sent: Mutex<Vec<String>>,
    lose_on: Option<&'static str>,
    fail_once_on: Option<&'static str>,
    disconnect_on: Option<&'static str>,
    query_error_on: Option<&'static str>,
}

struct ScriptedSession {
    script: Arc<SessionScript>,
    usable: bool,
    failed_once: bool,
}

#[async_trait]
impl tablepro_core::Session for ScriptedSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        self.script.sent.lock().expect("sent lock").push(sql.to_string());
        if self.script.disconnect_on == Some(sql) {
            return Err(DriverError::Disconnected);
        }
        if self.script.query_error_on == Some(sql) {
            return Err(DriverError::Query {
                message: "deferred foreign key constraint violated".into(),
                sqlstate: Some("23503".into()),
                position: None,
            });
        }
        if !self.failed_once && self.script.fail_once_on == Some(sql) {
            self.failed_once = true;
            return Err(DriverError::TimedOut);
        }
        if self.script.lose_on == Some(sql) {
            self.usable = false;
            return Err(DriverError::Cancelled);
        }
        Ok(empty_result())
    }

    fn is_usable(&self) -> bool {
        self.usable
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct SessionConn {
    script: Arc<SessionScript>,
}

#[async_trait]
impl Connection for SessionConn {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Ok(empty_result())
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 0 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 0 })
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Ok(vec![])
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        Ok(Box::new(ScriptedSession {
            script: self.script.clone(),
            usable: true,
            failed_once: false,
        }))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

struct Harness {
    guard: PolicyGuard,
    script: Arc<SessionScript>,
    audit: Arc<SequenceAuditSink>,
    audit_state: Arc<AuditState>,
}

fn harness(script: SessionScript, read_only: bool) -> Harness {
    harness_with_driver(script, read_only, "postgres")
}

fn harness_with_driver(script: SessionScript, read_only: bool, driver_id: &str) -> Harness {
    harness_with_principal(script, read_only, driver_id, Principal::human_gui(), Environment::Local)
}

fn harness_with_principal(
    script: SessionScript,
    read_only: bool,
    driver_id: &str,
    principal: Principal,
    environment: Environment,
) -> Harness {
    let script = Arc::new(script);
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let audit_state = Arc::new(AuditState::new());
    let mut ctx = context(
        principal,
        environment,
        PolicyConfig::default(),
        Arc::new(AutoApproveSink),
        audit.clone(),
        audit_state.clone(),
    );
    ctx.read_only = read_only;
    ctx.driver_id = driver_id.into();
    let inner: Arc<dyn Connection> = Arc::new(SessionConn { script: script.clone() });
    Harness {
        guard: PolicyGuard::new(inner, ctx),
        script,
        audit,
        audit_state,
    }
}

#[tokio::test]
async fn postgres_read_only_begin_is_audited_as_a_read_and_refuses_writes_before_dispatch() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .expect("read-only transaction begins");
    assert!(session.transaction_open());
    let write = run(&mut session, "DELETE FROM items WHERE id = 1")
        .await
        .expect_err("read-only transaction refuses writes");
    assert!(matches!(write, DriverError::ReadOnly), "{write:?}");
    let session_effect = run(&mut session, "SELECT pg_advisory_lock(1)")
        .await
        .expect_err("read-only transaction refuses session side effects");
    assert!(matches!(session_effect, DriverError::ReadOnly), "{session_effect:?}");
    assert_eq!(
        *h.script.sent.lock().expect("sent lock"),
        vec!["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"]
    );
    run(&mut session, "COMMIT")
        .await
        .expect("read-only transaction commits");

    let events = h.audit.events.lock().expect("event lock");
    let begin = events
        .iter()
        .find(|event| event.operation_class == AuditOperationClass::Read && event.phase == AuditRecordPhase::Outcome)
        .expect("read-only begin outcome is audited");
    assert_eq!(begin.operation_class, AuditOperationClass::Read);
    assert_eq!(begin.terminal_status, AuditTerminalStatus::Succeeded);
}

#[tokio::test]
async fn a_read_only_connection_can_open_a_postgres_read_only_session() {
    let h = harness(SessionScript::default(), true);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .expect("read-only connection can start its read snapshot");
    run(&mut session, "SELECT 1")
        .await
        .expect("read-only snapshot permits reads");
    run(&mut session, "ROLLBACK")
        .await
        .expect("read-only snapshot can roll back");
}

#[tokio::test]
async fn a_read_scoped_agent_can_open_and_audit_a_postgres_read_snapshot() {
    let h = harness_with_principal(
        SessionScript::default(),
        true,
        "postgres",
        Principal::Agent {
            token: "raw-agent-token".into(),
            client: Some("session-test".into()),
            model: None,
        },
        Environment::Staging,
    );
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .expect("read-scoped agent can start a read snapshot");
    run(&mut session, "SELECT 1").await.expect("read-scoped query");
    let write = run(&mut session, "DELETE FROM items WHERE id = 1")
        .await
        .expect_err("read-scoped agent cannot write in the snapshot");
    assert!(matches!(write, DriverError::ReadOnly), "{write:?}");
    assert_eq!(
        *h.script.sent.lock().expect("sent lock"),
        vec!["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", "SELECT 1"]
    );
    run(&mut session, "ROLLBACK").await.expect("rollback snapshot");

    let events = h.audit.events.lock().expect("event lock");
    let begin_events = events
        .iter()
        .filter(|event| event.decision_rule == "read_only_snapshot")
        .collect::<Vec<_>>();
    assert_eq!(begin_events.len(), 2);
    assert!(
        begin_events
            .iter()
            .all(|event| event.operation_class == AuditOperationClass::Read)
    );
    assert!(begin_events.iter().any(|event| event.phase == AuditRecordPhase::Intent));
    assert!(
        begin_events
            .iter()
            .any(|event| event.phase == AuditRecordPhase::Outcome)
    );
    let serialized = serde_json::to_string(&*events).expect("serialize events");
    assert!(!serialized.contains("raw-agent-token"));
}

#[tokio::test]
async fn read_only_mode_survives_commit_and_chain() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY")
        .await
        .expect("begin");
    run(&mut session, "COMMIT AND CHAIN").await.expect("commit and chain");
    let error = run(&mut session, "DELETE FROM items WHERE id = 1")
        .await
        .expect_err("chained transaction keeps read-only mode");
    assert!(matches!(error, DriverError::ReadOnly), "{error:?}");
    assert_eq!(
        *h.script.sent.lock().expect("sent lock"),
        vec!["BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY", "COMMIT AND CHAIN"]
    );
}

#[tokio::test]
async fn a_read_only_begin_without_snapshot_isolation_is_refused_before_dispatch() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    let error = run(&mut session, "BEGIN READ ONLY")
        .await
        .expect_err("read committed does not provide a transaction-wide snapshot");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
    assert!(!session.transaction_open());
    assert!(h.script.sent.lock().expect("sent lock").is_empty());
}

#[tokio::test]
async fn a_read_only_begin_is_refused_before_dispatch_on_unsupported_engines() {
    let h = harness_with_driver(SessionScript::default(), false, "mysql");
    let mut session = h.guard.open_session().await.expect("open session");

    let error = run(&mut session, "START TRANSACTION READ ONLY")
        .await
        .expect_err("read-only transaction mode is not yet supported for MySQL");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
    assert!(!session.transaction_open());
    assert!(h.script.sent.lock().expect("sent lock").is_empty());
}

async fn run(session: &mut Box<dyn tablepro_core::Session>, sql: &str) -> Result<QueryResult, DriverError> {
    session
        .query_params_controlled(sql, &[], &OperationControl::with_timeout(Duration::from_secs(5)))
        .await
}

fn outcomes_of(audit: &SequenceAuditSink, class: AuditOperationClass) -> Vec<AuditEvent> {
    audit
        .events
        .lock()
        .expect("event lock")
        .iter()
        .filter(|event| event.operation_class == class && event.phase == AuditRecordPhase::Outcome)
        .cloned()
        .collect()
}

#[tokio::test]
async fn a_session_runs_its_own_transaction_and_audits_the_rollback_against_its_batch() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin is allowed in a session");
    assert!(session.transaction_open());
    run(&mut session, "UPDATE items SET v = 1 WHERE id = 1")
        .await
        .expect("write");
    run(&mut session, "ROLLBACK TO SAVEPOINT s")
        .await
        .expect("savepoint rollback stays inside");
    assert!(session.transaction_open());
    run(&mut session, "ROLLBACK").await.expect("rollback");
    assert!(!session.transaction_open());

    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
    let events = h.audit.events.lock().expect("event lock");
    let write = events
        .iter()
        .find(|event| {
            event.operation_class.is_write() && event.operation_class != AuditOperationClass::TransactionRollback
        })
        .expect("the write is audited");
    assert_eq!(write.batch_id, rollbacks[0].batch_id);
    assert!(write.batch_id.is_some());
    assert_eq!(
        *h.script.sent.lock().expect("sent lock"),
        vec![
            "BEGIN",
            "UPDATE items SET v = 1 WHERE id = 1",
            "ROLLBACK TO SAVEPOINT s",
            "ROLLBACK"
        ]
    );
}

#[tokio::test]
async fn a_committed_session_transaction_records_the_commit() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    for sql in ["BEGIN", "INSERT INTO items VALUES (1)", "COMMIT"] {
        run(&mut session, sql).await.expect(sql);
    }

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Committed);
    assert!(!session.transaction_open());
}

#[tokio::test]
async fn a_failed_rollback_keeps_the_batch_until_a_retry_succeeds() {
    let h = harness(
        SessionScript {
            fail_once_on: Some("ROLLBACK"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE items SET v = 1 WHERE id = 1")
        .await
        .expect("write");

    assert!(matches!(
        run(&mut session, "ROLLBACK").await,
        Err(DriverError::TimedOut)
    ));
    assert!(session.transaction_open());
    run(&mut session, "ROLLBACK").await.expect("retry rollback");
    assert!(!session.transaction_open());

    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 2);
    assert_eq!(rollbacks[0].batch_id, rollbacks[1].batch_id);
    assert_eq!(rollbacks[1].transaction_outcome, AuditTransactionOutcome::RolledBack);
}

#[tokio::test]
async fn policy_still_denies_a_write_inside_a_session_on_a_read_only_connection() {
    let h = harness(SessionScript::default(), true);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    let error = run(&mut session, "DELETE FROM items WHERE id = 1")
        .await
        .expect_err("read-only must deny the write");

    assert!(
        matches!(error, DriverError::PolicyDenied(_) | DriverError::ReadOnly),
        "{error:?}"
    );
    assert!(
        !h.script
            .sent
            .lock()
            .expect("sent lock")
            .iter()
            .any(|sql| sql.starts_with("DELETE"))
    );
}

#[tokio::test]
async fn closing_a_session_with_an_open_transaction_rolls_it_back_and_audits_it() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE items SET v = 2 WHERE id = 1")
        .await
        .expect("write");

    session.close().await.expect("rollback and close");

    assert_eq!(
        h.script.sent.lock().expect("sent lock").last().map(String::as_str),
        Some("ROLLBACK")
    );
    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
    assert!(!h.audit_state.governed_writes_disabled());
}

#[tokio::test]
async fn closing_after_a_failed_rollback_surfaces_and_audits_unknown_outcome() {
    let h = harness(
        SessionScript {
            fail_once_on: Some("ROLLBACK"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE items SET v = 2 WHERE id = 1")
        .await
        .expect("write");

    let error = session.close().await.expect_err("rollback failure must be reported");
    assert!(matches!(error, DriverError::TimedOut));
    assert_eq!(
        h.script.sent.lock().expect("sent lock").last().map(String::as_str),
        Some("ROLLBACK")
    );
    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 2);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::Pending);
    assert_eq!(rollbacks[1].transaction_outcome, AuditTransactionOutcome::Unknown);
    assert!(h.audit_state.governed_writes_disabled());
}

#[tokio::test]
async fn a_session_lost_mid_transaction_after_a_write_records_an_unknown_outcome() {
    let h = harness(
        SessionScript {
            lose_on: Some("SELECT pg_sleep(60)"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE items SET v = 3 WHERE id = 1")
        .await
        .expect("write");
    let _ = run(&mut session, "SELECT pg_sleep(60)").await;
    assert!(!session.is_usable());

    let close = session.close().await.expect_err("unknown outcome must be reported");
    assert!(matches!(close, DriverError::OperationOutcomeUnknown { .. }));

    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::Unknown);
    assert!(h.audit_state.governed_writes_disabled());
    assert_ne!(
        h.script.sent.lock().expect("sent lock").last().map(String::as_str),
        Some("ROLLBACK")
    );
}

#[tokio::test]
async fn a_statement_on_a_retired_session_is_refused_before_dispatch() {
    let h = harness(
        SessionScript {
            lose_on: Some("SELECT pg_sleep(60)"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    let _ = run(&mut session, "SELECT pg_sleep(60)").await;
    assert!(!session.is_usable());

    let error = run(&mut session, "SELECT 1")
        .await
        .expect_err("a retired session refuses");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
    assert_eq!(*h.script.sent.lock().expect("sent lock"), vec!["SELECT pg_sleep(60)"]);
}

#[tokio::test]
async fn a_disconnected_error_retires_the_session_even_when_the_driver_reports_it_usable() {
    let h = harness(
        SessionScript {
            disconnect_on: Some("UPDATE items SET v = 1 WHERE id = 1"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    let error = run(&mut session, "UPDATE items SET v = 1 WHERE id = 1")
        .await
        .expect_err("disconnected");
    assert!(matches!(error, DriverError::Disconnected));
    assert!(!session.is_usable());

    let refused = run(&mut session, "SELECT 1")
        .await
        .expect_err("retired session refuses");
    assert!(matches!(refused, DriverError::PolicyDenied(_)), "{refused:?}");

    let close = session.close().await.expect_err("unknown outcome must be reported");
    assert!(matches!(close, DriverError::OperationOutcomeUnknown { .. }));
    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::Unknown);
}

#[tokio::test]
async fn commit_without_a_preceding_begin_is_refused() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    let error = run(&mut session, "COMMIT").await.expect_err("no transaction is open");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
    assert!(h.script.sent.lock().expect("sent lock").is_empty());
}

#[tokio::test]
async fn transaction_control_hidden_in_a_script_is_refused_and_never_reaches_the_database() {
    for script in [
        "SELECT 1; COMMIT",
        "BEGIN; UPDATE jobs SET done = true; COMMIT",
        "SELECT 1; ROLLBACK",
        "SELECT 1; BEGIN",
    ] {
        let h = harness(SessionScript::default(), false);
        let mut session = h.guard.open_session().await.expect("open session");

        run(&mut session, "BEGIN").await.expect("begin");
        let error = run(&mut session, script)
            .await
            .expect_err("script with transaction control");

        assert!(matches!(error, DriverError::PolicyDenied(_)), "{script}: {error:?}");
        assert!(session.transaction_open(), "{script}");
        assert_eq!(*h.script.sent.lock().expect("sent lock"), vec!["BEGIN"], "{script}");
    }
}

#[tokio::test]
async fn a_nested_begin_is_refused() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    let error = run(&mut session, "BEGIN").await.expect_err("nested begin is refused");
    assert!(matches!(error, DriverError::PolicyDenied(_)), "{error:?}");
    assert!(session.transaction_open());
    assert_eq!(*h.script.sent.lock().expect("sent lock"), vec!["BEGIN"]);
}

#[tokio::test]
async fn a_denied_statement_inside_a_transaction_does_not_block_the_following_commit() {
    let h = harness(SessionScript::default(), true);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "DELETE FROM items WHERE id = 1")
        .await
        .expect_err("read-only denies the write");
    run(&mut session, "COMMIT").await.expect("commit still succeeds");
    assert!(!session.transaction_open());

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Committed);
}

#[tokio::test]
async fn a_timed_out_statement_inside_a_postgres_transaction_leaves_the_commit_rolled_back() {
    let h = harness(
        SessionScript {
            fail_once_on: Some("UPDATE items SET v = 1 WHERE id = 1"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    assert!(matches!(
        run(&mut session, "UPDATE items SET v = 1 WHERE id = 1").await,
        Err(DriverError::TimedOut)
    ));
    run(&mut session, "COMMIT")
        .await
        .expect("the commit itself is dispatched successfully");
    assert!(!session.transaction_open());

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::Succeeded);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
}

#[tokio::test]
async fn rollback_and_chain_starts_a_fresh_batch() {
    let h = harness(SessionScript::default(), false);
    let mut session = h.guard.open_session().await.expect("open session");

    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "UPDATE items SET v = 1 WHERE id = 1")
        .await
        .expect("write");
    run(&mut session, "ROLLBACK AND CHAIN")
        .await
        .expect("rollback and chain");
    assert!(session.transaction_open());

    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::RolledBack);

    run(&mut session, "ROLLBACK").await.expect("second rollback");
    assert!(!session.transaction_open());
    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 2);
    assert_ne!(rollbacks[0].batch_id, rollbacks[1].batch_id);
}

#[tokio::test]
async fn a_disconnected_commit_writes_an_unknown_terminal_state_and_retires_the_session() {
    let h = harness(
        SessionScript {
            disconnect_on: Some("COMMIT"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "INSERT INTO items VALUES (1)").await.expect("write");

    let error = run(&mut session, "COMMIT").await.expect_err("disconnected");
    assert!(matches!(error, DriverError::Disconnected));
    assert!(!session.is_usable());

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::Unknown);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Unknown);
    assert!(h.audit_state.governed_writes_disabled());

    let close = session.close().await.expect_err("unknown outcome must be reported");
    assert!(matches!(close, DriverError::OperationOutcomeUnknown { .. }));
    let rollbacks = outcomes_of(&h.audit, AuditOperationClass::TransactionRollback);
    assert_eq!(rollbacks.len(), 1);
    assert_eq!(rollbacks[0].transaction_outcome, AuditTransactionOutcome::Unknown);
}

#[tokio::test]
async fn a_timed_out_commit_writes_a_timed_out_terminal_state_and_stays_open_for_retry() {
    let h = harness(
        SessionScript {
            fail_once_on: Some("COMMIT"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "INSERT INTO items VALUES (1)").await.expect("write");

    assert!(matches!(run(&mut session, "COMMIT").await, Err(DriverError::TimedOut)));
    assert!(session.transaction_open());
    run(&mut session, "COMMIT").await.expect("retry commit");
    assert!(!session.transaction_open());

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 2);
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::TimedOut);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Pending);
    assert_eq!(commits[1].terminal_status, AuditTerminalStatus::Succeeded);
    assert_eq!(commits[1].transaction_outcome, AuditTransactionOutcome::Committed);
}

#[tokio::test]
async fn a_definite_commit_failure_closes_the_batch_instead_of_leaving_it_open() {
    let h = harness(
        SessionScript {
            query_error_on: Some("COMMIT"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "INSERT INTO items VALUES (1)").await.expect("write");

    let error = run(&mut session, "COMMIT")
        .await
        .expect_err("deferred constraint failure");
    assert!(matches!(error, DriverError::Query { .. }), "{error:?}");
    assert!(
        !session.transaction_open(),
        "the engine already ended the transaction, so the batch must not stay open"
    );

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].terminal_status, AuditTerminalStatus::Failed);

    let new_batch_begin = run(&mut session, "BEGIN").await;
    assert!(
        new_batch_begin.is_ok(),
        "a fresh BEGIN must be accepted after the batch closed"
    );
}
