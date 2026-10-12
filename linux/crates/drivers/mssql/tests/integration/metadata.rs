//! The catalogue as browse and the structure tab read it.

use drivers_mssql::{MssqlDdl, MssqlDialect};
use tablepro_core::column::{ColumnDefault, ColumnKind, ReadForm, TextLength};
use tablepro_core::ddl::IdentityStyle;
use tablepro_core::dialect::{BindTarget, LikeForm};
use tablepro_core::meta::{ObjectKind, ObjectScope, RowIdentity, TableRef};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{RowLimit, Value};

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

    let drop = MssqlDdl::drop_default_constraint(&dialect, &table, definition.column("state").expect("state"))
        .expect("a constraint to drop");
    setup(
        connection.as_ref(),
        &[
            &drop,
            "ALTER TABLE dbo.jobs ADD CONSTRAINT DF_state_one DEFAULT ((1)) FOR state",
        ],
    )
    .await;

    let state = connection
        .fetch_table_definition(&table, within(CALL))
        .await
        .expect("the definition");
    let state = state.column("state").expect("state");
    assert_eq!(
        state.attributes.default_constraint_name.as_deref(),
        Some("DF_state_one")
    );
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
