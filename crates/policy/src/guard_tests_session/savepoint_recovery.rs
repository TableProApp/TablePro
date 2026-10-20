use super::*;

#[tokio::test]
async fn committing_after_confirmed_savepoint_recovery_is_audited_as_committed() {
    for (savepoint, recovery) in [
        ("SAVEPOINT recovery", "ROLLBACK TO SAVEPOINT recovery"),
        ("SAVEPOINT recovery", "ROLLBACK TO recovery"),
        (
            "SAVEPOINT \"Recovery Point\"",
            "/* recovery */ ROLLBACK TO SAVEPOINT \"Recovery Point\"",
        ),
    ] {
        let h = harness(
            SessionScript {
                query_error_on: Some("SELECT 1 / 0"),
                ..SessionScript::default()
            },
            false,
        );
        let mut session = h.guard.open_session().await.expect("open session");
        run(&mut session, "BEGIN").await.expect("begin");
        run(&mut session, savepoint).await.expect("savepoint");
        run(&mut session, "SELECT 1 / 0").await.expect_err("statement fails");
        run(&mut session, recovery).await.expect("recover savepoint");
        run(&mut session, "COMMIT").await.expect("commit");

        let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
        assert_eq!(commits.len(), 1);
        assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::Committed);
        assert!(!session.transaction_open());
    }
}

#[tokio::test]
async fn a_failed_savepoint_recovery_keeps_the_commit_audited_as_rolled_back() {
    let h = harness(
        SessionScript {
            fail_once_on: Some("SELECT pg_sleep(1)"),
            query_error_on: Some("ROLLBACK TO SAVEPOINT missing"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "SELECT pg_sleep(1)")
        .await
        .expect_err("statement fails");
    run(&mut session, "ROLLBACK TO SAVEPOINT missing")
        .await
        .expect_err("recovery fails");
    run(&mut session, "COMMIT").await.expect("commit command succeeds");

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits.len(), 1);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
}

#[tokio::test]
async fn savepoint_words_in_a_value_do_not_clear_an_aborted_transaction() {
    let h = harness(
        SessionScript {
            query_error_on: Some("SELECT 1 / 0"),
            ..SessionScript::default()
        },
        false,
    );
    let mut session = h.guard.open_session().await.expect("open session");
    run(&mut session, "BEGIN").await.expect("begin");
    run(&mut session, "SELECT 1 / 0").await.expect_err("statement fails");
    run(&mut session, "SELECT 'ROLLBACK TO SAVEPOINT recovery'")
        .await
        .expect("scripted successful result");
    run(&mut session, "COMMIT").await.expect("commit command succeeds");

    let commits = outcomes_of(&h.audit, AuditOperationClass::TransactionCommit);
    assert_eq!(commits[0].transaction_outcome, AuditTransactionOutcome::RolledBack);
}

#[tokio::test]
async fn typed_commit_distinguishes_a_committed_transaction_from_an_aborted_rollback() {
    use tablepro_core::SessionCommitOutcome;

    for (abort, expected) in [
        (false, SessionCommitOutcome::Committed),
        (true, SessionCommitOutcome::RolledBack),
    ] {
        let h = harness(
            SessionScript {
                query_error_on: Some("SELECT 1 / 0"),
                ..SessionScript::default()
            },
            false,
        );
        let mut session = h.guard.open_session().await.expect("open session");
        run(&mut session, "BEGIN").await.expect("begin");
        if abort {
            run(&mut session, "SELECT 1 / 0").await.expect_err("abort transaction");
        }
        let outcome = session
            .commit_controlled(&OperationControl::with_timeout(std::time::Duration::from_secs(5)))
            .await
            .expect("finish transaction");
        assert_eq!(outcome, expected);
        assert!(!session.transaction_open());
    }
}

#[tokio::test]
async fn typed_commit_preserves_missing_transaction_lockdown_and_retired_session_refusals() {
    for state in ["missing", "locked", "retired"] {
        let h = harness(
            SessionScript {
                disconnect_on: Some("SELECT 1"),
                ..SessionScript::default()
            },
            false,
        );
        let mut session = h.guard.open_session().await.expect("open session");
        if state != "missing" {
            run(&mut session, "BEGIN").await.expect("begin");
        }
        if state == "locked" {
            h.audit_state.disable_after_audit_failure();
        }
        if state == "retired" {
            run(&mut session, "SELECT 1").await.expect_err("disconnect");
        }
        let before = h.script.sent.lock().expect("sent").len();
        let result = session
            .commit_controlled(&OperationControl::with_timeout(std::time::Duration::from_secs(5)))
            .await;
        assert!(matches!(result, Err(DriverError::PolicyDenied(_))), "{result:?}");
        assert_eq!(h.script.sent.lock().expect("sent").len(), before);
    }
}
