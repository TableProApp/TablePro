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

/// The pragma repeats a REFERENCES clause as written; every other read,
/// and a filter on the parent's columns, names them as declared.
#[tokio::test]
async fn foreign_keys_name_the_parent_and_its_columns_as_declared() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE customers (Id INTEGER, Region TEXT, PRIMARY KEY (Id, Region))",
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, region TEXT, \
             FOREIGN KEY (CUSTOMER_ID, region) REFERENCES Customers (ID, REGION))",
            "CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer_id INTEGER, region TEXT, \
             FOREIGN KEY (customer_id, region) REFERENCES CUSTOMERS)",
        ],
    )
    .await
    .unwrap();

    let outbound = connection
        .fetch_foreign_keys(&TableRef::unqualified("orders"), call())
        .await
        .unwrap();
    let implicit = connection
        .fetch_foreign_keys(&TableRef::unqualified("invoices"), call())
        .await
        .unwrap();
    let inbound = connection
        .fetch_inbound_foreign_keys(&TableRef::unqualified("customers"), call())
        .await
        .unwrap();

    let declared = vec!["Id".to_owned(), "Region".to_owned()];
    assert_eq!(outbound[0].ref_table, "customers");
    assert_eq!(outbound[0].ref_columns, declared);
    assert_eq!(outbound[0].columns, ["customer_id", "region"]);
    assert_eq!(implicit[0].ref_table, "customers");
    assert_eq!(implicit[0].ref_columns, declared);
    let pointing: Vec<(&str, &[String])> = inbound
        .iter()
        .map(|key| (key.table.name.as_str(), key.referenced_columns.as_slice()))
        .collect();
    assert_eq!(pointing, [("invoices", &declared[..]), ("orders", &declared[..])]);
    connection.close().await.unwrap();
}

/// SQLite accepts a key to a table that is not there, and keeps one
/// whose table was dropped while foreign keys were off.
#[tokio::test]
async fn a_key_to_a_missing_table_leaves_the_tables_other_keys_readable() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE owners (id INTEGER PRIMARY KEY)",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, owner INTEGER REFERENCES owners, \
             ghost_id INTEGER REFERENCES ghost, spook_id INTEGER REFERENCES Spook (Id))",
        ],
    )
    .await
    .unwrap();
    let notes = TableRef::unqualified("notes");

    let keys = connection.fetch_foreign_keys(&notes, call()).await.unwrap();
    let definition = connection.fetch_table_definition(&notes, call()).await.unwrap();

    let mut read: Vec<(&str, &[String])> = keys
        .iter()
        .map(|key| (key.ref_table.as_str(), key.ref_columns.as_slice()))
        .collect();
    read.sort_unstable();
    assert_eq!(
        read,
        [
            ("Spook", &["Id".to_owned()][..]),
            ("ghost", &[][..]),
            ("owners", &["id".to_owned()][..]),
        ]
    );
    assert_eq!(definition.foreign_keys, keys);
    connection.close().await.unwrap();
}

/// SQLite matches a key under the parent column's affinity and
/// collation, which `=` on a column declared otherwise does not, and a
/// filter reads its value under the column's declared type.
#[tokio::test]
async fn a_key_says_whether_its_columns_compare_as_it_does() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE users (email TEXT PRIMARY KEY COLLATE NOCASE, id INTEGER UNIQUE)",
            "CREATE TABLE posts (id INTEGER PRIMARY KEY, author TEXT REFERENCES users (email))",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, author TEXT COLLATE \"NoCase\" REFERENCES users (email))",
            "CREATE TABLE logs (id INTEGER PRIMARY KEY, user_id TEXT REFERENCES users (id))",
            "CREATE TABLE visits (id INTEGER PRIMARY KEY, user_id INT REFERENCES users (id))",
            "CREATE TABLE scores (id INTEGER PRIMARY KEY, user_id REAL REFERENCES users (id))",
            "CREATE TABLE tags (id INTEGER PRIMARY KEY, user_id REFERENCES users (id))",
            "CREATE TABLE ghosts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES gone (id))",
        ],
    )
    .await
    .unwrap();

    let inbound = connection
        .fetch_inbound_foreign_keys(&TableRef::unqualified("users"), call())
        .await
        .unwrap();
    let mut outbound = Vec::new();
    for child in ["posts", "notes", "logs", "visits", "scores", "tags", "ghosts"] {
        let keys = connection
            .fetch_outbound_foreign_keys(&TableRef::unqualified(child), call())
            .await
            .unwrap();
        outbound.push((child, keys[0].parent_compares_alike));
    }

    let alike: Vec<(&str, bool)> = inbound
        .iter()
        .map(|key| (key.table.name.as_str(), key.child_compares_alike))
        .collect();
    assert_eq!(
        alike,
        [
            ("logs", false),
            ("notes", true),
            ("posts", false),
            ("scores", false),
            ("tags", false),
            ("visits", true)
        ]
    );
    assert_eq!(
        outbound,
        [
            ("posts", false),
            ("notes", true),
            ("logs", false),
            ("visits", true),
            ("scores", false),
            ("tags", false),
            ("ghosts", true)
        ]
    );
    connection.close().await.unwrap();
}

#[tokio::test]
async fn inbound_keys_read_alone_are_the_definitions() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE orders (id INTEGER PRIMARY KEY, code TEXT UNIQUE)",
            "CREATE TABLE lines (id INTEGER PRIMARY KEY, order_id INTEGER REFERENCES orders)",
            "CREATE TABLE notes (id INTEGER PRIMARY KEY, order_code TEXT REFERENCES \"ORDERS\" (CODE))",
        ],
    )
    .await
    .unwrap();
    let orders = TableRef::unqualified("orders");

    let inbound = connection.fetch_inbound_foreign_keys(&orders, call()).await.unwrap();
    let definition = connection.fetch_table_definition(&orders, call()).await.unwrap();

    assert_eq!(inbound, definition.inbound_foreign_keys);
    assert_eq!(inbound[1].referenced_columns, ["code"]);
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
