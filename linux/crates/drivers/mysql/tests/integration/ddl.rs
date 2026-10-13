//! Structure changes the MySQL dialect plans, run against both servers.

use tablepro_core::column::ColumnDefault;
use tablepro_core::ddl::{
    BuildDdlError, CollationName, ColumnVisibility, DraftColumn, DraftType, GeneratedStorage, Permission,
    RefusalReason, TableDefinition, TableDraft, diff_table,
};
use tablepro_core::{Connection, WriteKind};
use tablepro_test_fixtures::{MysqlFlavour, MysqlOptions};

use crate::support::{CALL, FLAVOURS, apply, connect, scalar, setup, start, start_with, table, text, within};

async fn read(connection: &dyn Connection) -> TableDefinition {
    connection
        .fetch_table_definition(&table("kept"), within(CALL))
        .await
        .expect("the definition")
}

/// Plan the edit against the table as read, run it, and read it again.
async fn change(connection: &dyn Connection, edit: impl Fn(&mut DraftColumn)) -> (TableDefinition, TableDefinition) {
    let before = read(connection).await;
    let mut draft = TableDraft::from_definition(&before);
    draft.columns.iter_mut().for_each(edit);
    let dialect = connection.dialect();
    let plan = dialect
        .ddl()
        .expect("MySQL plans its DDL")
        .plan_alter_table(&before, &diff_table(&before, &draft))
        .expect("the change plans");
    connection
        .write_batch(&plan.into_write_batch(table("kept")), within(CALL))
        .await
        .expect("the change runs");
    let after = read(connection).await;
    (before, after)
}

/// MODIFY replaces the whole definition, so a column comes back as it
/// was in every attribute but the ones the edit changed.
fn assert_kept(before: &TableDefinition, after: &TableDefinition, flavour: MysqlFlavour) {
    assert_eq!(before.columns.len(), after.columns.len(), "{flavour:?}");
    for (old, new) in before.columns.iter().zip(&after.columns) {
        assert_eq!(old.attributes, new.attributes, "{flavour:?}: {}", old.name());
        assert_eq!(
            old.info.column_type,
            new.info.column_type,
            "{flavour:?}: {}",
            old.name()
        );
        assert_eq!(old.info.default, new.info.default, "{flavour:?}: {}", old.name());
        assert_eq!(
            old.info.is_generated,
            new.info.is_generated,
            "{flavour:?}: {}",
            old.name()
        );
    }
}

fn collation(definition: &TableDefinition, column: &str) -> Option<CollationName> {
    definition
        .column(column)
        .and_then(|column| column.attributes.collation.clone())
}

/// The server's global sql_mode has NO_BACKSLASH_ESCAPES, which the
/// workspace session takes off, so the doubled backslash in a restated
/// comment reads back as one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn nullability_change_keeps_comment_on_update_collation_invisible() {
    let fixture = start_with(
        MysqlOptions::new(MysqlFlavour::Mysql)
            .allowing_plaintext()
            .trusting_function_creators()
            .with_server_argument("--sql-mode=NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES"),
    )
    .await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[r#"CREATE TABLE kept (
             id int PRIMARY KEY,
             code varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL COMMENT 'it''s \\ x',
             changed timestamp(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
             hidden int NULL DEFAULT 7 INVISIBLE,
             base int NULL,
             doubled int GENERATED ALWAYS AS (base * 2) STORED,
             label varchar(40) GENERATED ALWAYS AS (concat('it''s ', code)) VIRTUAL,
             doc json NULL DEFAULT ('{"a": "it''s"}'),
             shape point NULL SRID 4326)"#],
    )
    .await;

    let (before, after) = change(connection.as_ref(), |column| {
        if column.name != "id" {
            column.nullable = false;
        }
        if column.name == "hidden" {
            column.comment = Some(r"it's \ x".to_owned());
        }
    })
    .await;

    assert_kept(&before, &after, MysqlFlavour::Mysql);
    assert!(after.columns.iter().all(|column| !column.info.nullable));
    let comment = |name: &str| after.column(name).and_then(|column| column.info.comment.clone());
    assert_eq!(comment("code").as_deref(), Some(r"it's \ x"));
    assert_eq!(comment("hidden").as_deref(), Some(r"it's \ x"));
    assert_eq!(collation(&after, "code"), Some(CollationName::new(None, "utf8mb4_bin")));
    let column = |name: &str| after.column(name).expect("the column");
    assert_eq!(
        column("changed")
            .attributes
            .on_update
            .as_ref()
            .map(|expression| expression.as_sql().to_owned()),
        Some("CURRENT_TIMESTAMP(3)".to_owned())
    );
    assert_eq!(column("hidden").attributes.visibility, ColumnVisibility::Invisible);
    assert_eq!(column("shape").attributes.spatial_reference, Some(4326));
    let label = column("label").attributes.generated.as_ref().expect("still generated");
    assert_eq!(label.storage, GeneratedStorage::Virtual);
    assert_eq!(
        column("doubled")
            .attributes
            .generated
            .as_ref()
            .map(|generated| generated.storage),
        Some(GeneratedStorage::Stored)
    );
    setup(
        connection.as_ref(),
        &["INSERT INTO kept (id, code, base, shape) VALUES (1, 'a', 2, ST_GeomFromText('POINT(1 1)', 4326))"],
    )
    .await;
    assert_eq!(
        text(
            &scalar(
                connection.as_ref(),
                "SELECT concat(label, '|', doubled, '|', doc->>'$.a') FROM kept"
            )
            .await
        ),
        "it's a|4|it's"
    );
    connection.close().await.expect("a close");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn expression_default_uuid_survives_modify() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE kept (id int PRIMARY KEY, token char(36) NULL DEFAULT (uuid()))"],
    )
    .await;

    let (before, after) = change(connection.as_ref(), |column| {
        if column.name == "token" {
            column.nullable = false;
            column.comment = Some("made by the server".to_owned());
        }
    })
    .await;
    setup(connection.as_ref(), &["INSERT INTO kept (id) VALUES (1)"]).await;

    assert_kept(&before, &after, MysqlFlavour::Mysql);
    assert!(matches!(
        &after.column("token").expect("token").info.default,
        ColumnDefault::Expression(expression) if expression.as_sql() == "uuid()"
    ));
    assert_eq!(
        text(&scalar(connection.as_ref(), "SELECT CHAR_LENGTH(token) FROM kept").await),
        "36"
    );
    connection.close().await.expect("a close");
}

/// MariaDB lists its EXTRA words with commas, keeps an SRID and a
/// column's CHECK out of COLUMNS, and takes neither NULL nor NOT NULL on
/// a generated column.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mariadb_restated_columns_keep_every_attribute() {
    let fixture = start(MysqlFlavour::Mariadb).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[r"CREATE TABLE kept (
             id int PRIMARY KEY,
             code varchar(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL COMMENT 'it''s \\ x',
             changed timestamp(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3) INVISIBLE,
             hidden int NULL DEFAULT 7 INVISIBLE,
             base int NULL,
             doubled int GENERATED ALWAYS AS (base * 2) STORED,
             label varchar(40) GENERATED ALWAYS AS (concat('it''s ', code)) VIRTUAL INVISIBLE,
             token char(36) NULL DEFAULT (uuid()),
             doc json NULL,
             bounded int NULL CHECK (bounded > 0),
             shape point REF_SYSTEM_ID=4326 NULL)"],
    )
    .await;

    let (before, after) = change(connection.as_ref(), |column| match column.name.as_str() {
        "id" => {}
        "doubled" | "label" => column.comment = Some(r"it's \ x".to_owned()),
        _ => column.nullable = false,
    })
    .await;

    assert_kept(&before, &after, MysqlFlavour::Mariadb);
    let column = |name: &str| after.column(name).expect("the column");
    assert!(!column("code").info.nullable);
    assert_eq!(column("code").info.comment.as_deref(), Some(r"it's \ x"));
    assert_eq!(column("label").info.comment.as_deref(), Some(r"it's \ x"));
    assert_eq!(collation(&after, "code"), Some(CollationName::new(None, "utf8mb4_bin")));
    assert_eq!(column("changed").attributes.visibility, ColumnVisibility::Invisible);
    assert!(column("changed").attributes.on_update.is_some());
    assert_eq!(column("label").attributes.visibility, ColumnVisibility::Invisible);
    assert_eq!(column("shape").attributes.spatial_reference, Some(4326));
    assert!(
        column("doc")
            .attributes
            .check
            .as_ref()
            .is_some_and(|check| check.as_sql().contains("json_valid"))
    );
    assert!(column("bounded").attributes.check.is_some());
    setup(
        connection.as_ref(),
        &["INSERT INTO kept (id, code, base, doc, bounded, shape) VALUES (1, 'a', 2, '{}', 1, ST_PointFromText('POINT(1 1)', 4326))"],
    )
    .await;
    assert!(
        apply(
            connection.as_ref(),
            WriteKind::RowChanges,
            &["INSERT INTO kept (id, code, base, doc, bounded, shape) VALUES (2, 'b', 2, 'not json', 1, ST_PointFromText('POINT(1 1)', 4326))"],
        )
        .await
        .is_err(),
        "the json_valid check is gone"
    );
    assert_eq!(
        text(&scalar(connection.as_ref(), "SELECT concat(label, '|', doubled) FROM kept").await),
        "it's a|4"
    );
    connection.close().await.expect("a close");
}

/// MariaDB keeps a column CHECK's constraint name from when it was
/// written, through a rename, so the check is found where SHOW CREATE
/// TABLE prints it. Renaming and restating in one ALTER would splice the
/// check with the old name, so that is refused before anything runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn mariadb_check_follows_its_column_through_a_rename() {
    let fixture = start(MysqlFlavour::Mariadb).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &["CREATE TABLE kept (id int PRIMARY KEY, doc json NULL, web point REF_SYSTEM_ID=102100 NULL)"],
    )
    .await;
    let dialect = connection.dialect();
    let ddl = dialect.ddl().expect("MySQL plans its DDL");
    let original = read(connection.as_ref()).await;
    let mut draft = TableDraft::from_definition(&original);
    for column in &mut draft.columns {
        if column.name == "doc" {
            column.name = "body".to_owned();
            column.comment = Some("x".to_owned());
        }
    }

    let both = ddl.plan_alter_table(&original, &diff_table(&original, &draft));
    let (_, renamed) = change(connection.as_ref(), |column| {
        if column.name == "doc" {
            column.name = "body".to_owned();
        }
    })
    .await;
    let (before, after) = change(connection.as_ref(), |column| {
        if column.name == "body" {
            column.comment = Some("x".to_owned());
        }
    })
    .await;

    assert!(
        matches!(
            &both,
            Err(BuildDdlError::Refused { reason: RefusalReason::NamesRenamedColumn(name), .. }) if name == "doc"
        ),
        "{both:?}"
    );
    let check = |definition: &TableDefinition| {
        definition
            .column("body")
            .and_then(|column| column.attributes.check.as_ref())
            .map(|check| check.as_sql().to_owned())
    };
    assert_eq!(check(&renamed).as_deref(), Some("json_valid(`body`)"));
    assert_kept(&before, &after, MysqlFlavour::Mariadb);
    assert_eq!(check(&after).as_deref(), Some("json_valid(`body`)"));
    assert!(
        apply(
            connection.as_ref(),
            WriteKind::RowChanges,
            &["INSERT INTO kept (id, body) VALUES (1, 'not json')"],
        )
        .await
        .is_err(),
        "the json_valid check is gone"
    );
    setup(connection.as_ref(), &["ALTER TABLE kept ADD COLUMN doc int NULL"]).await;
    let added = read(connection.as_ref()).await;
    let doc = added.column("doc").expect("doc");
    assert_eq!(doc.attributes.check, None);
    assert!(doc.attributes.unmodeled.is_empty());
    let web = added.column("web").expect("web");
    assert_eq!(web.attributes.spatial_reference, None);
    assert_eq!(
        ddl.column_capabilities(&added, web).alter_nullability,
        Permission::Refused(RefusalReason::UnmodeledAttribute("REF_SYSTEM_ID".to_owned()))
    );
    connection.close().await.expect("a close");
}

fn type_of(definition: &TableDefinition, column: &str) -> String {
    definition
        .column(column)
        .map(|column| column.info.column_type.name.clone())
        .unwrap_or_default()
}

fn names(definition: &TableDefinition) -> Vec<&str> {
    definition.columns.iter().map(|column| column.name()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn rename_and_retype_column_applies() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (id int PRIMARY KEY, code varchar(10) NULL COMMENT 'sku', qty smallint NULL)",
            "INSERT INTO kept VALUES (1, 'a', 5)",
        ],
    )
    .await;

    let (_, after) = change(connection.as_ref(), |column| match column.name.as_str() {
        "code" => {
            column.name = "label".to_owned();
            column.column_type = DraftType::Typed("varchar(40)".to_owned());
        }
        "qty" => column.name = "amount".to_owned(),
        _ => {}
    })
    .await;

    assert_eq!(names(&after), ["id", "label", "amount"]);
    assert_eq!(type_of(&after, "label"), "varchar(40)");
    assert_eq!(type_of(&after, "amount"), "smallint");
    assert_eq!(
        after
            .column("label")
            .and_then(|column| column.info.comment.clone())
            .as_deref(),
        Some("sku")
    );
    assert_eq!(
        text(&scalar(connection.as_ref(), "SELECT concat(label, '|', amount) FROM kept").await),
        "a|5"
    );
    connection.close().await.expect("a close");
}

/// Every clause of one ALTER names columns as the table had them, so a
/// swap and a cycle of renames need no temporary name, on either server.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn swap_column_names_applies() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE kept (id int PRIMARY KEY, a varchar(10) NULL, b int NULL, c date NULL, KEY by_a (a))",
                "INSERT INTO kept VALUES (1, 'x', 2, '2026-10-14')",
            ],
        )
        .await;

        let (_, after) = change(connection.as_ref(), |column| {
            let renamed = match column.name.as_str() {
                "a" => "b",
                "b" => "c",
                "c" => "a",
                _ => return,
            };
            column.name = renamed.to_owned();
            if renamed == "c" {
                column.nullable = false;
            }
        })
        .await;

        assert_eq!(names(&after), ["id", "b", "c", "a"], "{flavour:?}");
        assert!(type_of(&after, "b").starts_with("varchar"), "{flavour:?}");
        assert!(type_of(&after, "c").starts_with("int"), "{flavour:?}");
        assert_eq!(type_of(&after, "a"), "date", "{flavour:?}");
        assert!(!after.column("c").expect("c").info.nullable, "{flavour:?}");
        assert_eq!(
            text(&scalar(connection.as_ref(), "SELECT concat(b, '|', c, '|', a) FROM kept").await),
            "x|2|2026-10-14",
            "{flavour:?}"
        );
        let indexed = scalar(
            connection.as_ref(),
            "SELECT column_name FROM information_schema.statistics WHERE table_schema = DATABASE() AND \
             table_name = 'kept' AND index_name = 'by_a'",
        )
        .await;
        assert_eq!(text(&indexed), "b", "{flavour:?}");
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn change_primary_key_to_composite_applies() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE kept (order_id int PRIMARY KEY, line int NULL, sku varchar(10) NULL)",
            "INSERT INTO kept VALUES (1, 1, 'a'), (2, 1, 'b')",
        ],
    )
    .await;

    let (_, after) = change(connection.as_ref(), |column| {
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
