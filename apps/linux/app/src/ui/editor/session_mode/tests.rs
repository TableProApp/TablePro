use super::*;
use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

#[test]
fn a_running_query_or_open_session_delays_teardown() {
    assert!(!can_start_session_close(true, false, false, true));
    assert!(!can_start_session_close(true, false, true, false));
    assert!(!can_start_session_close(true, true, false, false));
    assert!(can_start_session_close(true, false, false, false));
}

struct FailFirstCommit(bool);

struct DelayedClose {
    started: tokio::sync::oneshot::Sender<()>,
    release: tokio::sync::oneshot::Receiver<()>,
}

struct CountedClose {
    calls: Arc<AtomicUsize>,
    result: Result<(), DriverError>,
}

struct HealthSession {
    usable: Arc<AtomicBool>,
    queries: Arc<AtomicUsize>,
    fail_query: bool,
    close_unknown: bool,
}

struct DelayedRollback {
    rollback_started: Option<tokio::sync::oneshot::Sender<()>>,
    finish_rollback: Option<tokio::sync::oneshot::Receiver<()>>,
    close_started: Option<tokio::sync::oneshot::Sender<()>>,
    finish_close: Option<tokio::sync::oneshot::Receiver<()>>,
}

struct FailingRollback {
    close_calls: Arc<AtomicUsize>,
}

#[async_trait::async_trait]
impl Session for DelayedClose {
    async fn query_params_controlled(
        &mut self,
        _: &str,
        _: &[Value],
        _: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        let _ = self.started.send(());
        let _ = self.release.await;
        Ok(())
    }
}

#[async_trait::async_trait]
impl Session for CountedClose {
    async fn query_params_controlled(
        &mut self,
        _: &str,
        _: &[Value],
        _: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.result
    }
}

#[async_trait::async_trait]
impl Session for FailFirstCommit {
    async fn commit_controlled(&mut self, control: &OperationControl) -> Result<SessionCommitOutcome, DriverError> {
        self.query_params_controlled("COMMIT", &[], control).await?;
        Ok(SessionCommitOutcome::Committed)
    }

    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        assert_eq!(sql, "COMMIT");
        if self.0 {
            self.0 = false;
            return Err(DriverError::TimedOut);
        }
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl Session for HealthSession {
    async fn query_params_controlled(
        &mut self,
        _: &str,
        _: &[Value],
        _: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        self.queries.fetch_add(1, Ordering::SeqCst);
        if self.fail_query {
            Err(DriverError::Unsupported("ordinary statement error".into()))
        } else {
            Ok(QueryResult {
                columns: Vec::new(),
                rows: Vec::new(),
                truncated: false,
            })
        }
    }

    fn is_usable(&self) -> bool {
        self.usable.load(Ordering::SeqCst)
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        if self.close_unknown {
            Err(DriverError::OperationOutcomeUnknown {
                source: Box::new(DriverError::Disconnected),
            })
        } else {
            Ok(())
        }
    }
}

#[async_trait::async_trait]
impl Session for DelayedRollback {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _: &[Value],
        _: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        assert_eq!(sql, "ROLLBACK");
        let _ = self.rollback_started.take().expect("rollback signal").send(());
        let _ = self.finish_rollback.take().expect("rollback gate").await;
        Ok(QueryResult {
            columns: Vec::new(),
            rows: Vec::new(),
            truncated: false,
        })
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(mut self: Box<Self>) -> Result<(), DriverError> {
        let _ = self.close_started.take().expect("close signal").send(());
        let _ = self.finish_close.take().expect("close gate").await;
        Ok(())
    }
}

#[async_trait::async_trait]
impl Session for FailingRollback {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _: &[Value],
        _: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        assert_eq!(sql, "ROLLBACK");
        Err(DriverError::TimedOut)
    }

    fn is_usable(&self) -> bool {
        true
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        self.close_calls.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
}

#[tokio::test]
async fn detached_cleanup_logs_category_without_server_payload() {
    let log = tempfile::NamedTempFile::new().unwrap();
    let subscriber = tracing_subscriber::fmt().with_writer(log.reopen().unwrap()).finish();
    let _guard = tracing::subscriber::set_default(subscriber);
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(CountedClose {
        calls: Arc::new(AtomicUsize::new(0)),
        result: Err(DriverError::query("private-session-payload")),
    }))));
    close_detached_session(shared).await;
    let output = std::fs::read_to_string(log.path()).unwrap();
    assert!(!output.contains("private-session-payload"));
    assert!(output.contains("query"));
}

#[tokio::test]
async fn a_failed_commit_leaves_the_session_available_for_retry() {
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(FailFirstCommit(true)))));
    assert!(matches!(commit_session(&shared).await, Err(DriverError::TimedOut)));
    assert!(shared.lock().await.is_some());
    commit_session(&shared).await.expect("retry commit");
}

#[tokio::test]
async fn rollback_completes_before_session_close_and_end_reports_only_after_close() {
    let (rollback_started, started) = tokio::sync::oneshot::channel();
    let (finish_rollback, rollback_gate) = tokio::sync::oneshot::channel();
    let (close_started, mut closed) = tokio::sync::oneshot::channel();
    let (finish_close, close_gate) = tokio::sync::oneshot::channel();
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(DelayedRollback {
        rollback_started: Some(rollback_started),
        finish_rollback: Some(rollback_gate),
        close_started: Some(close_started),
        finish_close: Some(close_gate),
    }))));
    let ending_shared = shared.clone();
    let ending = tokio::spawn(async move { rollback_and_close(&ending_shared).await });

    started.await.expect("ROLLBACK started");
    assert!(closed.try_recv().is_err(), "close must wait for ROLLBACK");
    assert!(!ending.is_finished(), "the editor must wait while ROLLBACK runs");
    finish_rollback.send(()).expect("finish ROLLBACK");
    closed.await.expect("close started after ROLLBACK");
    assert!(!ending.is_finished(), "the editor must wait while close runs");
    finish_close.send(()).expect("finish close");
    ending.await.expect("end task").expect("rollback and close succeed");
}

#[tokio::test]
async fn rollback_failure_still_closes_and_returns_the_rollback_error() {
    let close_calls = Arc::new(AtomicUsize::new(0));
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(FailingRollback {
        close_calls: close_calls.clone(),
    }))));

    assert!(matches!(rollback_and_close(&shared).await, Err(DriverError::TimedOut)));
    assert!(shared.lock().await.is_none());
    assert_eq!(close_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_retired_transaction_session_closes_without_sending_rollback() {
    let queries = Arc::new(AtomicUsize::new(0));
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(HealthSession {
        usable: Arc::new(AtomicBool::new(false)),
        queries: queries.clone(),
        fail_query: false,
        close_unknown: true,
    }))));

    assert!(matches!(
        rollback_and_close(&shared).await,
        Err(DriverError::OperationOutcomeUnknown { .. })
    ));
    assert_eq!(queries.load(Ordering::SeqCst), 0);
    assert!(shared.lock().await.is_none());
}

#[test]
#[ignore = "requires an isolated GTK display"]
fn session_end_dialog_keeps_the_toggle_active_until_the_selected_action_finishes() {
    gtk::init().unwrap();
    let button = gtk::ToggleButton::new();
    button.set_active(true);
    let ended = Rc::new(Cell::new(None));
    let ended_callback = ended.clone();
    let dialog = session_end_dialog(&button, move |commit| ended_callback.set(Some(commit)));

    dialog.emit_by_name::<()>("response", &[&"cancel"]);

    assert!(button.is_active());
    assert_eq!(ended.get(), None);
    assert_eq!(dialog.default_response().as_deref(), Some("cancel"));
    assert_eq!(dialog.close_response().as_str(), "cancel");

    let ended = Rc::new(Cell::new(None));
    let ended_callback = ended.clone();
    let dialog = session_end_dialog(&button, move |commit| ended_callback.set(Some(commit)));
    dialog.emit_by_name::<()>("response", &[&"rollback"]);
    assert_eq!(ended.get(), Some(false));
    assert!(
        button.is_active(),
        "the session stays visible until rollback and close finish"
    );

    let ended = Rc::new(Cell::new(None));
    let ended_callback = ended.clone();
    let dialog = session_end_dialog(&button, move |commit| ended_callback.set(Some(commit)));
    dialog.emit_by_name::<()>("response", &[&"commit"]);
    assert_eq!(ended.get(), Some(true));
    assert!(
        button.is_active(),
        "commit selection also leaves completion to the session handler"
    );
}

#[tokio::test]
async fn teardown_waits_for_delayed_session_close_before_completing() {
    let (started, did_start) = tokio::sync::oneshot::channel();
    let (release, wait) = tokio::sync::oneshot::channel();
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(DelayedClose {
        started,
        release: wait,
    }))));
    let closing = tokio::spawn(close_for_teardown(shared.clone()));

    did_start.await.expect("close started");
    assert!(shared.lock().await.is_none());
    assert!(!closing.is_finished(), "teardown must wait for close to return");
    release.send(()).expect("release close");
    closing.await.expect("close task").expect("close succeeds");
}

#[tokio::test]
async fn teardown_propagates_close_errors_and_takes_the_session_once() {
    let calls = Arc::new(AtomicUsize::new(0));
    let shared: SharedSession = Arc::new(tokio::sync::Mutex::new(Some(Box::new(CountedClose {
        calls: calls.clone(),
        result: Err(DriverError::TimedOut),
    }))));

    assert!(matches!(
        close_for_teardown(shared.clone()).await,
        Err(DriverError::TimedOut)
    ));
    close_for_teardown(shared)
        .await
        .expect("repeated cleanup is idempotent");
    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_closed_session_target_refuses_instead_of_falling_back_to_the_pool() {
    let id = Uuid::new_v4();
    let target = StatementTarget::Session {
        id,
        shared: Arc::new(tokio::sync::Mutex::new(None)),
    };
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(1));

    let error = target.query("SELECT 1", &[], &control).await.unwrap_err();

    assert!(matches!(error, DriverError::Unsupported(_)));
    assert_eq!(target.session_state().await, Some((id, false, false)));
}

#[tokio::test]
async fn a_retired_session_reports_its_identity_and_never_dispatches_again() {
    let id = Uuid::new_v4();
    let queries = Arc::new(AtomicUsize::new(0));
    let target = StatementTarget::Session {
        id,
        shared: Arc::new(tokio::sync::Mutex::new(Some(Box::new(HealthSession {
            usable: Arc::new(AtomicBool::new(false)),
            queries: queries.clone(),
            fail_query: false,
            close_unknown: false,
        })))),
    };
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(1));

    assert_eq!(target.session_state().await, Some((id, false, false)));
    assert!(matches!(
        target.query("SELECT 1", &[], &control).await,
        Err(DriverError::Unsupported(_))
    ));
    assert_eq!(queries.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn an_ordinary_statement_error_keeps_a_usable_session() {
    let id = Uuid::new_v4();
    let queries = Arc::new(AtomicUsize::new(0));
    let target = StatementTarget::Session {
        id,
        shared: Arc::new(tokio::sync::Mutex::new(Some(Box::new(HealthSession {
            usable: Arc::new(AtomicBool::new(true)),
            queries: queries.clone(),
            fail_query: true,
            close_unknown: false,
        })))),
    };
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(1));

    assert!(target.query("SELECT invalid", &[], &control).await.is_err());
    assert_eq!(target.session_state().await, Some((id, false, true)));
    assert_eq!(queries.load(Ordering::SeqCst), 1);
}

#[test]
fn a_retired_session_only_blocks_the_connection_that_lost_it() {
    let retired_connection = Uuid::new_v4();
    assert!(retired_connection_matches(
        Some((retired_connection, Uuid::new_v4())),
        Some(retired_connection)
    ));
    assert!(!retired_connection_matches(
        Some((retired_connection, Uuid::new_v4())),
        Some(Uuid::new_v4())
    ));
}

#[test]
fn callbacks_from_an_older_editor_session_do_not_match_the_current_session() {
    let old = Uuid::new_v4();
    let current = Uuid::new_v4();
    assert!(!session_callback_matches(old, Some(current)));
    assert!(!session_callback_matches(old, None));
    assert!(session_callback_matches(current, Some(current)));
    let connection = Uuid::new_v4();
    assert!(!open_callback_matches(old, Some(current), connection, Some(connection)));
    assert!(!open_callback_matches(current, Some(current), connection, None));
    assert!(open_callback_matches(
        current,
        Some(current),
        connection,
        Some(connection)
    ));
    assert!(!commit_callback_matches(old, Some(current), Some(old)));
    assert!(!commit_callback_matches(current, Some(current), None));
    assert!(commit_callback_matches(current, Some(current), Some(current)));
}

#[test]
fn a_late_transaction_state_does_not_change_a_replacement_session() {
    let old_id = Uuid::new_v4();
    let current_id = Uuid::new_v4();
    let mut session = EditorSession {
        id: current_id,
        shared: Arc::new(tokio::sync::Mutex::new(None)),
        connection_id: Uuid::new_v4(),
        connection_identity: None,
        transaction_open: false,
    };

    assert!(!apply_transaction_state(&mut session, old_id, true));
    assert!(!session.transaction_open);
    assert!(apply_transaction_state(&mut session, current_id, true));
    assert!(session.transaction_open);
}
