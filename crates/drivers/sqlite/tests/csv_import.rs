#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
//! End to end: a CSV file reaching a real SQLite database through the
//! same policy guard the GUI uses. Nothing here talks to the driver
//! without the guard, and every import ends in one terminal audit record.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use drivers_sqlite::SqliteDriver;
use tablepro_core::import::{CsvImportOptions, ImportTarget, InsertPlan, build_insert_plan, infer_columns, read_csv};
use tablepro_core::sql_ddl::build_create_table;
use tablepro_core::{
    ColumnInfo, ConnectOptions, Connection, DatabaseDriver, DriverError, Environment, OperationControl, Value,
};
use tablepro_policy::{
    AuditError, AuditEvent, AuditOperationClass, AuditSink, AuditState, AuditTerminalStatus, AutoApproveSink,
    BulkBatch, BulkInsertEnd, BulkInsertRequest, BulkInsertScope, GuardContext, PolicyConfig, PolicyGuard, Principal,
};
use tempfile::TempDir;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

const BATCH_ROWS: usize = 2;

#[derive(Default)]
struct RecordingAudit {
    events: Mutex<Vec<AuditEvent>>,
}

#[async_trait]
impl AuditSink for RecordingAudit {
    async fn record(&self, event: AuditEvent) -> Result<(), AuditError> {
        self.events.lock().expect("audit lock").push(event);
        Ok(())
    }
}

impl RecordingAudit {
    /// Only the import's own records. The CREATE is DDL and the
    /// verification queries are reads; neither belongs to the one
    /// governed operation an import is audited as.
    fn import_outcomes(&self) -> Vec<(AuditTerminalStatus, Option<u64>)> {
        self.events
            .lock()
            .expect("audit lock")
            .iter()
            .filter(|event| {
                event.operation_class == AuditOperationClass::Mutation
                    && event.terminal_status != AuditTerminalStatus::Pending
            })
            .map(|event| (event.terminal_status, event.rows_affected))
            .collect()
    }
}

struct Fixture {
    guard: PolicyGuard,
    audit: Arc<RecordingAudit>,
    _directory: TempDir,
}

async fn fixture() -> Fixture {
    let directory = TempDir::new().expect("temp dir");
    let path = directory.path().join("import.db");
    let inner: Arc<dyn Connection> = SqliteDriver
        .connect(ConnectOptions {
            database: path.to_string_lossy().to_string(),
            ..Default::default()
        })
        .await
        .expect("connect to the sqlite file")
        .into();
    let audit = Arc::new(RecordingAudit::default());
    let context = GuardContext {
        connection_id: Uuid::new_v4(),
        connection_name: "import test".into(),
        driver_id: "sqlite".into(),
        environment: Environment::Local,
        read_only: false,
        principal: Principal::human_gui(),
        policy: Arc::new(PolicyConfig::default()),
        approval: Arc::new(AutoApproveSink),
        audit: audit.clone(),
        audit_state: Arc::new(AuditState::new()),
    };
    Fixture {
        guard: PolicyGuard::new(inner, context),
        audit,
        _directory: directory,
    }
}

fn control() -> OperationControl {
    OperationControl::with_timeout(Duration::from_secs(30))
}

fn control_with(token: CancellationToken) -> OperationControl {
    OperationControl::new(token, Some(tokio::time::Instant::now() + Duration::from_secs(30)))
}

fn plan_for(table: &str, columns: &[ColumnInfo], csv: &[u8]) -> InsertPlan {
    let options = CsvImportOptions::default();
    let sheet = read_csv(csv, &options, None).expect("read the file");
    let mapping: Vec<Option<usize>> = columns
        .iter()
        .map(|column| sheet.headers.iter().position(|header| header == &column.name))
        .collect();
    let target = ImportTarget {
        driver_id: "sqlite",
        schema: None,
        table,
        columns,
        mapping: &mapping,
    };
    build_insert_plan(&target, &sheet, &options).expect("plan")
}

async fn begin(guard: &PolicyGuard, table: &str, plan: &InsertPlan) -> BulkInsertScope {
    guard
        .begin_bulk_insert(BulkInsertRequest {
            schema: None,
            table: table.to_owned(),
            statement: plan.statement.clone(),
            row_budget: plan.row_count(),
        })
        .await
        .expect("an approved scope")
}

async fn run_batches(
    guard: &PolicyGuard,
    scope: &mut BulkInsertScope,
    table: &str,
    plan: &InsertPlan,
    token: Option<&CancellationToken>,
) -> Result<(), DriverError> {
    for rows in plan.batches(BATCH_ROWS) {
        let control = token.map_or_else(control, |token| control_with(token.clone()));
        let batch = BulkBatch {
            schema: None,
            table,
            statement: &plan.statement,
            rows,
        };
        guard.execute_bulk_batch(scope, batch, &control).await?;
        if let Some(token) = token {
            token.cancel();
        }
    }
    Ok(())
}

async fn rows_in(guard: &PolicyGuard, sql: &str) -> Vec<Vec<Value>> {
    guard.query_controlled(sql, &control()).await.expect("query").rows
}

#[tokio::test]
async fn value_contract_csv_binary_export_import_keeps_null_empty_and_every_byte() {
    let fixture = fixture().await;
    fixture
        .guard
        .execute_controlled(
            "CREATE TABLE payloads (id INTEGER PRIMARY KEY, payload BLOB)",
            &control(),
        )
        .await
        .expect("create");
    let columns = vec![column("id", "INTEGER"), column("payload", "BLOB")];
    let expected = vec![
        vec![Value::Int(1), Value::Null],
        vec![Value::Int(2), Value::Bytes(vec![])],
        vec![Value::Int(3), Value::Bytes((0..=255).collect())],
    ];
    let csv = tablepro_core::export::render_csv(&columns, &expected, &tablepro_core::export::CsvOptions::default());
    let plan = plan_for("payloads", &columns, csv.as_bytes());
    assert_eq!(plan.rows, expected);
    let mut scope = begin(&fixture.guard, "payloads", &plan).await;
    run_batches(&fixture.guard, &mut scope, "payloads", &plan, None)
        .await
        .expect("import");
    assert_eq!(
        fixture
            .guard
            .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
            .await
            .unwrap(),
        3
    );
    assert_eq!(
        rows_in(&fixture.guard, "SELECT id, payload FROM payloads ORDER BY id").await,
        expected
    );
    assert_eq!(
        rows_in(
            &fixture.guard,
            "SELECT typeof(payload), length(payload) FROM payloads ORDER BY id"
        )
        .await,
        vec![
            vec![Value::Text("null".into()), Value::Null],
            vec![Value::Text("blob".into()), Value::Int(0)],
            vec![Value::Text("blob".into()), Value::Int(256)],
        ],
    );
    assert_eq!(
        fixture.audit.import_outcomes(),
        vec![(AuditTerminalStatus::Succeeded, Some(3))]
    );
}

#[tokio::test]
async fn a_csv_file_creates_the_table_it_is_loaded_into_and_fills_it() {
    let fixture = fixture().await;
    let csv = b"id,name,joined\n1,ada,2024-05-06\n2,grace,2024-05-07\n3,alan,2024-05-08\n";
    let options = CsvImportOptions::default();
    let sheet = read_csv(csv, &options, None).expect("read");
    let drafts = infer_columns(&sheet, &options, "sqlite");
    let create = build_create_table("sqlite", None, "people", &drafts, &[], &[]).expect("create sql");

    fixture
        .guard
        .execute_controlled(&create[0], &control())
        .await
        .expect("the create runs as its own governed statement");

    let columns: Vec<ColumnInfo> = drafts
        .iter()
        .map(|draft| ColumnInfo {
            name: draft.name.clone(),
            data_type: draft.data_type.clone(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        })
        .collect();
    let plan = plan_for("people", &columns, csv);
    let mut scope = begin(&fixture.guard, "people", &plan).await;
    run_batches(&fixture.guard, &mut scope, "people", &plan, None)
        .await
        .expect("every batch");
    let committed = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    assert_eq!(committed, 3);
    assert_eq!(
        rows_in(&fixture.guard, "SELECT id, name FROM people ORDER BY id").await,
        vec![
            vec![Value::Int(1), Value::Text("ada".into())],
            vec![Value::Int(2), Value::Text("grace".into())],
            vec![Value::Int(3), Value::Text("alan".into())],
        ]
    );
    assert_eq!(
        fixture.audit.import_outcomes(),
        vec![(AuditTerminalStatus::Succeeded, Some(3))]
    );
}

#[tokio::test]
async fn a_csv_file_loads_into_a_table_that_is_already_there() {
    let fixture = fixture().await;
    fixture
        .guard
        .execute_controlled(
            "CREATE TABLE people (id INTEGER, name TEXT, note TEXT DEFAULT 'none')",
            &control(),
        )
        .await
        .expect("create");
    let columns = vec![
        column("id", "INTEGER"),
        column("name", "TEXT"),
        ColumnInfo {
            default_value: Some("'none'".into()),
            ..column("note", "TEXT")
        },
    ];
    let plan = plan_for("people", &columns, b"id,name\n1,ada\n2,grace\n3,alan\n");
    let mut scope = begin(&fixture.guard, "people", &plan).await;

    run_batches(&fixture.guard, &mut scope, "people", &plan, None)
        .await
        .expect("every batch");
    let committed = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    assert_eq!(committed, 3);
    // `note` was never mapped, so the statement leaves it out and the
    // column's own default is what lands in the table.
    assert_eq!(
        rows_in(&fixture.guard, "SELECT note FROM people ORDER BY id").await,
        vec![
            vec![Value::Text("none".into())],
            vec![Value::Text("none".into())],
            vec![Value::Text("none".into())],
        ]
    );
    assert_eq!(
        fixture.audit.import_outcomes(),
        vec![(AuditTerminalStatus::Succeeded, Some(3))]
    );
}

#[tokio::test]
async fn csv_import_preserves_text_in_sqlite_integer_real_and_numeric_affinities() {
    let fixture = fixture().await;
    fixture
        .guard
        .execute_controlled(
            "CREATE TABLE flexible (integer_value INTEGER, real_value REAL, numeric_value NUMERIC)",
            &control(),
        )
        .await
        .expect("create");
    let columns = vec![
        column("integer_value", "INTEGER"),
        column("real_value", "REAL"),
        column("numeric_value", "NUMERIC"),
    ];
    let plan = plan_for(
        "flexible",
        &columns,
        b"integer_value,real_value,numeric_value\nnot numeric,not numeric,not numeric\n42.50,42.50,42.50\n42,42,42\n",
    );
    let mut scope = begin(&fixture.guard, "flexible", &plan).await;
    run_batches(&fixture.guard, &mut scope, "flexible", &plan, None)
        .await
        .expect("SQLite numeric affinities accept legal text storage values");
    let committed = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Completed)
        .await
        .expect("finish");

    assert_eq!(committed, 3);
    assert_eq!(
        rows_in(
            &fixture.guard,
            "SELECT typeof(integer_value), integer_value, typeof(real_value), real_value, typeof(numeric_value), numeric_value FROM flexible ORDER BY rowid"
        )
        .await,
        vec![
            vec![
                Value::Text("text".into()), Value::Text("not numeric".into()),
                Value::Text("text".into()), Value::Text("not numeric".into()),
                Value::Text("text".into()), Value::Text("not numeric".into()),
            ],
            vec![
                Value::Text("real".into()), Value::Float(42.5),
                Value::Text("real".into()), Value::Float(42.5),
                Value::Text("real".into()), Value::Float(42.5),
            ],
            vec![
                Value::Text("integer".into()), Value::Int(42),
                Value::Text("real".into()), Value::Float(42.0),
                Value::Text("integer".into()), Value::Int(42),
            ],
        ]
    );
}

#[tokio::test]
async fn a_row_the_database_refuses_stops_the_import_and_keeps_what_already_committed() {
    let fixture = fixture().await;
    fixture
        .guard
        .execute_controlled("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)", &control())
        .await
        .expect("create");
    let columns = vec![column("id", "INTEGER"), column("name", "TEXT")];
    let plan = plan_for("people", &columns, b"id,name\n1,ada\n2,grace\n3,alan\n3,alan again\n");
    let mut scope = begin(&fixture.guard, "people", &plan).await;

    let failure = run_batches(&fixture.guard, &mut scope, "people", &plan, None)
        .await
        .expect_err("the duplicate key stops the import");
    let committed = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Failed(&failure))
        .await
        .expect("finish");

    assert_eq!(committed, 2);
    assert_eq!(
        rows_in(&fixture.guard, "SELECT count(*) FROM people").await,
        vec![vec![Value::Int(2)]]
    );
    assert_eq!(
        fixture.audit.import_outcomes(),
        vec![(AuditTerminalStatus::Failed, Some(2))]
    );
}

#[tokio::test]
async fn a_cancelled_import_leaves_the_batches_that_already_committed_and_no_more() {
    let fixture = fixture().await;
    fixture
        .guard
        .execute_controlled("CREATE TABLE people (id INTEGER, name TEXT)", &control())
        .await
        .expect("create");
    let columns = vec![column("id", "INTEGER"), column("name", "TEXT")];
    let plan = plan_for("people", &columns, b"id,name\n1,ada\n2,grace\n3,alan\n4,edsger\n");
    let mut scope = begin(&fixture.guard, "people", &plan).await;
    let token = CancellationToken::new();

    let stop = run_batches(&fixture.guard, &mut scope, "people", &plan, Some(&token))
        .await
        .expect_err("the second batch is cancelled before it is dispatched");
    let committed = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Cancelled)
        .await
        .expect("finish");

    assert!(matches!(stop, DriverError::Cancelled));
    assert_eq!(committed, 2);
    assert_eq!(
        rows_in(&fixture.guard, "SELECT count(*) FROM people").await,
        vec![vec![Value::Int(2)]]
    );
    assert_eq!(
        fixture.audit.import_outcomes(),
        vec![(AuditTerminalStatus::Cancelled, Some(2))]
    );
}

#[tokio::test]
async fn a_scope_cannot_be_spent_on_another_table_of_the_same_database() {
    let fixture = fixture().await;
    for table in ["people", "salaries"] {
        fixture
            .guard
            .execute_controlled(&format!("CREATE TABLE {table} (id INTEGER, name TEXT)"), &control())
            .await
            .expect("create");
    }
    let columns = vec![column("id", "INTEGER"), column("name", "TEXT")];
    let plan = plan_for("people", &columns, b"id,name\n1,ada\n");
    let mut scope = begin(&fixture.guard, "people", &plan).await;

    let denied = fixture
        .guard
        .execute_bulk_batch(
            &mut scope,
            BulkBatch {
                schema: None,
                table: "salaries",
                statement: &plan.statement,
                rows: &plan.rows,
            },
            &control(),
        )
        .await
        .expect_err("another table is not covered by this approval");

    assert!(matches!(denied, DriverError::PolicyDenied(_)));
    let _ = fixture
        .guard
        .finish_bulk_insert(&mut scope, BulkInsertEnd::Cancelled)
        .await;
    assert_eq!(
        rows_in(&fixture.guard, "SELECT count(*) FROM salaries").await,
        vec![vec![Value::Int(0)]]
    );
}

fn column(name: &str, data_type: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        data_type: data_type.to_owned(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        default_value: None,
        is_generated: false,
        comment: None,
        collation: None,
        enum_type: None,
        domain_type: None,
    }
}
