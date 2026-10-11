#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_core::sql_ddl::{DraftColumn, StructureOp, diff_to_ops, materialize_ops};
use tablepro_core::{ColumnInfo, Connection, ForeignKeyInfo, IndexInfo, Value};
use tablepro_release_tests::Fixture;

const PARENT: &str = "ddl_parent";
const CHILD: &str = "ddl_child";

fn draft(name: &str, data_type: &str, nullable: bool, primary_key: bool) -> DraftColumn {
    DraftColumn {
        original: None,
        name: name.into(),
        data_type: data_type.into(),
        nullable,
        primary_key,
        auto_increment: false,
        default_value: None,
        comment: None,
        collation: None,
    }
}

async fn apply(connection: &dyn Connection, ops: &[StructureOp]) {
    let statements = materialize_ops(ops, "postgres").expect("materialize the structure ops");
    assert!(!statements.is_empty(), "ops must produce at least one statement");
    let batch: Vec<(String, Vec<Value>)> = statements.into_iter().map(|sql| (sql, Vec::new())).collect();
    connection
        .execute_in_transaction(&batch)
        .await
        .unwrap_or_else(|e| panic!("ddl batch failed: {e}\n{batch:?}"));
}

async fn reset(connection: &dyn Connection) {
    for table in [CHILD, PARENT, "ddl_parent_renamed"] {
        connection
            .execute(&format!("DROP TABLE IF EXISTS {table} CASCADE"))
            .await
            .expect("drop any earlier fixture table");
    }
}

fn column<'a>(columns: &'a [ColumnInfo], name: &str) -> &'a ColumnInfo {
    columns
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| panic!("column {name} missing from {columns:?}"))
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_created_table_matches_the_drafted_columns_indexes_and_keys() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![
                draft("id", "integer", false, true),
                draft("label", "text", false, false),
            ],
            indexes: vec![IndexInfo {
                name: "ddl_parent_label_key".into(),
                columns: vec!["label".into()],
                unique: true,
                primary: false,
                predicate: None,
            }],
            fks: vec![],
        }],
    )
    .await;

    let columns = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    assert_eq!(columns.len(), 2);
    assert!(column(&columns, "id").primary_key, "id must be the primary key");
    assert!(!column(&columns, "label").nullable, "label was drafted NOT NULL");

    let indexes = connection.fetch_indexes(None, PARENT).await.expect("fetch indexes");
    let unique = indexes
        .iter()
        .find(|i| i.name == "ddl_parent_label_key")
        .expect("the drafted unique index must exist");
    assert!(unique.unique);
    assert_eq!(unique.columns, vec!["label".to_string()]);

    connection
        .execute(&format!("INSERT INTO {PARENT} (id, label) VALUES (1, 'one')"))
        .await
        .expect("insert into the created table");
    let duplicate = connection
        .execute(&format!("INSERT INTO {PARENT} (id, label) VALUES (2, 'one')"))
        .await;
    assert!(duplicate.is_err(), "the unique index must reject a duplicate label");
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_drafted_foreign_key_is_created_and_enforced() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![draft("id", "integer", false, true)],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;
    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: CHILD.into(),
            columns: vec![
                draft("id", "integer", false, true),
                draft("parent_id", "integer", true, false),
            ],
            indexes: vec![],
            fks: vec![ForeignKeyInfo {
                name: "ddl_child_parent_fk".into(),
                columns: vec!["parent_id".into()],
                ref_schema: None,
                ref_table: PARENT.into(),
                ref_columns: vec!["id".into()],
                on_delete: Some("CASCADE".into()),
                on_update: Some("RESTRICT".into()),
            }],
        }],
    )
    .await;

    let fks = connection.fetch_foreign_keys(None, CHILD).await.expect("fetch keys");
    let fk = fks
        .iter()
        .find(|f| f.name == "ddl_child_parent_fk")
        .expect("the drafted foreign key must exist");
    assert_eq!(fk.columns, vec!["parent_id".to_string()]);
    assert_eq!(fk.ref_table, PARENT);
    assert_eq!(fk.ref_columns, vec!["id".to_string()]);
    assert_eq!(fk.on_delete.as_deref(), Some("CASCADE"), "actual fk: {fk:?}");

    let orphan = connection
        .execute(&format!("INSERT INTO {CHILD} (id, parent_id) VALUES (1, 99)"))
        .await;
    assert!(orphan.is_err(), "the foreign key must reject an unknown parent");

    connection
        .execute(&format!("INSERT INTO {PARENT} (id) VALUES (1)"))
        .await
        .expect("insert a parent row");
    connection
        .execute(&format!("INSERT INTO {CHILD} (id, parent_id) VALUES (1, 1)"))
        .await
        .expect("insert a child row");
    connection
        .execute(&format!("DELETE FROM {PARENT} WHERE id = 1"))
        .await
        .expect("delete the parent row");
    let remaining = connection
        .query(&format!("SELECT count(*) FROM {CHILD}"))
        .await
        .expect("count child rows");
    assert_eq!(
        remaining.rows[0].first(),
        Some(&Value::Int(0)),
        "ON DELETE CASCADE must remove the child row"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn an_edited_draft_applies_the_diffed_column_changes() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![
                draft("id", "integer", false, true),
                draft("label", "text", true, false),
                draft("scratch", "text", true, false),
            ],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;

    let original_columns = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    let mut drafts: Vec<DraftColumn> = original_columns
        .iter()
        .filter(|c| c.name != "scratch")
        .cloned()
        .map(DraftColumn::from_info)
        .collect();
    for column in &mut drafts {
        if column.name == "label" {
            column.name = "title".into();
            column.nullable = false;
            column.default_value = Some("'untitled'".into());
        }
    }
    drafts.push(draft("amount", "integer", true, false));

    let ops = diff_to_ops(None, PARENT, PARENT, &original_columns, &drafts, &[], &[], &[], &[]);
    assert!(!ops.is_empty(), "the diff must produce operations");
    apply(connection.as_ref(), &ops).await;

    let updated = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    let names: Vec<&str> = updated.iter().map(|c| c.name.as_str()).collect();
    assert!(names.contains(&"title"), "label must be renamed to title: {names:?}");
    assert!(!names.contains(&"label"));
    assert!(!names.contains(&"scratch"), "scratch must be dropped: {names:?}");
    assert!(names.contains(&"amount"), "amount must be added: {names:?}");
    assert!(!column(&updated, "title").nullable, "title must become NOT NULL");

    connection
        .execute(&format!("INSERT INTO {PARENT} (id) VALUES (7)"))
        .await
        .expect("insert relying on the new default");
    let stored = connection
        .query(&format!("SELECT title FROM {PARENT} WHERE id = 7"))
        .await
        .expect("read the defaulted value");
    assert_eq!(stored.rows[0].first(), Some(&Value::Text("untitled".into())));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_renamed_table_keeps_its_rows() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![draft("id", "integer", false, true)],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;
    connection
        .execute(&format!("INSERT INTO {PARENT} (id) VALUES (1), (2)"))
        .await
        .expect("seed rows");

    apply(
        connection.as_ref(),
        &[StructureOp::RenameTable {
            schema: None,
            old_name: PARENT.into(),
            new_name: "ddl_parent_renamed".into(),
        }],
    )
    .await;

    let rows = connection
        .query("SELECT count(*) FROM ddl_parent_renamed")
        .await
        .expect("the renamed table must carry its rows");
    assert_eq!(rows.rows[0].first(), Some(&Value::Int(2)));

    let tables = connection.list_tables().await.expect("list tables");
    assert!(tables.iter().any(|t| t.name == "ddl_parent_renamed"));
    assert!(!tables.iter().any(|t| t.name == PARENT));
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_failed_statement_rolls_back_the_whole_ddl_batch() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![draft("id", "integer", false, true)],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;

    let batch = vec![
        (format!("ALTER TABLE {PARENT} ADD COLUMN good integer"), Vec::new()),
        (format!("ALTER TABLE {PARENT} ADD COLUMN bad no_such_type"), Vec::new()),
    ];
    let result = connection.execute_in_transaction(&batch).await;
    assert!(result.is_err(), "the invalid type must fail the batch");

    let columns = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    let names: Vec<&str> = columns.iter().map(|c| c.name.as_str()).collect();
    assert!(
        !names.contains(&"good"),
        "the first statement must roll back with the batch: {names:?}"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn structure_batches_do_not_commit_or_rollback_an_editor_transaction() {
    let connection = Fixture::from_env().connect_verified().await;
    connection
        .execute("DROP TABLE IF EXISTS ddl_editor_isolation")
        .await
        .unwrap();
    connection
        .execute("DROP TABLE IF EXISTS ddl_isolated_structure")
        .await
        .unwrap();
    connection
        .execute("CREATE TABLE ddl_editor_isolation (id integer PRIMARY KEY)")
        .await
        .unwrap();
    let mut editor = connection.begin().await.unwrap();
    editor
        .execute("INSERT INTO ddl_editor_isolation VALUES (1)")
        .await
        .unwrap();
    connection
        .execute_in_transaction(&[("CREATE TABLE ddl_isolated_structure (id integer)".into(), vec![])])
        .await
        .unwrap();
    // The structure commit must not commit the editor's write.
    assert_eq!(
        connection
            .query("SELECT count(*) FROM ddl_editor_isolation")
            .await
            .unwrap()
            .rows[0][0],
        Value::Int(0)
    );
    assert!(
        connection
            .execute_in_transaction(&[("SELECT * FROM no_such_ddl_fixture_table".into(), vec![])])
            .await
            .is_err()
    );
    // A failing structure batch must not roll back the editor either.
    assert_eq!(
        editor
            .query("SELECT count(*) FROM ddl_editor_isolation")
            .await
            .unwrap()
            .rows[0][0],
        Value::Int(1)
    );
    editor.rollback().await.unwrap();
    assert_eq!(
        connection
            .query("SELECT count(*) FROM ddl_editor_isolation")
            .await
            .unwrap()
            .rows[0][0],
        Value::Int(0)
    );
    connection
        .execute("DROP TABLE ddl_isolated_structure, ddl_editor_isolation")
        .await
        .unwrap();
}

fn commented(name: &str, data_type: &str, comment: &str) -> DraftColumn {
    DraftColumn {
        comment: Some(comment.into()),
        ..draft(name, data_type, true, false)
    }
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn column_comments_are_created_added_edited_and_cleared() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![
                draft("id", "integer", false, true),
                commented("label", "text", "what the row is called"),
                commented("scratch", "text", "temporary"),
            ],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;

    let created = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    assert_eq!(
        column(&created, "label").comment.as_deref(),
        Some("what the row is called"),
        "a created column keeps its comment"
    );
    assert_eq!(column(&created, "id").comment, None);

    let mut drafts: Vec<DraftColumn> = created.iter().cloned().map(DraftColumn::from_info).collect();
    for column in &mut drafts {
        if column.name == "label" {
            column.comment = Some("renamed and re-commented".into());
        }
        if column.name == "scratch" {
            column.comment = None;
        }
    }
    drafts.push(commented("amount", "integer", "how much"));

    let ops = diff_to_ops(None, PARENT, PARENT, &created, &drafts, &[], &[], &[], &[]);
    apply(connection.as_ref(), &ops).await;

    let updated = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    assert_eq!(
        column(&updated, "label").comment.as_deref(),
        Some("renamed and re-commented"),
        "an edited comment is applied"
    );
    assert_eq!(
        column(&updated, "scratch").comment,
        None,
        "a cleared comment is removed, not stored as an empty string"
    );
    assert_eq!(
        column(&updated, "amount").comment.as_deref(),
        Some("how much"),
        "an added column keeps its comment"
    );
}

#[tokio::test]
#[ignore = "requires the postgres release fixture"]
async fn a_renamed_column_keeps_a_comment_edited_in_the_same_save() {
    let fixture = Fixture::from_env();
    let connection = fixture.connect_verified().await;
    reset(connection.as_ref()).await;

    apply(
        connection.as_ref(),
        &[StructureOp::CreateTable {
            schema: None,
            table: PARENT.into(),
            columns: vec![
                draft("id", "integer", false, true),
                commented("label", "text", "the old note"),
            ],
            indexes: vec![],
            fks: vec![],
        }],
    )
    .await;

    let original = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    let mut drafts: Vec<DraftColumn> = original.iter().cloned().map(DraftColumn::from_info).collect();
    for column in &mut drafts {
        if column.name == "label" {
            column.name = "title".into();
            column.comment = Some("the new note".into());
        }
    }

    let ops = diff_to_ops(None, PARENT, PARENT, &original, &drafts, &[], &[], &[], &[]);
    apply(connection.as_ref(), &ops).await;

    let updated = connection.fetch_columns(None, PARENT).await.expect("fetch columns");
    assert!(updated.iter().all(|c| c.name != "label"));
    assert_eq!(
        column(&updated, "title").comment.as_deref(),
        Some("the new note"),
        "the comment statement must address the post-rename name"
    );
}
