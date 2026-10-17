use super::*;
use crate::approval::AutoApproveSink;
use crate::guard::AdministrativeOperation;
use tokio_util::sync::CancellationToken;

fn agent() -> Principal {
    Principal::Agent {
        token: "token".into(),
        client: None,
        model: None,
    }
}

fn guard(
    principal: Principal,
    read_only: bool,
    approval: Arc<dyn ApprovalSink>,
    audit: Arc<SequenceAuditSink>,
    audit_state: Arc<AuditState>,
) -> PolicyGuard {
    let mut ctx = context(
        principal,
        Environment::Local,
        PolicyConfig::default(),
        approval,
        audit,
        audit_state,
    );
    ctx.read_only = read_only;
    PolicyGuard::new(Arc::new(PanickingConn), ctx)
}

fn control() -> OperationControl {
    OperationControl::new(CancellationToken::new(), None)
}

async fn run(
    guard: &PolicyGuard,
    operation: AdministrativeOperation,
    ran: &Arc<AtomicUsize>,
) -> Result<(), DriverError> {
    let ran = ran.clone();
    guard
        .run_administrative(operation, &control(), async move {
            ran.fetch_add(1, Ordering::SeqCst);
            Ok(())
        })
        .await
}

fn statuses(audit: &SequenceAuditSink) -> Vec<(AuditRecordPhase, AuditTerminalStatus)> {
    audit
        .events
        .lock()
        .expect("event lock")
        .iter()
        .inspect(|event| assert_eq!(event.operation_class, AuditOperationClass::Administrative))
        .map(|event| (event.phase, event.terminal_status))
        .collect()
}

#[tokio::test]
async fn a_backup_on_a_read_only_connection_runs_without_approval_and_is_audited() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let calls = Arc::new(AtomicUsize::new(0));
    let approval = Arc::new(CountingApprovalSink { calls: calls.clone() });
    let guard = guard(
        Principal::human_gui(),
        true,
        approval,
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    let ran = Arc::new(AtomicUsize::new(0));

    run(&guard, AdministrativeOperation::Backup, &ran)
        .await
        .expect("backup");

    assert_eq!(ran.load(Ordering::SeqCst), 1);
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Succeeded),
        ]
    );
}

#[tokio::test]
async fn agents_cannot_back_up_or_restore() {
    for operation in [AdministrativeOperation::Backup, AdministrativeOperation::Restore] {
        let audit = Arc::new(SequenceAuditSink::new(vec![]));
        let guard = guard(
            agent(),
            false,
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        );
        let ran = Arc::new(AtomicUsize::new(0));

        let error = run(&guard, operation, &ran).await.expect_err("agent refused");

        assert!(
            matches!(error, DriverError::PolicyDenied(_)),
            "{operation:?}: {error:?}"
        );
        assert_eq!(ran.load(Ordering::SeqCst), 0);
        assert_eq!(
            statuses(&audit),
            [(AuditRecordPhase::Outcome, AuditTerminalStatus::Denied)]
        );
    }
}

#[tokio::test]
async fn a_restore_on_a_read_only_connection_is_refused() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = guard(
        Principal::human_gui(),
        true,
        Arc::new(AutoApproveSink),
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    let ran = Arc::new(AtomicUsize::new(0));

    let error = run(&guard, AdministrativeOperation::Restore, &ran)
        .await
        .expect_err("read-only refused");

    assert!(matches!(error, DriverError::PolicyDenied(_)));
    assert_eq!(ran.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_restore_needs_approval_even_on_a_local_connection() {
    let calls = Arc::new(AtomicUsize::new(0));
    let approved = Arc::new(SequenceApprovalSink {
        calls: calls.clone(),
        outcomes: Mutex::new(vec![ApprovalOutcome::AllowOnce]),
    });
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = guard(
        Principal::human_gui(),
        false,
        approved,
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    let ran = Arc::new(AtomicUsize::new(0));

    run(&guard, AdministrativeOperation::Restore, &ran)
        .await
        .expect("approved restore");
    let error = run(&guard, AdministrativeOperation::Restore, &ran)
        .await
        .expect_err("denied restore");

    assert!(matches!(error, DriverError::PolicyDenied(_)));
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(ran.load(Ordering::SeqCst), 1);
    let approvals: Vec<_> = audit
        .events
        .lock()
        .expect("event lock")
        .iter()
        .map(|event| event.approval_outcome)
        .collect();
    assert_eq!(
        approvals,
        [
            AuditApprovalOutcome::Approved,
            AuditApprovalOutcome::Approved,
            AuditApprovalOutcome::Denied
        ]
    );
}

#[tokio::test]
async fn nothing_runs_when_the_intent_cannot_be_recorded() {
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Intent]));
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit,
        Arc::new(AuditState::new()),
    );
    let ran = Arc::new(AtomicUsize::new(0));

    let error = run(&guard, AdministrativeOperation::Backup, &ran)
        .await
        .expect_err("intent failure refuses");

    assert!(matches!(error, DriverError::PolicyDenied(_)));
    assert_eq!(ran.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_cancelled_operation_records_a_cancelled_outcome() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    let control = control();
    let token = control.cancellation_token().clone();

    let error = guard
        .run_administrative(AdministrativeOperation::Backup, &control, async move {
            token.cancel();
            std::future::pending::<Result<(), DriverError>>().await
        })
        .await
        .expect_err("cancelled");

    assert!(matches!(error, DriverError::Cancelled));
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Cancelled),
        ]
    );
}

#[tokio::test]
async fn a_cancelled_restore_after_dispatch_is_unknown_and_disables_governed_writes() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit.clone(),
        state.clone(),
    );
    let control = control();
    let token = control.cancellation_token().clone();
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mark_dispatched = dispatched.clone();

    let error = guard
        .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control, dispatched, async move {
            mark_dispatched.store(true, std::sync::atomic::Ordering::Release);
            token.cancel();
            std::future::pending::<Result<(), DriverError>>().await
        })
        .await
        .expect_err("restore outcome is unknown");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(state.governed_writes_disabled());
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Unknown),
        ]
    );
}

#[tokio::test]
async fn cancelling_a_restore_before_dispatch_keeps_the_session_available() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit.clone(),
        state.clone(),
    );
    let control = control();
    let token = control.cancellation_token().clone();
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));

    let error = guard
        .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control, dispatched, async move {
            token.cancel();
            std::future::pending::<Result<(), DriverError>>().await
        })
        .await
        .expect_err("cancelled before dispatch");

    assert!(matches!(error, DriverError::Cancelled));
    assert!(!state.governed_writes_disabled());
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Cancelled),
        ]
    );
}

#[tokio::test]
async fn a_timed_out_restore_after_dispatch_is_unknown_and_disables_governed_writes() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit.clone(),
        state.clone(),
    );
    let control = OperationControl::new(
        CancellationToken::new(),
        Some(tokio::time::Instant::now() + std::time::Duration::from_secs(1)),
    );
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mark_dispatched = dispatched.clone();

    let error = guard
        .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control, dispatched, async move {
            mark_dispatched.store(true, std::sync::atomic::Ordering::Release);
            std::future::pending::<Result<(), DriverError>>().await
        })
        .await
        .expect_err("restore outcome is unknown");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(state.governed_writes_disabled());
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Unknown),
        ]
    );
}

#[tokio::test]
async fn a_failed_restore_after_dispatch_is_unknown_and_disables_governed_writes() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit.clone(),
        state.clone(),
    );
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mark_dispatched = dispatched.clone();

    let error = guard
        .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control(), dispatched, async move {
            mark_dispatched.store(true, std::sync::atomic::Ordering::Release);
            Err::<(), _>(DriverError::Internal("pg_restore exited unsuccessfully".into()))
        })
        .await
        .expect_err("restore outcome is unknown");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert!(state.governed_writes_disabled());
    assert_eq!(
        statuses(&audit),
        [
            (AuditRecordPhase::Intent, AuditTerminalStatus::Pending),
            (AuditRecordPhase::Outcome, AuditTerminalStatus::Unknown),
        ]
    );
}

#[tokio::test]
async fn a_completed_restore_disarms_the_pending_write_guard() {
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        Arc::new(SequenceAuditSink::new(vec![])),
        state.clone(),
    );
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mark_dispatched = dispatched.clone();

    guard
        .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control(), dispatched, async move {
            mark_dispatched.store(true, std::sync::atomic::Ordering::Release);
            Ok(())
        })
        .await
        .expect("restore");

    assert!(!state.governed_writes_disabled());
}

#[tokio::test]
async fn dropping_a_started_restore_disables_governed_writes() {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit,
        state.clone(),
    );
    let dispatched = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let mark_dispatched = dispatched.clone();
    let observe_dispatch = dispatched.clone();
    let control = control();
    let task = tokio::spawn(async move {
        guard
            .run_administrative_with_dispatch(AdministrativeOperation::Restore, &control, dispatched, async move {
                mark_dispatched.store(true, std::sync::atomic::Ordering::Release);
                std::future::pending::<Result<(), DriverError>>().await
            })
            .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(1), async {
        while !observe_dispatch.load(std::sync::atomic::Ordering::Acquire) {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("restore dispatch");
    task.abort();
    let _ = task.await;

    assert!(state.governed_writes_disabled());
}

#[tokio::test]
async fn a_lost_outcome_fails_the_operation_and_disables_governed_writes() {
    let audit_state = Arc::new(AuditState::new());
    let audit = Arc::new(SequenceAuditSink::new(vec![AuditRecordPhase::Outcome]));
    let guard = guard(
        Principal::human_gui(),
        false,
        Arc::new(AutoApproveSink),
        audit,
        audit_state.clone(),
    );
    let ran = Arc::new(AtomicUsize::new(0));

    let error = run(&guard, AdministrativeOperation::Backup, &ran)
        .await
        .expect_err("outcome failure");

    assert!(matches!(error, DriverError::Internal(_)));
    assert_eq!(ran.load(Ordering::SeqCst), 1);
    assert!(audit_state.governed_writes_disabled());
}
