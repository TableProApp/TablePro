//! Structure changes the SQLite dialect plans, run against a database
//! file.

use tablepro_core::ddl::{DraftColumn, SchemaObjectKind, TableDefinition, TableDraft, diff_table};
use tablepro_core::meta::TableRef;
use tablepro_core::{Connection, Value};

use crate::support::{TestFile, apply, call, query};

fn kept() -> TableRef {
    TableRef::unqualified("kept")
}

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection.fetch_table_definition(&kept(), call()).await.unwrap()
}

/// Plan the edit against the table as read, run it as the structure tab
/// saves, and read the table again.
async fn change(connection: &dyn Connection, edit: impl Fn(&mut DraftColumn)) -> TableDefinition {
    let before = read(connection).await;
    let mut draft = TableDraft::from_definition(&before);
    draft.columns.iter_mut().for_each(edit);
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .unwrap()
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .unwrap();
    connection
        .write_batch(&plan.into_write_batch(kept()), call())
        .await
        .unwrap();
    read(connection).await
}

/// The stored statement with its quotes taken out: SQLite writes a
/// renamed name the way the rename spelled it.
fn dependent(definition: &TableDefinition, kind: SchemaObjectKind) -> String {
    definition
        .source
        .as_ref()
        .and_then(|source| source.dependents.iter().find(|object| object.kind == kind))
        .map(|object| object.sql.replace('"', ""))
        .unwrap_or_default()
}

/// SQLite rewrites the indexes and triggers that name a column as it
/// renames it, and a swap goes through a temporary name.
#[tokio::test]
async fn rename_column_updates_index_and_trigger() {
    let file = TestFile::new().await;
    let connection = file.open().await;
    apply(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id INTEGER PRIMARY KEY, email TEXT, name TEXT)",
            "CREATE TABLE audit (note TEXT)",
            "CREATE INDEX kept_by_email ON kept (email)",
            "CREATE TRIGGER kept_audit AFTER INSERT ON kept BEGIN INSERT INTO audit VALUES (new.email); END",
            "INSERT INTO kept VALUES (1, 'a@x', 'Ann')",
        ],
    )
    .await
    .unwrap();

    let renamed = change(connection.as_ref(), |column| {
        if column.name == "email" {
            column.name = "mail".to_owned();
        }
    })
    .await;
    let swapped = change(connection.as_ref(), |column| {
        column.name = match column.name.as_str() {
            "mail" => "name",
            "name" => "mail",
            other => other,
        }
        .to_owned();
    })
    .await;
    apply(
        connection.as_ref(),
        &["INSERT INTO kept (id, name, mail) VALUES (2, 'b@x', 'Bo')"],
    )
    .await
    .unwrap();

    let names = |definition: &TableDefinition| {
        definition
            .columns
            .iter()
            .map(|column| column.name().to_owned())
            .collect::<Vec<_>>()
    };
    assert_eq!(names(&renamed), ["id", "mail", "name"]);
    assert!(dependent(&renamed, SchemaObjectKind::Index).contains("(mail)"));
    assert!(dependent(&renamed, SchemaObjectKind::Trigger).contains("new.mail"));
    assert_eq!(names(&swapped), ["id", "name", "mail"]);
    assert!(dependent(&swapped, SchemaObjectKind::Index).contains("(name)"));
    assert!(dependent(&swapped, SchemaObjectKind::Trigger).contains("new.name"));
    let audit = query(connection.as_ref(), "SELECT note FROM audit ORDER BY rowid").await;
    assert_eq!(
        audit.rows,
        [vec![Value::Text("a@x".to_owned())], vec![Value::Text("b@x".to_owned())]]
    );
    let kept = query(connection.as_ref(), "SELECT name, mail FROM kept WHERE id = 1").await;
    assert_eq!(
        kept.rows,
        [vec![Value::Text("a@x".to_owned()), Value::Text("Ann".to_owned())]]
    );
    connection.close().await.unwrap();
}
