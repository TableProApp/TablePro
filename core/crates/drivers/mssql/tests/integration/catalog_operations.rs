//! Emptying a table and making and dropping schemas and databases, as
//! the sidebar plans them, run against a real server.

use std::sync::Arc;
use std::time::Duration;

use tablepro_core::ddl::{
    self as catalog, DatabaseDraft, DdlPlan, DropDatabaseOptions, DropSchemaOptions, SchemaDraft, TruncateTableOptions,
};
use tablepro_core::{ConnectTarget, Connection, DriverError, TableRef, Value, WorkspaceSettings};
use tablepro_test_fixtures::MssqlFixture;
use tokio::time::Instant;

use crate::support::{CALL, connect, dbo, dial, fixture_options, require, rows, scalar, setup, start, within};

async fn run(connection: &dyn Connection, plan: DdlPlan, table: TableRef) -> Result<(), DriverError> {
    connection
        .write_batch(&plan.into_write_batch(table), within(CALL))
        .await
        .map(|_| ())
}

/// The table a schema or database batch carries: its name, and no table.
fn database(name: &str) -> TableRef {
    TableRef::new(Some(name.to_owned()), "")
}

async fn database_names(connection: &dyn Connection) -> Vec<String> {
    connection
        .list_databases(within(CALL))
        .await
        .expect("the databases")
        .into_iter()
        .map(|database| database.name)
        .collect()
}

async fn schema_names(connection: &dyn Connection) -> Vec<String> {
    connection
        .list_schemas(within(CALL))
        .await
        .expect("the schemas")
        .into_iter()
        .map(|schema| schema.name)
        .collect()
}

/// A connection whose login names `database`.
async fn dial_into(fixture: &MssqlFixture, database: &str) -> Result<Arc<dyn Connection>, DriverError> {
    let mut options = fixture_options(fixture, require(), WorkspaceSettings::workspace(false));
    if let ConnectTarget::Network(target) = &mut options.target {
        target.database = Some(database.to_owned());
    }
    dial(options).await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_truncate_empties_the_table_and_starts_its_identity_again() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.kept (id int IDENTITY(1, 1) PRIMARY KEY, name nvarchar(20))",
            "INSERT INTO dbo.kept (name) VALUES (N'a'), (N'b')",
        ],
    )
    .await;
    let dialect = connection.dialect();
    let plan =
        catalog::plan_truncate_table(dialect.as_ref(), &dbo("kept"), &TruncateTableOptions::default()).expect("a plan");

    run(connection.as_ref(), plan, dbo("kept")).await.expect("the truncate");
    setup(connection.as_ref(), &["INSERT INTO dbo.kept (name) VALUES (N'c')"]).await;

    assert_eq!(
        rows(connection.as_ref(), "SELECT id, name FROM dbo.kept").await,
        [[Value::Int(1), Value::Text("c".to_owned())]]
    );
}

/// SQL Server refuses by the key's definition, so an empty child table
/// still holds its parent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_table_another_tables_key_points_at_is_not_truncated() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.parent (id int PRIMARY KEY)",
            "CREATE TABLE dbo.child (id int PRIMARY KEY, parent_id int REFERENCES dbo.parent (id))",
            "INSERT INTO dbo.parent (id) VALUES (1)",
        ],
    )
    .await;
    let dialect = connection.dialect();
    let plan = catalog::plan_truncate_table(dialect.as_ref(), &dbo("parent"), &TruncateTableOptions::default())
        .expect("a plan");

    let refused = run(connection.as_ref(), plan, dbo("parent")).await;

    assert!(matches!(refused, Err(DriverError::RolledBack { .. })), "{refused:?}");
    assert_eq!(
        scalar(connection.as_ref(), "SELECT COUNT(*) FROM dbo.parent").await,
        Value::Int(1)
    );
}

/// CREATE SCHEMA has to start its batch, which sp_executesql gives it
/// inside the write's transaction.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_schema_is_created_with_its_owner_and_dropped_once_empty() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let dialect = connection.dialect();
    let draft = SchemaDraft {
        name: "sales".to_owned(),
        owner: Some("dbo".to_owned()),
    };
    let created = catalog::plan_create_schema(dialect.as_ref(), &draft).expect("a plan");
    let drop_plan =
        || catalog::plan_drop_schema(dialect.as_ref(), "sales", DropSchemaOptions::default()).expect("a plan");

    run(connection.as_ref(), created, database("sales"))
        .await
        .expect("the schema is created");
    setup(connection.as_ref(), &["CREATE TABLE sales.orders (id int)"]).await;
    let refused = run(connection.as_ref(), drop_plan(), database("sales")).await;
    setup(connection.as_ref(), &["DROP TABLE sales.orders"]).await;
    let owner = scalar(
        connection.as_ref(),
        "SELECT USER_NAME(principal_id) FROM sys.schemas WHERE name = N'sales'",
    )
    .await;
    let listed = schema_names(connection.as_ref()).await;
    run(connection.as_ref(), drop_plan(), database("sales"))
        .await
        .expect("the schema is dropped");

    assert!(matches!(refused, Err(DriverError::RolledBack { .. })), "{refused:?}");
    assert_eq!(owner, Value::Text("dbo".to_owned()));
    assert!(listed.iter().any(|name| name == "sales"), "{listed:?}");
    let after = schema_names(connection.as_ref()).await;
    assert!(!after.iter().any(|name| name == "sales"), "{after:?}");
}

/// The owners New Schema offers are the connected database's users and
/// roles a schema can belong to, and the one left out is the session's
/// own user, which the fixture's login maps to dbo.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn the_choices_list_collations_and_the_owners_a_schema_can_have() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &["CREATE ROLE reporting"]).await;

    let choices = connection
        .fetch_database_choices(within(CALL))
        .await
        .expect("the choices");

    let collation = choices.defaults.collation.clone().expect("the server's collation");
    assert!(choices.collations.contains(&collation), "{collation}");
    assert!(
        choices.owners.iter().any(|owner| owner == "dbo"),
        "{:?}",
        choices.owners
    );
    assert!(
        choices.owners.iter().any(|owner| owner == "reporting"),
        "{:?}",
        choices.owners
    );
    for kept in [
        "public",
        "guest",
        "sys",
        "INFORMATION_SCHEMA",
        "db_owner",
        "db_datareader",
    ] {
        assert!(!choices.owners.iter().any(|owner| owner == kept), "{kept}");
    }
    assert_eq!(choices.defaults.owner.as_deref(), Some("dbo"));
}

/// Sessions still in `database`.
async fn sessions_in(connection: &dyn Connection, database: &str) -> u64 {
    scalar(
        connection,
        &format!("SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE database_id = DB_ID(N'{database}')"),
    )
    .await
    .as_exact_u64()
    .expect("a count")
}

/// SQL Server refuses CREATE and DROP DATABASE inside a transaction, and
/// a drop while another session is in the database.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_database_is_created_and_dropped_once_no_session_is_in_it() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let dialect = connection.dialect();
    let mut draft = DatabaseDraft::named("tablepro_made");
    draft.collation = Some("Latin1_General_100_CI_AS".to_owned());
    let created = catalog::plan_create_database(dialect.as_ref(), &draft).expect("a plan");
    let drop_plan = || {
        catalog::plan_drop_database(dialect.as_ref(), "tablepro_made", &DropDatabaseOptions::default()).expect("a plan")
    };

    run(connection.as_ref(), created, database("tablepro_made"))
        .await
        .expect("the database is created");
    let inside = dial_into(&fixture, "tablepro_made")
        .await
        .expect("a connection in the new database");
    assert_eq!(
        scalar(inside.as_ref(), "SELECT DB_NAME()").await,
        Value::Text("tablepro_made".to_owned())
    );
    let refused = run(connection.as_ref(), drop_plan(), database("tablepro_made")).await;
    let collation = scalar(
        connection.as_ref(),
        "SELECT collation_name FROM sys.databases WHERE name = N'tablepro_made'",
    )
    .await;
    inside.close().await.expect("the connection closes");
    let until = Instant::now() + Duration::from_secs(10);
    while sessions_in(connection.as_ref(), "tablepro_made").await > 0 && Instant::now() < until {
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    run(connection.as_ref(), drop_plan(), database("tablepro_made"))
        .await
        .expect("the drop");

    assert!(matches!(refused, Err(DriverError::RolledBack { .. })), "{refused:?}");
    assert_eq!(collation, Value::Text("Latin1_General_100_CI_AS".to_owned()));
    let after = database_names(connection.as_ref()).await;
    assert!(!after.iter().any(|name| name == "tablepro_made"), "{after:?}");
}

/// Error 4060 also answers a database that is offline or that the login
/// may not open, so the refusal keeps the server's own words rather
/// than claiming the database is gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_login_to_a_database_the_server_lacks_is_refused_in_its_words() {
    let fixture = start().await;

    let refused = dial_into(&fixture, "tablepro_gone").await;

    assert!(
        matches!(
            &refused,
            Err(DriverError::Server(_) | DriverError::Auth { diagnostics: Some(_) })
        ),
        "{:?}",
        refused.as_ref().err()
    );
}
