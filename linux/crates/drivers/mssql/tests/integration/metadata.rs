//! The catalogue as browse and the structure tab read it.

use tablepro_core::column::{ColumnDefault, ColumnKind, ReadForm, TextLength};
use tablepro_core::ddl::{DdlDialect, IdentityStyle, TableDraft, diff_table};
use tablepro_core::dialect::{BindTarget, LikeForm};
use tablepro_core::meta::{ObjectInfo, ObjectKind, ObjectScope, RowIdentity, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{DriverError, RowLimit, UnsupportedFeature, Value};
use tablepro_driver_mssql::MssqlDialect;

use crate::support::{CALL, columns, connect, dbo, rows, scalar, setup, start, statement, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn catalog_classifies_money_alias_hierarchyid() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TYPE dbo.Phone FROM nvarchar(20) NOT NULL",
            "CREATE TABLE dbo.mixed (id int PRIMARY KEY, price money, phone dbo.Phone, node hierarchyid, \
             spot geography, v sql_variant, stamp rowversion)",
        ],
    )
    .await;

    let columns = columns(connection.as_ref(), &dbo("mixed")).await;
    let kind = |name: &str| {
        columns
            .iter()
            .find(|column| column.name == name)
            .map(|column| (column.column_type.kind.clone(), column.column_type.read_form))
            .expect("the column")
    };

    assert_eq!(
        kind("price"),
        (ColumnKind::Money { scale: Some(4) }, ReadForm::ServerNumeric)
    );
    assert_eq!(
        kind("phone"),
        (
            ColumnKind::Text {
                length: TextLength::Varying(20)
            },
            ReadForm::Native
        )
    );
    assert_eq!(kind("node"), (ColumnKind::Other, ReadForm::ServerText));
    assert_eq!(kind("spot"), (ColumnKind::Spatial, ReadForm::ServerText));
    assert_eq!(kind("v"), (ColumnKind::Variant, ReadForm::Native));
    assert!(
        columns
            .iter()
            .any(|column| column.name == "stamp" && column.is_generated)
    );
    assert_eq!(
        columns
            .iter()
            .find(|column| column.name == "id")
            .map(|column| column.primary_key),
        Some(true)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn lists_objects_and_names_rows_by_key() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.keyed (tenant int NOT NULL, id int NOT NULL, CONSTRAINT PK_keyed PRIMARY KEY (tenant, id))",
            "CREATE TABLE dbo.heap (v int)",
            "CREATE VIEW dbo.keyed_view AS SELECT tenant, id FROM dbo.keyed",
        ],
    )
    .await;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");
    let identity = connection
        .row_identity(&dbo("keyed"), within(CALL))
        .await
        .expect("an identity");
    let heap = connection
        .row_identity(&dbo("heap"), within(CALL))
        .await
        .expect("an identity");

    assert!(
        objects
            .iter()
            .any(|object| object.name == "keyed" && object.kind == ObjectKind::Table)
    );
    assert!(
        objects
            .iter()
            .any(|object| object.name == "keyed_view" && object.kind == ObjectKind::View)
    );
    assert_eq!(
        identity,
        RowIdentity::UniqueKey {
            columns: vec!["tenant".to_owned(), "id".to_owned()]
        }
    );
    assert_eq!(heap, RowIdentity::Unordered);
    let schemas = connection.list_schemas(within(CALL)).await.expect("the schemas");
    assert!(schemas.iter().any(|schema| schema.name == "dbo" && schema.is_default));
    assert!(schemas.iter().any(|schema| schema.name == "sys" && schema.is_system));
}

/// The databases a query tab can move to: the login's own marked as the
/// default and the server's four as system ones.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn the_servers_databases_are_listed_for_a_query_tab() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;

    let databases = connection.list_databases(within(CALL)).await.expect("the databases");

    let find = |name: &str| databases.iter().find(|database| database.name == name);
    assert!(
        databases.iter().filter(|database| database.is_default).count() == 1,
        "{databases:?}"
    );
    let master = find("master").expect("master");
    assert!(master.is_system, "{master:?}");
    let own = databases
        .iter()
        .find(|database| database.is_default)
        .expect("the login's database");
    assert!(!own.is_system || own.name == "master", "{own:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn fetch_table_definition_reports_pk_name_collation_comment() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.people (id int IDENTITY(1,1) CONSTRAINT PK_people PRIMARY KEY, \
             name nvarchar(100) COLLATE Latin1_General_CS_AS NOT NULL, \
             note nvarchar(max) SPARSE NULL, \
             total AS (id * 2) PERSISTED)",
            "EXEC sp_addextendedproperty @name = N'MS_Description', @value = N'what to call them', \
             @level0type = N'SCHEMA', @level0name = N'dbo', @level1type = N'TABLE', @level1name = N'people', \
             @level2type = N'COLUMN', @level2name = N'name'",
        ],
    )
    .await;

    let definition = connection
        .fetch_table_definition(&dbo("people"), within(CALL))
        .await
        .expect("the definition");

    let primary = definition.primary_key.as_ref().expect("a primary key");
    assert_eq!(primary.name.as_deref(), Some("PK_people"));
    assert_eq!(primary.columns, ["id"]);
    let id = definition.column("id").expect("id");
    assert_eq!(id.attributes.identity, IdentityStyle::MssqlIdentity);
    let name = definition.column("name").expect("name");
    assert_eq!(
        name.attributes
            .collation
            .as_ref()
            .map(|collation| collation.name.as_str()),
        Some("Latin1_General_CS_AS")
    );
    assert_eq!(name.info.comment.as_deref(), Some("what to call them"));
    assert!(definition.column("note").expect("note").attributes.sparse);
    assert!(
        definition
            .column("total")
            .expect("total")
            .attributes
            .generated
            .is_some()
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn fetch_table_definition_lists_inbound_foreign_keys() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.orders (id int PRIMARY KEY)",
            "CREATE TABLE dbo.lines (id int PRIMARY KEY, order_id int \
             CONSTRAINT FK_lines_orders REFERENCES dbo.orders (id) ON DELETE CASCADE)",
        ],
    )
    .await;

    let orders = connection
        .fetch_table_definition(&dbo("orders"), within(CALL))
        .await
        .expect("the definition");
    let lines = connection
        .fetch_foreign_keys(&dbo("lines"), within(CALL))
        .await
        .expect("the foreign keys");
    let alone = connection
        .fetch_inbound_foreign_keys(&dbo("orders"), within(CALL))
        .await
        .expect("the keys pointing at orders");

    assert_eq!(alone, orders.inbound_foreign_keys);
    assert_eq!(orders.inbound_foreign_keys.len(), 1);
    let inbound = &orders.inbound_foreign_keys[0];
    assert_eq!(inbound.name, "FK_lines_orders");
    assert_eq!(inbound.table, dbo("lines"));
    assert_eq!(inbound.columns, ["order_id"]);
    assert_eq!(inbound.referenced_columns, ["id"]);
    assert!(lines[0].references(Some("dbo"), "orders"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn default_constraint_name_is_read() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.jobs (id int PRIMARY KEY, state int CONSTRAINT [DF]]state] DEFAULT ((0)))"],
    )
    .await;

    let definition = connection
        .fetch_table_definition(&dbo("jobs"), within(CALL))
        .await
        .expect("the definition");

    let state = definition.column("state").expect("state");
    assert_eq!(state.attributes.default_constraint_name.as_deref(), Some("DF]state"));
    assert_eq!(state.info.default, ColumnDefault::Literal(Value::Int(0)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn alter_default_on_column_with_named_constraint() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE dbo.jobs (id int PRIMARY KEY, state int CONSTRAINT [DF]]state] DEFAULT ((0)))"],
    )
    .await;
    let table = dbo("jobs");
    let definition = connection
        .fetch_table_definition(&table, within(CALL))
        .await
        .expect("the definition");
    let dialect = MssqlDialect::new(connection.server_info().major);
    let mut draft = TableDraft::from_definition(&definition);
    if let Some(state) = draft.columns.iter_mut().find(|column| column.name == "state") {
        state.default = ColumnDefault::Literal(Value::Int(1));
    }

    let plan = dialect
        .plan_alter_table(&definition, &diff_table(&definition, &draft))
        .expect("the default change plans");
    setup(connection.as_ref(), &plan.sql()).await;

    let state = connection
        .fetch_table_definition(&table, within(CALL))
        .await
        .expect("the definition");
    let state = state.column("state").expect("state");
    // The new default goes back under the old constraint's name, so a
    // named constraint keeps its name through the change.
    assert_eq!(state.attributes.default_constraint_name.as_deref(), Some("DF]state"));
    assert_eq!(state.info.default, ColumnDefault::Literal(Value::Int(1)));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn like_escape_matches_literal_underscore_and_percent() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.names (name nvarchar(20) NOT NULL)",
            "INSERT INTO dbo.names VALUES (N'user_id'), (N'userXid'), (N'50%'), (N'[a]')",
        ],
    )
    .await;
    let dialect = connection.dialect();
    let table = TableRef::new(Some("dbo".to_owned()), "names");
    let contains = |needle: &str| {
        let mut builder = StatementBuilder::new();
        builder.push_sql(&format!("SELECT name FROM {} WHERE ", dialect.qualify(&table)));
        let pattern = format!("%{}%", dialect.escape_like_text(needle));
        let marker = builder
            .bind(dialect.as_ref(), Value::Text(pattern), BindTarget::Pattern)
            .expect("a pattern");
        builder.push_sql(&dialect.like_predicate("[name]", &marker, LikeForm::contains()));
        builder.finish()
    };

    for (needle, expected) in [("user_id", "user_id"), ("50%", "50%"), ("[a]", "[a]")] {
        let found = connection
            .query_bound(&contains(needle), RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .expect("a filtered read")
            .rows;
        assert_eq!(found, vec![vec![Value::Text(expected.to_owned())]], "{needle}");
    }
    let estimate = connection
        .table_estimate(&table, within(CALL))
        .await
        .expect("an estimate");
    assert!(estimate.rows.value().is_some());
    assert_eq!(
        connection
            .count_rows(&statement("SELECT COUNT_BIG(*) FROM dbo.names"), within(CALL))
            .await
            .expect("a count"),
        4
    );
    assert_eq!(
        rows(connection.as_ref(), "SELECT 1 WHERE 1 = 0").await,
        Vec::<Vec<Value>>::new()
    );
    assert_eq!(
        scalar(connection.as_ref(), "SELECT N'x'").await,
        Value::Text("x".to_owned())
    );
}

const ROUTINES: [&str; 7] = [
    "CREATE TABLE dbo.orders (id int PRIMARY KEY, total int)",
    "CREATE TABLE dbo.audit (id int PRIMARY KEY)",
    "CREATE FUNCTION dbo.add_tax(@amount int) RETURNS int AS BEGIN RETURN @amount * 2 END",
    "CREATE PROCEDURE clear_audit AS DELETE FROM dbo.audit",
    "CREATE PROCEDURE dbo.hidden WITH ENCRYPTION AS SELECT 1",
    "CREATE TRIGGER orders_total ON orders AFTER INSERT AS UPDATE dbo.orders SET total = total + 1000",
    "CREATE SEQUENCE dbo.invoice_numbers AS bigint START WITH 100 INCREMENT BY 5 CYCLE CACHE 20",
];

async fn listed(connection: &dyn tablepro_core::Connection) -> Vec<ObjectInfo> {
    connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects")
}

async fn definition(connection: &dyn tablepro_core::Connection, object: &ObjectInfo) -> String {
    let found = connection
        .fetch_object_definition(object, within(CALL))
        .await
        .expect("the definition")
        .expect("a definition");
    assert_eq!(found.database, None);
    found.sql
}

fn named<'a>(objects: &'a [ObjectInfo], name: &str) -> &'a ObjectInfo {
    objects
        .iter()
        .find(|object| object.name == name)
        .expect("the object listed")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn routines_sequences_and_triggers_are_listed_with_their_definitions() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &ROUTINES).await;

    let objects = listed(connection.as_ref()).await;
    let find = |name: &str| named(&objects, name);
    assert_eq!(find("add_tax").kind, ObjectKind::Function);
    assert_eq!(find("clear_audit").kind, ObjectKind::Procedure);
    assert_eq!(find("invoice_numbers").kind, ObjectKind::Sequence);
    assert_eq!(
        find("orders_total"),
        &ObjectInfo::trigger(Some("dbo".to_owned()), "orders_total", "orders")
    );
    assert!(
        objects
            .iter()
            .filter(|object| object.kind != ObjectKind::Trigger)
            .all(|object| object.parent_table.is_none())
    );
    for (name, body) in [
        ("add_tax", "@amount * 2"),
        ("clear_audit", "DELETE FROM dbo.audit"),
        ("orders_total", "total + 1000"),
        ("invoice_numbers", "START WITH 100 INCREMENT BY 5"),
    ] {
        let sql = definition(connection.as_ref(), find(name)).await;
        assert!(sql.contains(body), "{name}: {sql}");
    }
    let sequence = definition(connection.as_ref(), find("invoice_numbers")).await;
    assert!(
        sequence.starts_with("CREATE SEQUENCE [dbo].[invoice_numbers] AS bigint")
            && sequence.contains(" CYCLE CACHE 20;"),
        "{sequence}"
    );
    let hidden = connection.fetch_object_definition(find("hidden"), within(CALL)).await;
    assert!(
        matches!(
            hidden,
            Err(DriverError::Unsupported {
                feature: UnsupportedFeature::EncryptedDefinition
            })
        ),
        "{hidden:?}"
    );
    let table_object = ObjectInfo::new(Some("dbo".to_owned()), "orders", ObjectKind::Table);
    assert!(matches!(
        connection.fetch_object_definition(&table_object, within(CALL)).await,
        Err(DriverError::Unsupported { .. })
    ));
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_module_written_without_its_schema_is_given_it_and_runs_again() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(connection.as_ref(), &ROUTINES).await;
    let objects = listed(connection.as_ref()).await;
    let trigger = named(&objects, "orders_total");

    let procedure = definition(connection.as_ref(), named(&objects, "clear_audit")).await;
    assert!(
        procedure.starts_with("CREATE PROCEDURE [dbo].clear_audit AS"),
        "{procedure}"
    );
    setup(
        connection.as_ref(),
        &["ALTER PROCEDURE clear_audit AS DELETE FROM dbo.audit WHERE id > 0"],
    )
    .await;
    let altered = definition(connection.as_ref(), named(&objects, "clear_audit")).await;
    assert!(
        altered.contains("PROCEDURE [dbo].clear_audit AS DELETE FROM dbo.audit WHERE id > 0"),
        "the stored text after an ALTER is qualified too: {altered}"
    );
    let on_orders = definition(connection.as_ref(), trigger).await;
    assert!(
        on_orders.starts_with("CREATE TRIGGER [dbo].orders_total ON [dbo].orders AFTER INSERT"),
        "{on_orders}"
    );
    setup(connection.as_ref(), &["DROP TRIGGER dbo.orders_total"]).await;
    setup(connection.as_ref(), &[on_orders.as_str()]).await;
    assert!(
        listed(connection.as_ref()).await.contains(trigger),
        "the text made the trigger again where it was"
    );

    let mut elsewhere = trigger.clone();
    elsewhere.parent_table = Some("audit".to_owned());
    let missing = connection
        .fetch_object_definition(&elsewhere, within(CALL))
        .await
        .expect("an answer");
    assert_eq!(missing, None, "a trigger on another table is not this trigger");
    connection.close().await.expect("a close");
}
