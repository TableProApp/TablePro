use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use super::*;
use crate::approval::AutoApproveSink;

struct OneWriteInFlightAuditSink {
    next_write_intent_fails: AtomicBool,
    events: Arc<Mutex<Vec<AuditEvent>>>,
}

#[async_trait]
impl AuditSink for OneWriteInFlightAuditSink {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        if event.phase == AuditRecordPhase::Intent
            && event.operation_class.is_write()
            && self.next_write_intent_fails.swap(false, Ordering::SeqCst)
        {
            return Err(AuditError::WriteInFlight);
        }
        self.events.lock().unwrap().push(event);
        Ok(())
    }
}

#[tokio::test]
async fn an_in_flight_write_refusal_is_audited_without_disabling_later_writes() {
    let executes = Arc::new(AtomicUsize::new(0));
    let state = Arc::new(AuditState::new());
    let events = Arc::new(Mutex::new(Vec::new()));
    let mut policy = PolicyConfig::default();
    policy
        .environments
        .entry("local".into())
        .or_default()
        .human_allow_unaudited_writes = Some(true);
    let guard = PolicyGuard::new(
        connection(executes.clone(), Arc::new(AtomicUsize::new(0))),
        context(
            Principal::human_gui(),
            Environment::Local,
            policy,
            Arc::new(AutoApproveSink),
            Arc::new(OneWriteInFlightAuditSink {
                next_write_intent_fails: AtomicBool::new(true),
                events: events.clone(),
            }),
            state.clone(),
        ),
    );

    guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("the competing write must be refused");
    assert!(!state.governed_writes_disabled());
    guard.execute("INSERT INTO jobs(id) VALUES (2)").await.unwrap();

    assert_eq!(executes.load(Ordering::SeqCst), 1);
    let events = events.lock().unwrap();
    assert!(
        events
            .iter()
            .any(|event| event.phase == AuditRecordPhase::Outcome
                && event.terminal_status == AuditTerminalStatus::Denied)
    );
    assert!(events.iter().any(
        |event| event.phase == AuditRecordPhase::Outcome && event.terminal_status == AuditTerminalStatus::Succeeded
    ));
}
