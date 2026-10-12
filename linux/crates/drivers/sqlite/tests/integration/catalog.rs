//! Column kinds from SQLite's structured catalogue, and table
//! definitions with their dependents.

use tablepro_core::Value;
use tablepro_core::column::{ColumnDefault, ColumnKind, IntegerKind, IntegerWidth};
use tablepro_core::ddl::{GeneratedStorage, IdentityStyle, SchemaObjectKind};
use tablepro_core::meta::TableRef;

use crate::support::{TestFile, apply, call};

#[tokio::test]
async fn strict_table_is_not_dynamic() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE fixed (id INTEGER PRIMARY KEY, n INTEGER, anything ANY) STRICT"],
    )
    .await
    .unwrap();

    let columns = connection
        .fetch_columns(&TableRef::unqualified("fixed"), call())
        .await
        .unwrap();

    assert!(
        !columns[1].column_type.dynamic_storage,
        "a STRICT column holds only its type"
    );
    assert!(
        columns[2].column_type.dynamic_storage,
        "ANY holds any class even when STRICT"
    );
    assert_eq!(
        columns[1].column_type.kind,
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true
        })
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn decimal_declared_type_is_decimal_dynamic() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &["CREATE TABLE prices (amount DECIMAL(10,2) DEFAULT 0, label TEXT DEFAULT 'none')"],
    )
    .await
    .unwrap();

    let columns = connection
        .fetch_columns(&TableRef::unqualified("prices"), call())
        .await
        .unwrap();

    assert_eq!(
        columns[0].column_type.kind,
        ColumnKind::Decimal {
            precision: Some(10),
            scale: Some(2)
        }
    );
    assert!(columns[0].column_type.dynamic_storage);
    assert_eq!(
        columns[0]
            .column_type
            .catalog
            .as_ref()
            .map(|catalog| catalog.declaration.as_sql()),
        Some("DECIMAL(10,2)")
    );
    assert_eq!(columns[0].default, ColumnDefault::Literal(Value::Int(0)));
    assert_eq!(
        columns[1].default,
        ColumnDefault::Literal(Value::Text("none".to_owned()))
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn fetch_table_definition_lists_inbound_foreign_keys() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, code TEXT UNIQUE)",
            "CREATE TABLE lines (id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders)",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, order_code TEXT REFERENCES \"ORDERS\" (code))",
            "CREATE TABLE unrelated (id INTEGER PRIMARY KEY)",
        ],
    )
    .await
    .unwrap();

    let definition = connection
        .fetch_table_definition(&TableRef::unqualified("orders"), call())
        .await
        .unwrap();

    let inbound: Vec<(&str, &[String], &[String])> = definition
        .inbound_foreign_keys
        .iter()
        .map(|key| {
            (
                key.table.name.as_str(),
                key.columns.as_slice(),
                key.referenced_columns.as_slice(),
            )
        })
        .collect();
    assert_eq!(
        inbound,
        [
            ("lines", &["order_id".to_owned()][..], &["id".to_owned()][..]),
            ("notes", &["order_code".to_owned()][..], &["code".to_owned()][..]),
        ]
    );
    assert_eq!(
        definition.primary_key.map(|key| key.columns),
        Some(vec!["id".to_owned()])
    );
    assert_eq!(
        definition.columns[0].attributes.identity,
        IdentityStyle::SqliteRowidAlias
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn dependents_and_source_are_read() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, total INTEGER, doubled INTEGER GENERATED ALWAYS AS (total * 2) STORED)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE INDEX orders_total ON orders (total)",
            "CREATE VIEW big AS SELECT * FROM orders WHERE total > 10",
            "CREATE VIEW big_count AS SELECT count(*) AS n FROM big",
            "CREATE TRIGGER audit_note AFTER INSERT ON audit BEGIN DELETE FROM orders WHERE total = 0; END",
            "CREATE TRIGGER audit_other AFTER INSERT ON audit BEGIN SELECT 'orders'; END",
        ],
    )
    .await
    .unwrap();

    let definition = connection
        .fetch_table_definition(&TableRef::unqualified("orders"), call())
        .await
        .unwrap();

    let source = definition.source.as_ref().unwrap();
    assert!(
        source.create_statement.starts_with("CREATE TABLE orders"),
        "{}",
        source.create_statement
    );
    let dependents: Vec<(SchemaObjectKind, &str)> = source
        .dependents
        .iter()
        .map(|object| (object.kind, object.name.as_str()))
        .collect();
    assert_eq!(
        dependents,
        [
            (SchemaObjectKind::Index, "orders_total"),
            (SchemaObjectKind::View, "big"),
            (SchemaObjectKind::View, "big_count"),
            (SchemaObjectKind::Trigger, "audit_note"),
        ]
    );
    let doubled = definition.column("doubled").unwrap();
    assert!(doubled.info.is_generated);
    let generated = doubled.attributes.generated.as_ref().unwrap();
    assert_eq!(generated.storage, GeneratedStorage::Stored);
    assert_eq!(generated.expression.as_sql(), "total * 2");
    connection.close().await.unwrap();
}
