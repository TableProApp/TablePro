use super::*;
use crate::guard::{BulkBatch, BulkInsertEnd, BulkInsertRequest, BulkInsertScope};

const INSERT: &str = "INSERT INTO people (id, name) VALUES ($1, $2)";

struct BulkConn {
    batches: Arc<Mutex<Vec<usize>>>,
    fails_from_batch: usize,
}

impl BulkConn {
    fn open(fails_from_batch: usize) -> (Arc<dyn Connection>, Arc<Mutex<Vec<usize>>>) {
        let batches = Arc::new(Mutex::new(Vec::new()));
        (
            Arc::new(Self {
                batches: batches.clone(),
                fails_from_batch,
            }),
            batches,
        )
    }
}

#[async_trait]
impl Connection for BulkConn {
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
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        Ok(ExecResult { rows_affected: 1 })
    }

    async fn execute_in_transaction(&self, statements: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        let mut batches = self.batches.lock().expect("batch lock");
        if batches.len() + 1 >= self.fails_from_batch {
            return Err(query_error());
        }
        batches.push(statements.len());
        Ok(vec![1; statements.len()])
    }

    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Err(DriverError::Unsupported("begin".into()))
    }

    async fn ping(&self) -> Result<(), DriverError> {
        Ok(())
    }

    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

fn control() -> OperationControl {
    OperationControl::with_timeout(std::time::Duration::from_secs(30))
}

fn rows(count: usize) -> Vec<Vec<Value>> {
    (0..count)
        .map(|index| vec![Value::Int(index as i64), Value::Text(format!("name {index}"))])
        .collect()
}

fn batch<'a>(statement: &'a str, table: &'a str, rows: &'a [Vec<Value>]) -> BulkBatch<'a> {
    BulkBatch {
        schema: None,
        table,
        statement,
        rows,
    }
}

fn request(budget: u64) -> BulkInsertRequest {
    BulkInsertRequest {
        schema: None,
        table: "people".into(),
        statement: INSERT.into(),
        row_budget: budget,
    }
}

fn bulk_guard(
    connection: Arc<dyn Connection>,
    connection_id: Uuid,
    approval: Arc<dyn ApprovalSink>,
    audit: Arc<dyn AuditSink>,
    state: Arc<AuditState>,
) -> PolicyGuard {
    let mut ctx = context(
        Principal::human_gui(),
        Environment::Prod,
        PolicyConfig::default(),
        approval,
        audit,
        state,
    );
    ctx.connection_id = connection_id;
    PolicyGuard::new(connection, ctx)
}

fn approved_guard(
    connection: Arc<dyn Connection>,
    connection_id: Uuid,
) -> (PolicyGuard, Arc<SequenceAuditSink>, Arc<AuditState>) {
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let state = Arc::new(AuditState::new());
    let guard = bulk_guard(
        connection,
        connection_id,
        Arc::new(AutoApproveSink),
        audit.clone(),
        state.clone(),
    );
    (guard, audit, state)
}

fn events(audit: &SequenceAuditSink) -> Vec<AuditEvent> {
    audit.events.lock().expect("event lock").clone()
}

async fn end_quietly(guard: &PolicyGuard, scope: &mut BulkInsertScope) {
    let _ = guard.finish_bulk_insert(scope, BulkInsertEnd::Cancelled).await;
}

#[tokio::test]
async fn an_approved_scope_spends_exactly_its_row_budget() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(6)).await.expect("scope");
    let rows = rows(3);

    let first = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("first batch");
    let second = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("second batch");

    assert_eq!((first, second), (3, 3));
    assert_eq!(scope.remaining_rows(), 0);
    assert_eq!(*batches.lock().expect("batch lock"), vec![3, 3]);
    assert_eq!(
        guard
            .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
            .await
            .expect("finish"),
        6
    );
}

#[tokio::test]
async fn a_batch_past_the_row_budget_is_denied_and_never_reaches_the_driver() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(4)).await.expect("scope");
    let rows = rows(3);

    guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("first batch");
    let error = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("the second batch exceeds the budget");

    assert!(
        matches!(error, DriverError::PolicyDenied(ref message) if message.contains("more rows than were approved"))
    );
    assert_eq!(*batches.lock().expect("batch lock"), vec![3]);
    end_quietly(&guard, &mut scope).await;
}

#[tokio::test]
async fn a_scope_granted_for_one_table_is_denied_on_another() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(10)).await.expect("scope");
    let rows = rows(2);

    let error = guard
        .execute_bulk_batch(
            &mut scope,
            batch("INSERT INTO salaries (id, name) VALUES ($1, $2)", "salaries", &rows),
            &control(),
        )
        .await
        .expect_err("another table is not covered");

    assert!(matches!(error, DriverError::PolicyDenied(ref message) if message.contains("another table")));
    assert!(batches.lock().expect("batch lock").is_empty());
    end_quietly(&guard, &mut scope).await;
}

#[tokio::test]
async fn a_scope_granted_for_one_table_is_denied_on_another_schema() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(10)).await.expect("scope");
    let rows = rows(2);
    let mut other = batch(INSERT, "people", &rows);
    other.schema = Some("audit");

    let error = guard
        .execute_bulk_batch(&mut scope, other, &control())
        .await
        .expect_err("another schema is not covered");

    assert!(matches!(error, DriverError::PolicyDenied(ref message) if message.contains("another table")));
    end_quietly(&guard, &mut scope).await;
}

#[tokio::test]
async fn a_scope_granted_for_one_statement_is_denied_on_another() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(10)).await.expect("scope");
    let rows = rows(2);

    let error = guard
        .execute_bulk_batch(
            &mut scope,
            batch("INSERT INTO people (id) VALUES ($1)", "people", &rows),
            &control(),
        )
        .await
        .expect_err("another statement shape is not covered");

    assert!(matches!(error, DriverError::PolicyDenied(ref message) if message.contains("another statement")));
    assert!(batches.lock().expect("batch lock").is_empty());
    end_quietly(&guard, &mut scope).await;
}

#[tokio::test]
async fn a_scope_granted_on_one_connection_is_denied_on_another() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection.clone(), Uuid::new_v4());
    let (other_guard, _other_audit, _other_state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(10)).await.expect("scope");
    let rows = rows(2);

    let error = other_guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("another connection is not covered");

    assert!(matches!(error, DriverError::PolicyDenied(ref message) if message.contains("another connection")));
    assert!(batches.lock().expect("batch lock").is_empty());
    end_quietly(&guard, &mut scope).await;
}

#[tokio::test]
async fn a_scope_is_denied_once_the_import_has_ended() {
    let (connection, batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(10)).await.expect("scope");
    let rows = rows(2);
    guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("first batch");
    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    let error = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("a finished import cannot be resumed");

    assert!(matches!(error, DriverError::PolicyDenied(ref message) if message.contains("already been spent")));
    assert_eq!(*batches.lock().expect("batch lock"), vec![2]);
}

#[tokio::test]
async fn one_approval_covers_every_batch_of_one_import() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let calls = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = bulk_guard(
        connection,
        Uuid::new_v4(),
        Arc::new(CountingApprovalSink { calls: calls.clone() }),
        audit,
        Arc::new(AuditState::new()),
    );
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");
    let rows = rows(3);

    for _ in 0..3 {
        guard
            .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
            .await
            .expect("batch");
    }
    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn an_import_is_audited_as_one_operation_carrying_the_rows_it_wrote() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");
    let rows = rows(3);
    for _ in 0..3 {
        guard
            .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
            .await
            .expect("batch");
    }

    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    let events = events(&audit);
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].phase, AuditRecordPhase::Intent);
    assert_eq!(events[0].terminal_status, AuditTerminalStatus::Pending);
    assert_eq!(events[1].phase, AuditRecordPhase::Outcome);
    assert_eq!(events[1].terminal_status, AuditTerminalStatus::Succeeded);
    assert_eq!(events[1].rows_affected, Some(9));
    assert_eq!(events[1].targets, vec!["people".to_owned()]);
    assert_eq!(events[0].operation_id, events[1].operation_id);
    assert_eq!(events[1].approval_outcome, AuditApprovalOutcome::Approved);
}

#[tokio::test]
async fn a_denied_approval_writes_the_terminal_audit_state_and_grants_nothing() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = bulk_guard(
        connection,
        Uuid::new_v4(),
        Arc::new(DenyApprovalSink),
        audit.clone(),
        Arc::new(AuditState::new()),
    );

    let error = guard.begin_bulk_insert(request(9)).await.err().expect("denied");

    assert!(matches!(error, DriverError::PolicyDenied(_)));
    let events = events(&audit);
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].phase, AuditRecordPhase::Outcome);
    assert_eq!(events[0].terminal_status, AuditTerminalStatus::Denied);
    assert_eq!(events[0].approval_outcome, AuditApprovalOutcome::Denied);
    assert_eq!(events[0].error_category, Some(AuditErrorCategory::Policy));
}

#[tokio::test]
async fn a_read_only_connection_denies_an_import_before_it_asks_for_approval() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let calls = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let mut ctx = context(
        Principal::human_gui(),
        Environment::Prod,
        PolicyConfig::default(),
        Arc::new(CountingApprovalSink { calls: calls.clone() }),
        audit.clone(),
        Arc::new(AuditState::new()),
    );
    ctx.read_only = true;
    let guard = PolicyGuard::new(connection, ctx);

    let error = guard.begin_bulk_insert(request(9)).await.err().expect("denied");

    assert!(matches!(error, DriverError::PolicyDenied(_)));
    assert_eq!(calls.load(Ordering::SeqCst), 0);
    assert_eq!(events(&audit)[0].terminal_status, AuditTerminalStatus::Denied);
}

#[tokio::test]
async fn a_failure_mid_import_stops_it_and_writes_one_terminal_record_with_the_committed_rows() {
    let (connection, batches) = BulkConn::open(2);
    let (guard, audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");
    let rows = rows(3);

    guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("first batch");
    let failure = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("second batch fails");
    let committed = guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Failed(&failure))
        .await
        .expect("finish");

    assert_eq!(committed, 3);
    assert_eq!(*batches.lock().expect("batch lock"), vec![3]);
    let events = events(&audit);
    assert_eq!(events.len(), 2);
    assert_eq!(events[1].terminal_status, AuditTerminalStatus::Failed);
    assert_eq!(events[1].rows_affected, Some(3));
    assert_eq!(events[1].error_category, Some(AuditErrorCategory::Query));
}

#[tokio::test]
async fn a_failed_import_cannot_be_resumed_on_the_same_scope() {
    let (connection, _batches) = BulkConn::open(1);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");
    let rows = rows(3);
    let failure = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("first batch fails");

    let retry = guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect_err("a failed import is over");

    assert!(matches!(retry, DriverError::PolicyDenied(ref message) if message.contains("already been spent")));
    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Failed(&failure))
        .await
        .expect("finish");
}

#[tokio::test]
async fn a_cancelled_import_writes_the_cancelled_terminal_state() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");
    let rows = rows(3);
    guard
        .execute_bulk_batch(&mut scope, batch(INSERT, "people", &rows), &control())
        .await
        .expect("first batch");

    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Cancelled)
        .await
        .expect("finish");

    let events = events(&audit);
    assert_eq!(events[1].terminal_status, AuditTerminalStatus::Cancelled);
    assert_eq!(events[1].rows_affected, Some(3));
}

#[tokio::test]
async fn a_timed_out_import_writes_the_timed_out_terminal_state() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, audit, _state) = approved_guard(connection, Uuid::new_v4());
    let mut scope = guard.begin_bulk_insert(request(9)).await.expect("scope");

    guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Failed(&DriverError::TimedOut))
        .await
        .expect("finish");

    assert_eq!(events(&audit)[1].terminal_status, AuditTerminalStatus::TimedOut);
}

#[tokio::test]
async fn an_import_dropped_without_a_terminal_record_disables_governed_writes() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, state) = approved_guard(connection, Uuid::new_v4());

    drop(guard.begin_bulk_insert(request(9)).await.expect("scope"));

    assert!(state.governed_writes_disabled());
}

#[tokio::test]
async fn an_import_is_refused_when_governed_writes_are_already_disabled() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let audit = Arc::new(SequenceAuditSink::new(vec![]));
    let guard = bulk_guard(
        connection,
        Uuid::new_v4(),
        Arc::new(AutoApproveSink),
        audit,
        Arc::new(AuditState::with_governed_writes_disabled()),
    );

    let error = guard.begin_bulk_insert(request(9)).await.err().expect("refused");

    assert!(
        matches!(error, DriverError::PolicyDenied(ref message) if message.contains("governed writes are disabled"))
    );
}

#[tokio::test]
async fn a_scope_is_refused_for_anything_that_is_not_one_insert() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());

    for statement in [
        "DELETE FROM people",
        "INSERT INTO people (id) VALUES ($1); DROP TABLE people",
        "UPDATE people SET name = $1",
    ] {
        let mut request = request(9);
        request.statement = statement.into();
        let error = guard.begin_bulk_insert(request).await.err().expect("refused");
        assert!(matches!(error, DriverError::PolicyDenied(_)), "{statement}");
    }
}

#[tokio::test]
async fn a_row_budget_outside_the_import_limit_is_refused() {
    let (connection, _batches) = BulkConn::open(usize::MAX);
    let (guard, _audit, _state) = approved_guard(connection, Uuid::new_v4());

    assert!(guard.begin_bulk_insert(request(0)).await.is_err());
    assert!(
        guard
            .begin_bulk_insert(request(crate::guard::MAX_BULK_ROW_BUDGET + 1))
            .await
            .is_err()
    );
}
