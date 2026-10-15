use super::*;

use tablepro_core::{CatalogObject, CatalogObjectKind, ColumnInfo, ForeignKeyInfo, IndexInfo, TableInfo};

struct FakeTx {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl Transaction for FakeTx {
    async fn query(&mut self, _: &str) -> Result<QueryResult, DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(empty_result())
    }
    async fn query_params(&mut self, _: &str, _: &[Value]) -> Result<QueryResult, DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(empty_result())
    }
    async fn execute(&mut self, _: &str) -> Result<ExecResult, DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(ExecResult { rows_affected: 1 })
    }
    async fn execute_params(&mut self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(ExecResult { rows_affected: 1 })
    }
    async fn commit(self: Box<Self>) -> Result<(), DriverError> {
        self.calls.fetch_add(100, Ordering::SeqCst);
        Ok(())
    }
    async fn rollback(self: Box<Self>) -> Result<(), DriverError> {
        self.calls.fetch_add(1000, Ordering::SeqCst);
        Ok(())
    }
}

struct CatalogConn {
    calls: Arc<AtomicUsize>,
    fail: bool,
}

impl CatalogConn {
    fn answer<T>(&self, value: T) -> Result<T, DriverError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.fail {
            Err(DriverError::Disconnected)
        } else {
            Ok(value)
        }
    }
}

fn table() -> TableInfo {
    TableInfo {
        schema: Some("public".into()),
        name: "t".into(),
    }
}

#[async_trait]
impl Connection for CatalogConn {
    async fn list_databases(&self) -> Result<Vec<String>, DriverError> {
        self.answer(vec!["db".into()])
    }
    async fn list_tables(&self) -> Result<Vec<TableInfo>, DriverError> {
        self.answer(vec![table()])
    }
    async fn list_views(&self) -> Result<Vec<TableInfo>, DriverError> {
        self.answer(vec![table()])
    }
    async fn list_objects(&self, _: CatalogObjectKind, _: Option<&str>) -> Result<Vec<CatalogObject>, DriverError> {
        self.answer(Vec::new())
    }
    async fn fetch_columns(&self, _: Option<&str>, _: &str) -> Result<Vec<ColumnInfo>, DriverError> {
        self.answer(Vec::new())
    }
    async fn fetch_rows(&self, _: Option<&str>, _: &str, _: u64, _: u64) -> Result<QueryResult, DriverError> {
        self.answer(empty_result())
    }
    async fn fetch_indexes(&self, _: Option<&str>, _: &str) -> Result<Vec<IndexInfo>, DriverError> {
        self.answer(Vec::new())
    }
    async fn fetch_foreign_keys(&self, _: Option<&str>, _: &str) -> Result<Vec<ForeignKeyInfo>, DriverError> {
        self.answer(Vec::new())
    }
    async fn fetch_enum_labels(&self, _: &str, _: &str) -> Result<Vec<String>, DriverError> {
        self.answer(vec!["a".into()])
    }
    async fn query(&self, _: &str) -> Result<QueryResult, DriverError> {
        self.answer(empty_result())
    }
    async fn query_params(&self, _: &str, _: &[Value]) -> Result<QueryResult, DriverError> {
        self.answer(empty_result())
    }
    async fn execute(&self, _: &str) -> Result<ExecResult, DriverError> {
        self.answer(ExecResult { rows_affected: 0 })
    }
    async fn execute_in_transaction_checked(
        &self,
        _: &[(String, Vec<Value>)],
        _: &[usize],
    ) -> Result<Vec<u64>, DriverError> {
        self.answer(Vec::new())
    }
    async fn execute_in_transaction_checked_controlled(
        &self,
        _: &[(String, Vec<Value>)],
        _: &[usize],
        _: &OperationControl,
    ) -> Result<Vec<u64>, DriverError> {
        self.answer(Vec::new())
    }
    async fn execute_params(&self, _: &str, _: &[Value]) -> Result<ExecResult, DriverError> {
        self.answer(ExecResult { rows_affected: 0 })
    }
    async fn execute_in_transaction(&self, _: &[(String, Vec<Value>)]) -> Result<Vec<u64>, DriverError> {
        self.answer(Vec::new())
    }
    async fn server_version(&self) -> Result<Option<String>, DriverError> {
        self.answer(Some("18.0".into()))
    }
    async fn begin(&self) -> Result<Box<dyn Transaction>, DriverError> {
        Ok(Box::new(FakeTx {
            calls: self.calls.clone(),
        }))
    }
    async fn ping(&self) -> Result<(), DriverError> {
        self.answer(())
    }
    async fn close(self: Box<Self>) -> Result<(), DriverError> {
        Ok(())
    }
}

fn catalog_guard(fail: bool) -> (PolicyGuard, Arc<AtomicUsize>, Arc<SequenceAuditSink>) {
    catalog_guard_with(fail, vec![])
}

fn catalog_guard_with(
    fail: bool,
    audit_failures: Vec<AuditRecordPhase>,
) -> (PolicyGuard, Arc<AtomicUsize>, Arc<SequenceAuditSink>) {
    let calls = Arc::new(AtomicUsize::new(0));
    let audit = Arc::new(SequenceAuditSink::new(audit_failures));
    let guard = PolicyGuard::new(
        Arc::new(CatalogConn {
            calls: calls.clone(),
            fail,
        }),
        context(
            Principal::human_gui(),
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        ),
    );
    (guard, calls, audit)
}

async fn run_every_read(guard: &PolicyGuard, control: Option<&OperationControl>) -> Vec<Result<(), DriverError>> {
    let schema = Some("public");
    let kind = CatalogObjectKind::ALL[0];
    macro_rules! read {
        ($plain:expr, $controlled:expr) => {
            match control {
                Some(control) => $controlled(control).await.map(|_| ()),
                None => $plain.await.map(|_| ()),
            }
        };
    }
    vec![
        guard.list_databases().await.map(|_| ()),
        read!(guard.list_tables(), |c| guard.list_tables_controlled(c)),
        read!(guard.list_views(), |c| guard.list_views_controlled(c)),
        read!(guard.list_objects(kind, schema), |c| guard
            .list_objects_controlled(kind, schema, c)),
        read!(guard.fetch_columns(schema, "t"), |c| guard
            .fetch_columns_controlled(schema, "t", c)),
        read!(guard.fetch_rows(schema, "t", 0, 10), |c| guard
            .fetch_rows_controlled(schema, "t", 0, 10, c)),
        read!(guard.fetch_indexes(schema, "t"), |c| guard
            .fetch_indexes_controlled(schema, "t", c)),
        read!(guard.fetch_foreign_keys(schema, "t"), |c| guard
            .fetch_foreign_keys_controlled(schema, "t", c)),
        read!(guard.fetch_enum_labels("public", "mood"), |c| guard
            .fetch_enum_labels_controlled("public", "mood", c)),
        guard.server_version().await.map(|_| ()),
        guard.ping().await,
    ]
}

#[tokio::test]
async fn every_guarded_read_reaches_the_driver_once_and_is_audited() {
    for controlled in [false, true] {
        let (guard, calls, audit) = catalog_guard(false);
        let control = OperationControl::with_timeout(Duration::from_secs(30));
        let outcomes = run_every_read(&guard, controlled.then_some(&control)).await;
        assert!(
            outcomes.iter().all(Result::is_ok),
            "controlled={controlled}: {outcomes:?}"
        );
        assert_eq!(calls.load(Ordering::SeqCst), outcomes.len(), "one driver call per read");
        let events = audit.events.lock().expect("events").len();
        assert!(
            events >= 8,
            "controlled={controlled}: {events} audit events for {} reads",
            outcomes.len()
        );
    }
}

#[tokio::test]
async fn a_cancelled_control_stops_every_controlled_read_before_it_reaches_the_driver() {
    let (guard, calls, _audit) = catalog_guard(false);
    let control = OperationControl::with_timeout(Duration::from_secs(30));
    control.cancellation_token().cancel();
    let outcomes = run_every_read(&guard, Some(&control)).await;
    let controlled_outcomes = &outcomes[1..outcomes.len() - 2];
    assert!(
        controlled_outcomes
            .iter()
            .all(|outcome| matches!(outcome, Err(DriverError::Cancelled))),
        "{controlled_outcomes:?}"
    );
    assert_eq!(
        calls.load(Ordering::SeqCst),
        3,
        "only list_databases, server_version and ping are not controlled"
    );
}

#[tokio::test]
async fn a_driver_failure_on_any_read_is_returned_unchanged_and_audited() {
    let (guard, calls, audit) = catalog_guard(true);
    let outcomes = run_every_read(&guard, None).await;
    assert!(
        outcomes
            .iter()
            .all(|outcome| matches!(outcome, Err(DriverError::Disconnected))),
        "{outcomes:?}"
    );
    assert_eq!(calls.load(Ordering::SeqCst), outcomes.len());
    assert!(!audit.events.lock().expect("events").is_empty());
}

fn control() -> OperationControl {
    OperationControl::with_timeout(Duration::from_secs(30))
}

#[tokio::test]
async fn every_read_statement_form_reaches_the_driver() {
    let (guard, calls, _audit) = catalog_guard(false);
    let control = control();
    let one = Value::Int(1);
    guard.query("SELECT 1").await.unwrap();
    guard.query_controlled("SELECT 1", &control).await.unwrap();
    guard
        .query_params("SELECT $1", std::slice::from_ref(&one))
        .await
        .unwrap();
    guard
        .query_params_controlled("SELECT $1", std::slice::from_ref(&one), &control)
        .await
        .unwrap();
    guard
        .query_result_sets_controlled("SELECT 1", &[], &control)
        .await
        .unwrap();
    guard
        .query_result_sets_controlled("SELECT $1", std::slice::from_ref(&one), &control)
        .await
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 6, "one driver call per read form");
}

#[tokio::test]
async fn every_write_statement_form_reaches_the_driver_and_is_audited() {
    let (guard, calls, audit) = catalog_guard(false);
    let control = control();
    let one = Value::Int(1);
    guard.execute("INSERT INTO t VALUES (1)").await.unwrap();
    guard
        .execute_controlled("INSERT INTO t VALUES (2)", &control)
        .await
        .unwrap();
    guard
        .execute_params("INSERT INTO t VALUES ($1)", std::slice::from_ref(&one))
        .await
        .unwrap();
    guard
        .execute_params_controlled("INSERT INTO t VALUES ($1)", std::slice::from_ref(&one), &control)
        .await
        .unwrap();
    guard.query("INSERT INTO t VALUES (3) RETURNING id").await.unwrap();
    guard
        .query_params("INSERT INTO t VALUES ($1) RETURNING id", std::slice::from_ref(&one))
        .await
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 6, "one driver call per write form");
    let events = audit.events.lock().expect("events");
    let intents = |class: AuditOperationClass| {
        events
            .iter()
            .filter(|event| event.phase == AuditRecordPhase::Intent && event.operation_class == class)
            .count()
    };
    assert_eq!(
        intents(AuditOperationClass::Mutation),
        6,
        "six writes, each with an intent record"
    );
    assert_eq!(events.len(), 12, "every write has an intent and an outcome record");
}

#[tokio::test]
async fn transaction_batches_run_through_the_guard_in_every_form() {
    let (guard, calls, audit) = catalog_guard(false);
    let control = control();
    let batch = vec![
        ("INSERT INTO t VALUES (1)".to_string(), Vec::new()),
        ("UPDATE t SET a = 1 WHERE id = 1".to_string(), Vec::new()),
    ];
    guard.execute_in_transaction(&batch).await.unwrap();
    guard.execute_in_transaction_controlled(&batch, &control).await.unwrap();
    guard.execute_in_transaction_checked(&batch, &[1]).await.unwrap();
    guard.execute_in_transaction_checked(&batch, &[]).await.unwrap();
    guard
        .execute_in_transaction_checked_controlled(&batch, &[1], &control)
        .await
        .unwrap();
    guard
        .execute_in_transaction_checked_controlled(&batch, &[], &control)
        .await
        .unwrap();
    assert!(calls.load(Ordering::SeqCst) >= 6);
    assert!(!audit.events.lock().expect("events").is_empty());
}

#[tokio::test]
async fn a_guarded_transaction_audits_each_statement_and_its_outcome() {
    let (guard, calls, audit) = catalog_guard(false);
    let control = control();
    let one = Value::Int(1);

    let mut tx = guard.begin().await.unwrap();
    tx.query("SELECT 1").await.unwrap();
    tx.query_controlled("SELECT 1", &control).await.unwrap();
    tx.query_params("SELECT $1", std::slice::from_ref(&one)).await.unwrap();
    tx.query_params_controlled("SELECT $1", std::slice::from_ref(&one), &control)
        .await
        .unwrap();
    tx.execute("INSERT INTO t VALUES (1)").await.unwrap();
    tx.execute_controlled("INSERT INTO t VALUES (2)", &control)
        .await
        .unwrap();
    tx.execute_params("INSERT INTO t VALUES ($1)", std::slice::from_ref(&one))
        .await
        .unwrap();
    tx.execute_params_controlled("INSERT INTO t VALUES ($1)", std::slice::from_ref(&one), &control)
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 8 + 100, "eight statements and a commit");

    let rolled_back = guard.begin().await.unwrap();
    rolled_back.rollback().await.unwrap();
    let rolled_back_controlled = guard.begin().await.unwrap();
    rolled_back_controlled.rollback_controlled(&control).await.unwrap();
    assert_eq!(
        calls.load(Ordering::SeqCst),
        8 + 100 + 2000,
        "both rollbacks reached the driver"
    );
    assert!(audit.events.lock().expect("events").len() >= 10);
}

#[tokio::test]
async fn beginning_a_transaction_does_not_grant_write_authority() {
    let cases = [
        (Principal::human_gui(), true),
        (
            Principal::Agent {
                token: "token".into(),
                client: None,
                model: None,
            },
            false,
        ),
    ];

    for (principal, read_only) in cases {
        let calls = Arc::new(AtomicUsize::new(0));
        let audit = Arc::new(SequenceAuditSink::new(vec![]));
        let mut guard_context = context(
            principal,
            Environment::Prod,
            PolicyConfig::default(),
            Arc::new(AutoApproveSink),
            audit.clone(),
            Arc::new(AuditState::new()),
        );
        guard_context.read_only = read_only;
        let guard = PolicyGuard::new(
            Arc::new(CatalogConn {
                calls: calls.clone(),
                fail: false,
            }),
            guard_context,
        );

        let mut transaction = guard.begin().await.expect("transaction setup is permitted");
        transaction.query("SELECT 1").await.expect("read is permitted");
        transaction
            .execute("INSERT INTO t VALUES (1)")
            .await
            .expect_err("transaction setup does not authorize a write");

        assert_eq!(calls.load(Ordering::SeqCst), 1, "only the read reaches the driver");
        let events = audit.events.lock().expect("events");
        assert_eq!(events.len(), 3, "begin has no standalone audit event");
        assert_eq!(
            events
                .iter()
                .filter(|event| event.operation_class == AuditOperationClass::Read)
                .count(),
            2,
            "the read has its intent and outcome records"
        );
        assert!(events.iter().any(|event| {
            event.operation_class == AuditOperationClass::Mutation
                && event.terminal_status == AuditTerminalStatus::Denied
        }));
    }
}

#[tokio::test]
async fn closing_the_guard_closes_the_connection_and_the_session_is_not_offered_by_a_plain_driver() {
    let (guard, _calls, _audit) = catalog_guard(false);
    guard.ping().await.unwrap();
    assert!(matches!(guard.open_session().await, Err(DriverError::Unsupported(_))));
    Box::new(guard).close().await.unwrap();
}

#[tokio::test]
async fn a_controlled_write_that_returns_rows_is_governed_like_a_plain_one() {
    let (guard, calls, audit) = catalog_guard(false);
    let control = control();
    let one = Value::Int(1);
    guard
        .query_controlled("INSERT INTO t VALUES (1) RETURNING id", &control)
        .await
        .unwrap();
    guard
        .query_params_controlled(
            "INSERT INTO t VALUES ($1) RETURNING id",
            std::slice::from_ref(&one),
            &control,
        )
        .await
        .unwrap();
    guard
        .query_result_sets_controlled("INSERT INTO t VALUES (1) RETURNING id", &[], &control)
        .await
        .unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 3);
    let mutations = audit
        .events
        .lock()
        .expect("events")
        .iter()
        .filter(|event| {
            event.phase == AuditRecordPhase::Intent && event.operation_class == AuditOperationClass::Mutation
        })
        .count();
    assert_eq!(mutations, 3);
}

#[tokio::test]
async fn a_rollback_is_denied_when_its_audit_intent_cannot_be_written() {
    for controlled in [false, true] {
        let (guard, calls, _audit) = catalog_guard_with(false, vec![AuditRecordPhase::Intent]);
        let tx = guard.begin().await.unwrap();
        let outcome = if controlled {
            tx.rollback_controlled(&control()).await
        } else {
            tx.rollback().await
        };
        assert!(
            matches!(&outcome, Err(DriverError::PolicyDenied(message)) if message.contains("audit intent")),
            "controlled={controlled}: {outcome:?}"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0, "the rollback never reached the driver");
    }
}

#[tokio::test]
async fn a_write_that_returns_rows_inside_a_guarded_transaction_is_audited_as_a_mutation() {
    let (guard, calls, audit) = catalog_guard(false);
    let mut tx = guard.begin().await.unwrap();
    tx.query("INSERT INTO t VALUES (1) RETURNING id").await.unwrap();
    tx.query_params("INSERT INTO t VALUES ($1) RETURNING id", &[Value::Int(1)])
        .await
        .unwrap();
    tx.commit().await.unwrap();
    assert_eq!(calls.load(Ordering::SeqCst), 2 + 100);
    let mutations = audit
        .events
        .lock()
        .expect("events")
        .iter()
        .filter(|event| {
            event.phase == AuditRecordPhase::Intent && event.operation_class == AuditOperationClass::Mutation
        })
        .count();
    assert_eq!(mutations, 2);
}
