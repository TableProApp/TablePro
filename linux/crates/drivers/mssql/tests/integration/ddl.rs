//! Structure changes the SQL Server dialect plans, run against a real
//! server.

use tablepro_core::ddl::{DdlPlan, DraftColumn, DraftType, TableDefinition, TableDraft, diff_table};
use tablepro_core::value::Value;
use tablepro_core::{Connection, DriverError, WriteKind};

use crate::support::{CALL, apply, connect, dbo, scalar, setup, start, within};

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&dbo("kept"), within(CALL))
        .await
        .expect("the definition")
}

/// The plan the structure tab would save for the edit, against `before`.
fn plan(connection: &dyn Connection, before: &TableDefinition, edit: impl FnOnce(&mut TableDraft)) -> DdlPlan {
    let mut draft = TableDraft::from_definition(before);
    edit(&mut draft);
    connection
        .dialect()
        .ddl()
        .expect("SQL Server plans its DDL")
        .plan_alter_table(before, &diff_table(before, &draft))
        .expect("the change plans")
}

async fn run(connection: &dyn Connection, plan: DdlPlan) -> Result<(), DriverError> {
    connection
        .write_batch(&plan.into_write_batch(dbo("kept")), within(CALL))
        .await
        .map(|_| ())
}

/// Plan the edit against the table as read, run it, and read it again.
async fn change(connection: &dyn Connection, edit: impl Fn(&mut DraftColumn)) -> TableDefinition {
    let before = read(connection).await;
    let plan = plan(connection, &before, |draft| draft.columns.iter_mut().for_each(edit));
    run(connection, plan).await.expect("the change runs");
    read(connection).await
}

fn names(definition: &TableDefinition) -> Vec<&str> {
    definition.columns.iter().map(|column| column.name()).collect()
}

fn type_of(definition: &TableDefinition, column: &str) -> String {
    definition
        .column(column)
        .map(|column| column.info.column_type.name.clone())
        .unwrap_or_default()
}

async fn text(connection: &dyn Connection, sql: &str) -> String {
    match scalar(connection, sql).await {
        Value::Text(text) => text,
        other => tablepro_core::export::value_to_text(&other).unwrap_or_default(),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn nullability_change_keeps_column_collation() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (id int PRIMARY KEY, code varchar(20) COLLATE Latin1_General_BIN NULL, \
           name nvarchar(40) COLLATE Latin1_General_100_CS_AS NOT NULL, weight int SPARSE NULL, \
           email varchar(50) MASKED WITH (FUNCTION = 'partial(1,\"X''s\",2)') NULL)",
        ],
    )
    .await;
    let before = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&before);
    for column in &mut draft.columns {
        match column.name.as_str() {
            "code" => column.nullable = false,
            "name" => column.column_type = DraftType::Typed("nvarchar(80)".to_owned()),
            "weight" => column.column_type = DraftType::Typed("bigint".to_owned()),
            "email" => column.column_type = DraftType::Typed("varchar(80)".to_owned()),
            _ => {}
        }
    }
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("SQL Server plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");

    connection
        .write_batch(&plan.into_write_batch(dbo("kept")), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection.as_ref()).await;

    assert_eq!(before.columns.len(), after.columns.len());
    for old in &before.columns {
        let new = after.column(old.name()).expect("the column");
        assert_eq!(new.attributes, old.attributes, "{}", old.name());
    }
    let column = |name: &str| after.column(name).expect("the column");
    let collation = |name: &str| {
        column(name)
            .attributes
            .collation
            .as_ref()
            .map(|collation| collation.name.clone())
    };
    assert!(!column("code").info.nullable);
    assert_eq!(collation("code").as_deref(), Some("Latin1_General_BIN"));
    assert!(!column("name").info.nullable);
    assert_eq!(collation("name").as_deref(), Some("Latin1_General_100_CS_AS"));
    assert_eq!(column("name").info.column_type.name, "nvarchar(80)");
    assert!(column("weight").attributes.sparse);
    assert_eq!(column("weight").info.column_type.name, "bigint");
    let mask = |definition: &TableDefinition| {
        definition
            .column("email")
            .and_then(|column| column.attributes.masking_function.clone())
    };
    assert!(mask(&before).is_some_and(|function| function.starts_with("partial(")));
    assert_eq!(mask(&after), mask(&before));
    assert_eq!(column("email").info.column_type.name, "varchar(80)");
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn rename_and_retype_column_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (id int PRIMARY KEY, code varchar(10) NULL, qty smallint NULL)",
            "INSERT INTO dbo.kept VALUES (1, 'a', 5)",
        ],
    )
    .await;

    let after = change(connection.as_ref(), |column| match column.name.as_str() {
        "code" => {
            column.name = "label".to_owned();
            column.column_type = DraftType::Typed("nvarchar(40)".to_owned());
        }
        "qty" => {
            column.name = "amount".to_owned();
            column.column_type = DraftType::Typed("bigint".to_owned());
        }
        _ => {}
    })
    .await;

    assert_eq!(names(&after), ["id", "label", "amount"]);
    assert_eq!(type_of(&after, "label"), "nvarchar(40)");
    assert_eq!(type_of(&after, "amount"), "bigint");
    assert_eq!(
        text(
            connection.as_ref(),
            "SELECT label + N'|' + CAST(amount AS nvarchar(20)) FROM dbo.kept"
        )
        .await,
        "a|5"
    );
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn swap_column_names_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (id int PRIMARY KEY, a nvarchar(10) NULL, b int NULL)",
            "INSERT INTO dbo.kept VALUES (1, N'x', 2)",
        ],
    )
    .await;

    let after = change(connection.as_ref(), |column| {
        column.name = match column.name.as_str() {
            "a" => "B",
            "b" => "A",
            other => other,
        }
        .to_owned();
    })
    .await;

    assert_eq!(names(&after), ["id", "B", "A"]);
    assert_eq!(type_of(&after, "B"), "nvarchar(10)");
    assert_eq!(type_of(&after, "A"), "int");
    assert_eq!(
        text(
            connection.as_ref(),
            "SELECT B + N'|' + CAST(A AS nvarchar(20)) FROM dbo.kept"
        )
        .await,
        "x|2"
    );
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn change_primary_key_to_composite_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (order_id int NOT NULL CONSTRAINT PK_kept PRIMARY KEY, line int NULL, sku \
             nvarchar(10) COLLATE Latin1_General_BIN NULL)",
            "INSERT INTO dbo.kept VALUES (1, 1, N'a'), (2, 1, N'b')",
        ],
    )
    .await;

    let after = change(connection.as_ref(), |column| {
        if column.name == "line" {
            column.primary_key = true;
            column.nullable = false;
        }
    })
    .await;

    let key = after.primary_key.clone().expect("a primary key");
    assert_eq!(key.name.as_deref(), Some("PK_kept"));
    assert_eq!(key.columns, ["order_id", "line"]);
    assert!(!after.column("line").expect("line").info.nullable);
    apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO dbo.kept VALUES (1, 2, N'c')"],
    )
    .await
    .expect("a second line of order 1");
    let repeated = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO dbo.kept VALUES (1, 1, N'd')"],
    )
    .await;
    assert!(repeated.is_err(), "the key does not hold the line");
    connection.close().await.expect("a close");
}

/// sp_rename splits its first argument on periods outside brackets, so
/// each part goes in brackets with its `]` doubled.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn rename_column_with_period_and_bracket_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.kept (id int PRIMARY KEY, [a.b]]c] int NULL)"],
    )
    .await;

    let renamed = change(connection.as_ref(), |column| {
        if column.name == "a.b]c" {
            column.name = "d.e]f".to_owned();
        }
    })
    .await;

    assert_eq!(names(&renamed), ["id", "d.e]f"]);
    connection.close().await.expect("a close");
}
