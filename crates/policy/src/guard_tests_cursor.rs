use std::collections::VecDeque;
use std::sync::Mutex;

use super::*;
use crate::approval::AutoApproveSink;
use crate::audit::{AuditRecordPhase, AuditTerminalStatus};
use tablepro_core::{QueryCursorId, QueryCursorPage};
use tokio_util::sync::CancellationToken;

struct CursorScript {
    id: QueryCursorId,
    pages: Mutex<VecDeque<QueryCursorPage>>,
    failed_fetch: Option<usize>,
    fetch_count: Mutex<usize>,
    opened_sql: Mutex<Vec<String>>,
    unsupported_cursor: bool,
    materialized_sql: Mutex<Vec<String>>,
    closed: Mutex<usize>,
}

struct CursorSession {
    script: Arc<CursorScript>,
    usable: bool,
}

struct CursorConnection(Arc<CursorScript>);

fn page(value: &str, has_next_page: bool) -> QueryCursorPage {
    QueryCursorPage {
        result: QueryResult {
            columns: vec![ColumnInfo {
                name: "password".into(),
                data_type: "text".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: vec![vec![Value::Text(value.into())]],
            truncated: false,
        },
        has_next_page,
    }
}

fn make_guard(
    pages: Vec<QueryCursorPage>,
    failed_fetch: Option<usize>,
    unsupported_cursor: bool,
) -> (PolicyGuard, Arc<CursorScript>, Arc<SequenceAuditSink>) {
    let script = Arc::new(CursorScript {
        id: QueryCursorId::new(),
        pages: Mutex::new(pages.into()),
        failed_fetch,
        fetch_count: Mutex::new(0),
        opened_sql: Mutex::new(Vec::new()),
        unsupported_cursor,
        materialized_sql: Mutex::new(Vec::new()),
        closed: Mutex::new(0),
    });
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let context = context(
        Principal::Agent {
            token: "agent-token".into(),
            client: None,
            model: None,
        },
        Environment::Staging,
        PolicyConfig::default(),
        Arc::new(AutoApproveSink),
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    let guard = PolicyGuard::new(Arc::new(CursorConnection(script.clone())), context);
    (guard, script, audit)
}

#[async_trait]
impl tablepro_core::Session for CursorSession {
    async fn query_params_controlled(
        &mut self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryResult, DriverError> {
        if !sql.starts_with("BEGIN ") {
            self.script
                .materialized_sql
                .lock()
                .expect("query lock")
                .push(sql.into());
        }
        Ok(empty_result())
    }

    async fn open_query_cursor_controlled(
        &mut self,
        sql: &str,
        _params: &[Value],
        _control: &OperationControl,
    ) -> Result<QueryCursorId, DriverError> {
        self.script.opened_sql.lock().expect("open lock").push(sql.into());
        if self.script.unsupported_cursor {
            return Err(DriverError::Unsupported("forward-only query cursors".into()));
        }
        Ok(self.script.id)
    }

    async fn fetch_query_cursor_page_controlled(
        &mut self,
        id: QueryCursorId,
        control: &OperationControl,
    ) -> Result<QueryCursorPage, DriverError> {
        tablepro_core::check_pre_dispatch(control)?;
        if control.cancellation_token().is_cancelled() {
            return Err(DriverError::Cancelled);
        }
        assert_eq!(id, self.script.id);
        let mut fetch_count = self.script.fetch_count.lock().expect("fetch lock");
        *fetch_count += 1;
        if self.script.failed_fetch == Some(*fetch_count) {
            return Err(query_error());
        }
        Ok(self
            .script
            .pages
            .lock()
            .expect("page lock")
            .pop_front()
            .unwrap_or(QueryCursorPage {
                result: empty_result(),
                has_next_page: false,
            }))
    }

    async fn close_query_cursor_controlled(
        &mut self,
        id: QueryCursorId,
        _control: &OperationControl,
    ) -> Result<(), DriverError> {
        assert_eq!(id, self.script.id);
        *self.script.closed.lock().expect("close lock") += 1;
        Ok(())
    }

    fn is_usable(&self) -> bool {
        self.usable
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait]
impl Connection for CursorConnection {
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        Ok(vec![])
    }

    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("cursor fixture row fetch".into()))
    }

    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        Err(DriverError::Unsupported("cursor fixture query".into()))
    }

    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("cursor fixture execute".into()))
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Err(DriverError::Unsupported("cursor fixture parameterized execute".into()))
    }

    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        Err(DriverError::Unsupported("cursor fixture transaction".into()))
    }

    async fn open_session(&self) -> Result<Box<dyn tablepro_core::Session>, DriverError> {
        Ok(Box::new(CursorSession {
            script: self.0.clone(),
            usable: true,
        }))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

async fn begin_read_snapshot(session: &mut Box<dyn tablepro_core::Session>) {
    session
        .query_params_controlled(
            "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("read snapshot");
}

#[tokio::test]
async fn cursor_masks_every_page_and_keeps_one_audit_operation_id() {
    let (guard, _, audit) = make_guard(
        vec![page("first-secret", true), page("second-secret", false)],
        None,
        false,
    );
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("open guarded cursor");

    for expected_has_next in [true, false] {
        let result = session
            .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(CancellationToken::new(), None))
            .await
            .expect("fetch guarded page");
        assert_eq!(result.has_next_page, expected_has_next);
        assert_eq!(result.result.rows[0][0], Value::Text("***REDACTED***".into()));
    }

    session
        .close_query_cursor_controlled(cursor, &OperationControl::new(CancellationToken::new(), None))
        .await
        .expect("close guarded cursor");
    let events = audit.events.lock().expect("audit lock");
    let query_hash = hex::encode(Sha256::digest(b"SELECT password FROM accounts"));
    let cursor_events = events
        .iter()
        .filter(|event| event.sql_hash == query_hash)
        .collect::<Vec<_>>();
    assert_eq!(cursor_events.len(), 3);
    assert!(
        cursor_events
            .iter()
            .all(|event| event.operation_id == cursor_events[0].operation_id)
    );
    assert_eq!(cursor_events[0].phase, AuditRecordPhase::Intent);
    assert_eq!(cursor_events[1].phase, AuditRecordPhase::Outcome);
    assert_eq!(cursor_events[1].terminal_status, AuditTerminalStatus::Pending);
    assert_eq!(cursor_events[2].phase, AuditRecordPhase::Outcome);
    assert_eq!(cursor_events[2].terminal_status, AuditTerminalStatus::Succeeded);
}

#[tokio::test]
async fn a_page_error_closes_the_cursor_and_records_failure_after_prior_pages() {
    let (guard, script, audit) = make_guard(vec![page("first-secret", true)], Some(2), false);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("open guarded cursor");

    let first = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(CancellationToken::new(), None))
        .await
        .expect("first page remains available");
    assert_eq!(first.result.rows[0][0], Value::Text("***REDACTED***".into()));
    let failure = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(CancellationToken::new(), None))
        .await
        .expect_err("second page fails");
    assert!(matches!(failure, DriverError::Query { .. }), "{failure:?}");
    assert_eq!(*script.closed.lock().expect("close lock"), 1);
    let events = audit.events.lock().expect("audit lock");
    let query_hash = hex::encode(Sha256::digest(b"SELECT password FROM accounts"));
    let outcome = events
        .iter()
        .rev()
        .find(|event| event.sql_hash == query_hash && event.phase == AuditRecordPhase::Outcome)
        .expect("terminal cursor outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Failed);
}

#[tokio::test]
async fn cancellation_after_a_delivered_page_closes_and_audits_the_cursor() {
    let (guard, script, audit) = make_guard(vec![page("secret", true)], None, false);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("open guarded cursor");
    let cancellation = CancellationToken::new();

    let first = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(cancellation.clone(), None))
        .await
        .expect("first page remains available");
    assert_eq!(first.result.rows[0][0], Value::Text("***REDACTED***".into()));
    cancellation.cancel();
    let result = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(cancellation, None))
        .await;

    assert!(matches!(result, Err(DriverError::Cancelled)), "{result:?}");
    assert_eq!(*script.closed.lock().expect("close lock"), 1);
    {
        let events = audit.events.lock().expect("audit lock");
        let query_hash = hex::encode(Sha256::digest(b"SELECT password FROM accounts"));
        let outcome = events
            .iter()
            .rev()
            .find(|event| event.sql_hash == query_hash && event.phase == AuditRecordPhase::Outcome)
            .expect("cancelled cursor outcome");
        assert_eq!(outcome.terminal_status, AuditTerminalStatus::Cancelled);
    }
    session.close().await.expect("close cancelled read snapshot");
}

#[tokio::test]
async fn a_cursor_timeout_closes_and_audits_the_cursor() {
    let (guard, script, audit) = make_guard(vec![page("secret", true)], None, false);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("open guarded cursor");
    let result = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::with_timeout(Duration::ZERO))
        .await;

    assert!(matches!(result, Err(DriverError::TimedOut)), "{result:?}");
    assert_eq!(*script.closed.lock().expect("close lock"), 1);
    let events = audit.events.lock().expect("audit lock");
    let query_hash = hex::encode(Sha256::digest(b"SELECT password FROM accounts"));
    let outcome = events
        .iter()
        .rev()
        .find(|event| event.sql_hash == query_hash && event.phase == AuditRecordPhase::Outcome)
        .expect("timed out cursor outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::TimedOut);
}

#[tokio::test]
async fn closing_a_session_closes_an_open_cursor_and_audits_cancellation() {
    let (guard, script, audit) = make_guard(vec![page("secret", true)], None, false);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let cursor = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await
        .expect("open guarded cursor");
    let first = session
        .fetch_query_cursor_page_controlled(cursor, &OperationControl::new(CancellationToken::new(), None))
        .await
        .expect("first page remains available");
    session.close().await.expect("close session");
    assert_eq!(first.result.rows[0][0], Value::Text("***REDACTED***".into()));

    assert_eq!(*script.closed.lock().expect("close lock"), 1);
    let events = audit.events.lock().expect("audit lock");
    let query_hash = hex::encode(Sha256::digest(b"SELECT password FROM accounts"));
    let outcome = events
        .iter()
        .rev()
        .find(|event| event.sql_hash == query_hash && event.phase == AuditRecordPhase::Outcome)
        .expect("cancelled cursor outcome");
    assert_eq!(outcome.terminal_status, AuditTerminalStatus::Cancelled);
}

#[tokio::test]
async fn cursor_refuses_multi_statement_and_non_read_queries_before_driver_dispatch() {
    let (guard, script, _) = make_guard(vec![], None, false);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    for sql in [
        "SELECT 1; SELECT 2",
        "DELETE FROM accounts",
        "SELECT pg_terminate_backend(1)",
    ] {
        let result = session
            .open_query_cursor_controlled(sql, &[], &OperationControl::new(CancellationToken::new(), None))
            .await;
        assert!(matches!(result, Err(DriverError::PolicyDenied(_))), "{result:?}");
    }
    assert!(script.opened_sql.lock().expect("open lock").is_empty());
}

#[tokio::test]
async fn unsupported_cursor_is_refused_without_materializing_the_query() {
    let (guard, script, _) = make_guard(vec![], None, true);
    let mut session = guard.open_session().await.expect("open guarded session");
    begin_read_snapshot(&mut session).await;
    let result = session
        .open_query_cursor_controlled(
            "SELECT password FROM accounts",
            &[],
            &OperationControl::new(CancellationToken::new(), None),
        )
        .await;

    assert!(matches!(result, Err(DriverError::Unsupported(_))), "{result:?}");
    assert!(script.materialized_sql.lock().expect("query lock").is_empty());
}
