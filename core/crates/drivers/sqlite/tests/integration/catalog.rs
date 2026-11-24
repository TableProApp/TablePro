//! Column kinds from SQLite's structured catalogue, and table
//! definitions with their dependents.

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{Connection as _, Executor as _};
use tablepro_core::column::{ColumnDefault, ColumnKind, IntegerKind, IntegerWidth};
use tablepro_core::ddl::{GeneratedStorage, IdentityStyle, SchemaObjectKind};
use tablepro_core::meta::{ObjectScope, TableRef};
use tablepro_core::{DriverError, ServerCode, Value};

use crate::support::{TestFile, apply, call, connect, writable};

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

// A large real schema stays under the catalog budget: every table, and every key into a table thousands of others
// point at, read whole and in order. SQLite takes time quadratic in the tables to create them, hence not 50,000.
#[tokio::test]
async fn a_large_catalog_reads_whole() {
    const CHILDREN: usize = 5_000;
    const WIDE_KEYS: usize = 500;
    let file = TestFile::new().await;
    let mut script = String::from("BEGIN; CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT UNIQUE);");
    for child in 0..CHILDREN {
        script.push_str(&format!(
            "CREATE TABLE child_{child:05} (id INTEGER PRIMARY KEY, owner INTEGER REFERENCES users, email TEXT, \
             CONSTRAINT by_email_{child:05} FOREIGN KEY (email) REFERENCES users (email));"
        ));
    }
    let columns: Vec<String> = (0..WIDE_KEYS * 2).map(|column| format!("c{column} INTEGER")).collect();
    let keys: Vec<String> = (0..WIDE_KEYS)
        .map(|column| format!("FOREIGN KEY (c{column}) REFERENCES users"))
        .collect();
    script.push_str(&format!(
        "CREATE TABLE wide ({}, {}); COMMIT;",
        columns.join(", "),
        keys.join(", ")
    ));
    let mut writer = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    writer.execute(sqlx::AssertSqlSafe(script)).await.unwrap();
    writer.close().await.unwrap();
    let connection = file.open().await;
    let users = TableRef::unqualified("users");
    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, call())
        .await
        .unwrap();
    let inbound = connection.fetch_inbound_foreign_keys(&users, call()).await.unwrap();
    let definition = connection.fetch_table_definition(&users, call()).await.unwrap();
    let wide = connection
        .fetch_outbound_foreign_keys(&TableRef::unqualified("wide"), call())
        .await
        .unwrap();

    assert_eq!(objects.len(), CHILDREN + 2);
    assert_eq!(inbound.len(), CHILDREN * 2 + WIDE_KEYS);
    type Key<'a> = (&'a str, &'a str, &'a [String], &'a [String], bool);
    let first: Vec<Key<'_>> = inbound[..2]
        .iter()
        .map(|key| {
            (
                key.table.name.as_str(),
                key.name.as_str(),
                key.columns.as_slice(),
                key.referenced_columns.as_slice(),
                key.child_compares_alike,
            )
        })
        .collect();
    assert_eq!(
        first,
        [
            (
                "child_00000",
                "by_email_00000",
                &["email".to_owned()][..],
                &["email".to_owned()][..],
                true
            ),
            (
                "child_00000",
                "fk_child_00000_1",
                &["owner".to_owned()][..],
                &["id".to_owned()][..],
                true
            ),
        ]
    );
    assert!(
        inbound.windows(2).all(|pair| pair[0].table.name <= pair[1].table.name),
        "ordered by child"
    );
    assert_eq!(inbound.last().map(|key| key.table.name.as_str()), Some("wide"));
    assert_eq!(definition.inbound_foreign_keys, inbound);
    assert_eq!(wide.len(), WIDE_KEYS);
    assert!(
        wide.iter()
            .enumerate()
            .all(|(id, key)| key.key.name == format!("fk_wide_{id}")
                && key.key.ref_table == "users"
                && key.key.ref_columns == ["id"]
                && key.parent_compares_alike)
    );
    connection.close().await.unwrap();
}

// Only tables whose CREATE TABLE names the parent are asked for their keys, so a name written with its quote doubled,
// or in other case, still finds them.
#[tokio::test]
async fn keys_into_a_table_are_found_however_its_name_is_written() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE \"we\"\"ird's\" (id INTEGER PRIMARY KEY)",
            "CREATE TABLE doubled (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES \"WE\"\"IRD's\")",
            "CREATE TABLE quoted (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES 'we\"ird''s' (id))",
            "CREATE TABLE ticked (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES `we\"ird's`)",
            "CREATE TABLE unrelated (id INTEGER PRIMARY KEY, other INTEGER REFERENCES doubled)",
        ],
    )
    .await
    .unwrap();

    let inbound = connection
        .fetch_inbound_foreign_keys(&TableRef::unqualified("we\"ird's"), call())
        .await
        .unwrap();

    let children: Vec<&str> = inbound.iter().map(|key| key.table.name.as_str()).collect();
    assert_eq!(children, ["doubled", "quoted", "ticked"]);
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

async fn create(file: &TestFile, sql: String) {
    let mut writer = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    writer.execute(sqlx::AssertSqlSafe(sql)).await.unwrap();
    writer.close().await.unwrap();
}

// Past ten million bytes SQLite calls the schema malformed, so a crafted statement cannot reach the catalog reads.
#[tokio::test]
async fn a_create_statement_past_ten_million_bytes_does_not_open() {
    let file = TestFile::new().await;
    create(
        &file,
        format!("CREATE TABLE fits (a INTEGER /* {} */)", "x".repeat(9_000_000)),
    )
    .await;
    let connection = file.open().await;
    let columns = connection.fetch_columns(&TableRef::unqualified("fits"), call()).await;
    assert_eq!(columns.map(|columns| columns.len()), Ok(1));
    connection.close().await.unwrap();

    create(
        &file,
        format!("CREATE TABLE past (a INTEGER /* {} */)", "x".repeat(10_000_000)),
    )
    .await;
    let opened = connect(file.endpoint(), writable()).await.map(|_| ());

    assert!(
        matches!(&opened, Err(DriverError::Server(diagnostics))
            if matches!(diagnostics.code, Some(ServerCode::Sqlite { primary: 11, .. }))),
        "{opened:?}"
    );
}

// SQLite parses a stored CREATE text only to its statement's end, so a crafted file can carry any tail after it; the
// catalog reads that parse the text refuse it past the same cap, before parsing it.
#[tokio::test]
async fn a_stored_create_text_past_the_cap_is_refused_before_it_is_parsed() {
    let file = TestFile::new().await;
    create(&file, "CREATE TABLE t (a INTEGER)".to_owned()).await;
    let mut writer = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    writer.execute("PRAGMA writable_schema = ON").await.unwrap();
    writer
        .execute(
            "UPDATE sqlite_schema SET sql = sql || '; ' || replace(hex(zeroblob(5500000)), '00', 'x ') \
             WHERE name = 't'",
        )
        .await
        .unwrap();
    writer.close().await.unwrap();
    let connection = file.open().await;
    let table = TableRef::unqualified("t");

    let objects = connection.list_objects(&ObjectScope::DefaultSchema, call()).await;
    let columns = connection.fetch_columns(&table, call()).await;
    let keys = connection.fetch_foreign_keys(&table, call()).await.map(|_| ());
    let definition = connection.fetch_table_definition(&table, call()).await.map(|_| ());

    assert_eq!(
        objects.map(|objects| objects.len()),
        Ok(1),
        "SQLite read the statement and left the tail"
    );
    assert_eq!(
        columns.map(|columns| columns.len()),
        Ok(1),
        "a read that parses no text reads as before"
    );
    let refused = Err(DriverError::CatalogTooLarge {
        limit_bytes: 10_000_000,
    });
    assert_eq!(keys, refused);
    assert_eq!(definition, refused);
    connection.close().await.unwrap();
}

// A tail under the cap is cut where SQLite stops reading: an index's tail of 50,000 additions, which sqlparser would
// drop one call per term, and a table's tail, which would reach a rebuild's source and a dump.
#[tokio::test]
async fn a_stored_text_is_read_to_its_first_statement() {
    let file = TestFile::new().await;
    create(&file, "CREATE TABLE p (id INTEGER PRIMARY KEY)".to_owned()).await;
    create(&file, "CREATE TABLE c (a INTEGER REFERENCES p)".to_owned()).await;
    create(&file, "CREATE INDEX ci ON c (a) WHERE a > 0".to_owned()).await;
    let mut writer = SqliteConnection::connect_with(&SqliteConnectOptions::new().filename(&file.path))
        .await
        .unwrap();
    writer.execute("PRAGMA writable_schema = ON").await.unwrap();
    writer
        .execute("UPDATE sqlite_schema SET sql = sql || '; DROP TABLE p' WHERE name = 'c'")
        .await
        .unwrap();
    writer
        .execute(sqlx::AssertSqlSafe(format!(
            "UPDATE sqlite_schema SET sql = sql || '; SELECT {}' WHERE name = 'ci'",
            vec!["1"; 50_000].join("+")
        )))
        .await
        .unwrap();
    writer.close().await.unwrap();
    let connection = file.open().await;
    let table = TableRef::unqualified("c");

    let definition = connection.fetch_table_definition(&table, call()).await.unwrap();
    let indexes = connection.fetch_indexes(&table, call()).await.unwrap();

    assert_eq!(
        definition.source.map(|source| source.create_statement),
        Some("CREATE TABLE c (a INTEGER REFERENCES p)".to_owned())
    );
    assert_eq!(definition.foreign_keys.len(), 1);
    assert_eq!(indexes.len(), 1);
    assert_eq!(indexes[0].predicate.as_deref(), Some("a > 0"));
    assert_eq!(
        indexes[0].definition.as_deref(),
        Some("CREATE INDEX \"main\".ci ON c (a) WHERE a > 0")
    );
    connection.close().await.unwrap();
}
