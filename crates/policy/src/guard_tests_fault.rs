use super::*;
use crate::approval::AutoApproveSink;
use crate::guard::ConnectionFaultSink;

#[derive(Default)]
struct RecordingFault {
    operations: Mutex<Vec<String>>,
}

impl ConnectionFaultSink for RecordingFault {
    fn connection_became_unusable(&self, operation: &str) {
        self.operations.lock().expect("fault lock").push(operation.to_string());
    }
}

fn guard_with_fault(connection: Arc<dyn Connection>, fault: Arc<RecordingFault>) -> PolicyGuard {
    PolicyGuard::new(
        connection,
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            Arc::new(SequenceAuditSink::new(vec![])),
            Arc::new(AuditState::new()),
        ),
    )
    .with_fault_sink(fault)
}

#[tokio::test]
async fn a_panicking_read_reports_the_connection_unusable() {
    let fault = Arc::new(RecordingFault::default());
    let guard = guard_with_fault(Arc::new(PanickingConn), fault.clone());

    let error = guard.list_tables().await.expect_err("panic becomes an error");

    assert!(matches!(error, DriverError::Internal(_)));
    assert!(!error.to_string().contains("codec read past the end"));
    assert_eq!(*fault.operations.lock().expect("fault lock"), vec!["LIST TABLES"]);
}

#[tokio::test]
async fn a_panicking_write_reports_the_connection_unusable() {
    let fault = Arc::new(RecordingFault::default());
    let guard = guard_with_fault(Arc::new(PanickingConn), fault.clone());

    let error = guard
        .execute("INSERT INTO jobs(id) VALUES (1)")
        .await
        .expect_err("panic becomes an error");

    assert!(matches!(error, DriverError::OperationOutcomeUnknown { .. }));
    assert_eq!(fault.operations.lock().expect("fault lock").len(), 1);
}

#[tokio::test]
async fn a_disconnected_read_reports_the_connection_unusable() {
    let fault = Arc::new(RecordingFault::default());
    let guard = guard_with_fault(Arc::new(DisconnectedConn), fault.clone());

    let error = guard.list_tables().await.expect_err("disconnected is surfaced");

    assert!(matches!(error, DriverError::Disconnected));
    assert_eq!(*fault.operations.lock().expect("fault lock"), vec!["LIST TABLES"]);
}

#[tokio::test]
async fn a_healthy_read_reports_nothing() {
    let fault = Arc::new(RecordingFault::default());
    let guard = guard_with_fault(Arc::new(AmbiguousWriteConn), fault.clone());

    guard.list_tables().await.expect("healthy read");

    assert!(fault.operations.lock().expect("fault lock").is_empty());
}
