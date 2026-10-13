//! Structure changes the PostgreSQL dialect plans, run against a real
//! server.

use tablepro_core::ddl::{
    CollationName, DraftColumn, DraftType, IdentityStyle, PrimaryKeyConstraint, TableDefinition, TableDraft, diff_table,
};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, WriteKind};

use crate::support::{CALL, apply, connect, scalar, setup, start, text, within};

fn kept() -> TableRef {
    TableRef::new(Some("public".to_owned()), "kept")
}

async fn read(connection: &dyn Connection) -> TableDefinition {
    read_table(connection, &kept()).await
}

async fn read_table(connection: &dyn Connection, table: &TableRef) -> TableDefinition {
    connection
        .fetch_table_definition(table, within(CALL))
        .await
        .expect("the definition")
}

/// Plan the edit against the table as read, run it as the structure tab
/// saves, and read the table again.
async fn change(connection: &dyn Connection, table: &TableRef, edit: impl Fn(&mut DraftColumn)) -> TableDefinition {
    let before = read_table(connection, table).await;
    let mut draft = TableDraft::from_definition(&before);
    draft.columns.iter_mut().for_each(edit);
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("PostgreSQL plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");
    connection
        .write_batch(&plan.into_write_batch(table.clone()), within(CALL))
        .await
        .expect("the change runs");
    read_table(connection, table).await
}

fn type_of(definition: &TableDefinition, column: &str) -> String {
    definition
        .column(column)
        .map(|column| column.info.column_type.name.clone())
        .unwrap_or_default()
}

async fn value(connection: &dyn Connection, sql: &str) -> String {
    text(&scalar(connection, sql).await)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn rename_and_retype_column_applies() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id int PRIMARY KEY, code varchar(10), qty smallint)",
            "INSERT INTO kept VALUES (1, 'a', 5)",
        ],
    )
    .await;

    let after = change(connection.as_ref(), &kept(), |column| match column.name.as_str() {
        "code" => {
            column.name = "label".to_owned();
            column.column_type = DraftType::Typed("varchar(40)".to_owned());
        }
        "qty" => {
            column.name = "amount".to_owned();
            column.column_type = DraftType::Typed("bigint".to_owned());
        }
        _ => {}
    })
    .await;

    let names: Vec<&str> = after.columns.iter().map(|column| column.name()).collect();
    assert_eq!(names, ["id", "label", "amount"]);
    assert_eq!(type_of(&after, "label"), "character varying(40)");
    assert_eq!(type_of(&after, "amount"), "bigint");
    assert_eq!(
        value(connection.as_ref(), "SELECT label || '|' || amount FROM kept").await,
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
            "CREATE TABLE kept (id int PRIMARY KEY, a text, b integer, c boolean)",
            "CREATE INDEX kept_by_a ON kept (a)",
            "INSERT INTO kept VALUES (1, 'x', 2, true)",
        ],
    )
    .await;

    let after = change(connection.as_ref(), &kept(), |column| {
        column.name = match column.name.as_str() {
            "a" => "b",
            "b" => "c",
            "c" => "a",
            other => other,
        }
        .to_owned();
    })
    .await;

    let names: Vec<&str> = after.columns.iter().map(|column| column.name()).collect();
    assert_eq!(names, ["id", "b", "c", "a"]);
    assert_eq!(type_of(&after, "b"), "text");
    assert_eq!(type_of(&after, "c"), "integer");
    assert_eq!(type_of(&after, "a"), "boolean");
    assert_eq!(
        value(connection.as_ref(), "SELECT b || '|' || c || '|' || a FROM kept").await,
        "x|2|true"
    );
    assert_eq!(
        value(connection.as_ref(), "SELECT pg_get_indexdef('kept_by_a'::regclass)").await,
        "CREATE INDEX kept_by_a ON public.kept USING btree (b)"
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
            "CREATE TABLE kept (order_id int PRIMARY KEY, line int, sku text)",
            "INSERT INTO kept VALUES (1, 1, 'a'), (2, 1, 'b')",
        ],
    )
    .await;

    let after = change(connection.as_ref(), &kept(), |column| {
        if column.name == "line" {
            column.primary_key = true;
            column.nullable = false;
        }
    })
    .await;

    assert_eq!(
        after.primary_key.as_ref().map(|key| key.columns.clone()),
        Some(vec!["order_id".to_owned(), "line".to_owned()])
    );
    assert!(!after.column("line").expect("line").info.nullable);
    apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO kept VALUES (1, 2, 'c')"],
    )
    .await
    .expect("a second line of order 1");
    let repeated = apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO kept VALUES (1, 1, 'd')"],
    )
    .await;
    assert!(repeated.is_err(), "the key does not hold the line");
    connection.close().await.expect("a close");
}

/// The table and column take capitals and a space, which `regclass`
/// reads only when the table is quoted and the column is not.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn toggle_identity_on_populated_table_then_insert() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let table = TableRef::new(Some("public".to_owned()), "Ticket Log");
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE \"Ticket Log\" (\"Id\" int PRIMARY KEY, label text)",
            "INSERT INTO \"Ticket Log\" VALUES (1, 'a'), (2, 'b'), (3, 'c'), (4, 'd'), (5, 'e'), (42, 'f')",
        ],
    )
    .await;

    let numbered = change(connection.as_ref(), &table, |column| {
        if column.name == "Id" {
            column.auto_increment = true;
        }
    })
    .await;
    apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO \"Ticket Log\" (label) VALUES ('next')"],
    )
    .await
    .expect("an insert without an id");

    let id = numbered.column("Id").expect("Id");
    assert!(id.info.is_auto_increment);
    assert_eq!(id.attributes.identity, IdentityStyle::GeneratedByDefault);
    assert_eq!(
        value(
            connection.as_ref(),
            "SELECT \"Id\" FROM \"Ticket Log\" WHERE label = 'next'"
        )
        .await,
        "43"
    );

    let plain = change(connection.as_ref(), &table, |column| {
        if column.name == "Id" {
            column.auto_increment = false;
        }
    })
    .await;

    let id = plain.column("Id").expect("Id");
    assert!(!id.info.is_auto_increment);
    assert_eq!(id.attributes.identity, IdentityStyle::None);
    assert!(
        apply(
            connection.as_ref(),
            WriteKind::RowChanges,
            &["INSERT INTO \"Ticket Log\" (label) VALUES ('unnumbered')"],
        )
        .await
        .is_err(),
        "the identity is still there"
    );
    assert_eq!(
        plain.primary_key,
        Some(PrimaryKeyConstraint {
            name: Some("Ticket Log_pkey".to_owned()),
            columns: vec!["Id".to_owned()],
        })
    );
    connection.close().await.expect("a close");
}

/// A serial turned off keeps its sequence, owned by the column, so the
/// identity added later is not the only sequence the column has.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn identity_after_serial_off_numbers_past_rows() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id serial PRIMARY KEY, label text)",
            "INSERT INTO kept (label) VALUES ('a'), ('b'), ('c')",
        ],
    )
    .await;
    let numbering = |on: bool| {
        move |column: &mut DraftColumn| {
            if column.name == "id" {
                column.auto_increment = on;
            }
        }
    };

    let plain = change(connection.as_ref(), &kept(), numbering(false)).await;
    assert_eq!(
        plain.column("id").map(|id| id.attributes.identity),
        Some(IdentityStyle::None)
    );
    let numbered = change(connection.as_ref(), &kept(), numbering(true)).await;
    apply(
        connection.as_ref(),
        WriteKind::RowChanges,
        &["INSERT INTO kept (label) VALUES ('next')"],
    )
    .await
    .expect("an insert without an id");

    assert_eq!(
        numbered.column("id").map(|id| id.attributes.identity),
        Some(IdentityStyle::GeneratedByDefault)
    );
    assert_eq!(
        value(connection.as_ref(), "SELECT id FROM kept WHERE label = 'next'").await,
        "4"
    );
    connection.close().await.expect("a close");
}

/// SET DATA TYPE gives the column the new type's default collation
/// unless the statement names one, so a type change on a text column
/// has to name the one it had.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn type_change_keeps_c_collation() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id int PRIMARY KEY, code varchar(10) COLLATE \"C\", tags text[] COLLATE \"C\", \
           amount varchar(10) COLLATE \"C\")",
        ],
    )
    .await;
    let before = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&before);
    for column in &mut draft.columns {
        let retyped = match column.name.as_str() {
            "code" => "varchar(40)",
            "tags" => "varchar(20)[]",
            "amount" => "integer",
            _ => continue,
        };
        column.column_type = DraftType::Typed(retyped.to_owned());
    }
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("PostgreSQL plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");

    connection
        .write_batch(&plan.into_write_batch(kept()), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection.as_ref()).await;

    assert_eq!(before.columns.len(), after.columns.len());
    for old in &before.columns {
        let mut expected = old.attributes.clone();
        // An integer holds no text, so it has no collation to keep.
        if old.name() == "amount" {
            expected.collation = None;
        }
        let new = after.column(old.name()).expect("the column");
        assert_eq!(new.attributes, expected, "{}", old.name());
    }
    let c = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
    let column = |name: &str| after.column(name).expect("the column");
    assert_eq!(column("code").attributes.collation, c);
    assert_eq!(column("code").info.column_type.name, "character varying(40)");
    assert_eq!(column("tags").attributes.collation, c);
    assert_eq!(column("tags").info.column_type.name, "character varying(20)[]");
    assert_eq!(column("amount").attributes.collation, None);
    assert_eq!(column("amount").info.column_type.name, "integer");
    connection.close().await.expect("a close");
}
