//! The catalogue as the structure tab and the filters read it.

use tablepro_core::column::{BoolStorage, ColumnKind, IntegerKind, IntegerWidth};
use tablepro_core::ddl::{ColumnVisibility, GeneratedStorage, IdentityStyle};
use tablepro_core::dialect::{BindTarget, LikeForm, SqlDialect};
use tablepro_core::meta::{ObjectKind, ObjectScope};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{Connection, RowLimit, Value};
use tablepro_test_fixtures::MysqlFlavour;

use crate::support::{CALL, FLAVOURS, connect, rows, setup, start, table, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn catalog_classifies_unsigned_zerofill_year_bit_enum() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE kinds (z int(10) unsigned zerofill, d decimal(10,2) unsigned, y year, b bit(10), \
                 e enum('it''s','a\\\\b'), f tinyint(1))",
                "INSERT INTO kinds (e) VALUES ('it''s'), ('a\\\\b')",
            ],
        )
        .await;

        let columns = connection
            .fetch_columns(&table("kinds"), within(CALL))
            .await
            .expect("the columns");

        let kinds: Vec<&ColumnKind> = columns.iter().map(|column| &column.column_type.kind).collect();
        assert_eq!(
            kinds[0],
            &ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: false
            }),
            "{flavour:?}"
        );
        assert_eq!(
            kinds[1],
            &ColumnKind::Decimal {
                precision: Some(10),
                scale: Some(2)
            }
        );
        assert_eq!(
            kinds[2],
            &ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W16,
                signed: false
            })
        );
        assert_eq!(
            kinds[3],
            &ColumnKind::BitString {
                length: Some(10),
                varying: false
            }
        );
        let labels = vec!["it's".to_owned(), r"a\b".to_owned()];
        assert_eq!(
            kinds[4],
            &ColumnKind::Enum {
                labels: labels.clone(),
                multiple: false
            },
            "{flavour:?}"
        );
        assert_eq!(kinds[5], &ColumnKind::Bool(BoolStorage::Integer));
        let read: Vec<Value> = rows(connection.as_ref(), "SELECT e FROM kinds ORDER BY e")
            .await
            .into_iter()
            .map(|mut row| row.remove(0))
            .collect();
        assert_eq!(read, labels.into_iter().map(Value::Text).collect::<Vec<_>>());
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn fetch_table_definition_reports_pk_name_collation_comment() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &["CREATE TABLE described (\
                 id int AUTO_INCREMENT PRIMARY KEY, \
                 name varchar(20) COLLATE utf8mb4_bin COMMENT 'shown name', \
                 changed timestamp(3) NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3), \
                 base int, \
                 doubled int GENERATED ALWAYS AS (base * 2) STORED, \
                 hidden int INVISIBLE)"],
        )
        .await;

        let definition = connection
            .fetch_table_definition(&table("described"), within(CALL))
            .await
            .expect("the definition");

        let primary = definition.primary_key.as_ref().expect("a primary key");
        assert_eq!(primary.name.as_deref(), Some("PRIMARY"));
        assert_eq!(primary.columns, ["id"]);
        let id = definition.column("id").expect("id");
        assert_eq!(id.attributes.identity, IdentityStyle::AutoIncrementKeyword);
        let name = definition.column("name").expect("name");
        assert_eq!(
            name.attributes
                .collation
                .as_ref()
                .map(|collation| collation.name.as_str()),
            Some("utf8mb4_bin")
        );
        assert_eq!(name.attributes.character_set.as_deref(), Some("utf8mb4"));
        assert_eq!(name.info.comment.as_deref(), Some("shown name"));
        let changed = definition.column("changed").expect("changed");
        assert!(
            changed
                .attributes
                .on_update
                .as_ref()
                .is_some_and(|expression| expression
                    .as_sql()
                    .to_ascii_lowercase()
                    .starts_with("current_timestamp")),
            "{flavour:?}: {:?}",
            changed.attributes.on_update
        );
        let doubled = definition.column("doubled").expect("doubled");
        assert_eq!(
            doubled.attributes.generated.as_ref().map(|generated| generated.storage),
            Some(GeneratedStorage::Stored)
        );
        assert!(doubled.info.is_generated);
        let hidden = definition.column("hidden").expect("hidden");
        assert_eq!(hidden.attributes.visibility, ColumnVisibility::Invisible, "{flavour:?}");
        let source = definition.source.as_ref().expect("the table's source");
        assert!(
            source.create_statement.starts_with("CREATE TABLE `described`"),
            "{flavour:?}"
        );
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn fetch_table_definition_lists_inbound_foreign_keys() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE parent (id int, rev int, PRIMARY KEY (id, rev))",
                "CREATE TABLE child (id int PRIMARY KEY, parent_id int, parent_rev int, \
                 CONSTRAINT child_parent FOREIGN KEY (parent_id, parent_rev) REFERENCES parent (id, rev) \
                 ON DELETE CASCADE)",
            ],
        )
        .await;

        let parent = connection
            .fetch_table_definition(&table("parent"), within(CALL))
            .await
            .expect("the parent");
        let child = connection
            .fetch_table_definition(&table("child"), within(CALL))
            .await
            .expect("the child");

        let inbound = &parent.inbound_foreign_keys;
        assert_eq!(inbound.len(), 1, "{flavour:?}");
        assert_eq!(inbound[0].name, "child_parent");
        assert_eq!(inbound[0].table.name, "child");
        assert_eq!(inbound[0].columns, ["parent_id", "parent_rev"]);
        assert_eq!(inbound[0].referenced_columns, ["id", "rev"]);
        let outbound = &child.foreign_keys;
        assert_eq!(outbound.len(), 1);
        assert_eq!(outbound[0].ref_table, "parent");
        assert_eq!(
            outbound[0].on_delete,
            Some(tablepro_core::ddl::ReferentialAction::Cascade)
        );
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn objects_and_estimates_are_listed() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = crate::support::connect_root(&fixture).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE listed (id int PRIMARY KEY)",
                "CREATE VIEW listed_view AS SELECT id FROM listed",
                "CREATE PROCEDURE listed_procedure() SELECT 1",
                "CREATE FUNCTION listed_function() RETURNS int DETERMINISTIC RETURN 1",
            ],
        )
        .await;

        let objects = connection
            .list_objects(&ObjectScope::DefaultSchema, within(CALL))
            .await
            .expect("the objects");
        let schemas = connection.list_schemas(within(CALL)).await.expect("the schemas");
        let estimate = connection
            .table_estimate(&table("listed"), within(CALL))
            .await
            .expect("an estimate");

        let kind_of = |name: &str| {
            objects
                .iter()
                .find(|object| object.name == name)
                .map(|object| object.kind)
        };
        assert_eq!(kind_of("listed"), Some(ObjectKind::Table), "{flavour:?}");
        assert_eq!(kind_of("listed_view"), Some(ObjectKind::View));
        assert_eq!(kind_of("listed_procedure"), Some(ObjectKind::Procedure));
        assert_eq!(kind_of("listed_function"), Some(ObjectKind::Function));
        assert_eq!(schemas.len(), 1);
        assert_eq!(schemas[0].name, "tablepro");
        assert!(schemas[0].is_default);
        assert!(estimate.rows.value().is_some(), "{flavour:?}: {estimate:?}");
        connection.close().await.expect("a close");
    }
}

async fn names_matching(
    connection: &dyn Connection,
    dialect: &dyn SqlDialect,
    column: &str,
    pattern: Value,
    form: LikeForm,
) -> Vec<String> {
    let mut builder = StatementBuilder::new();
    let column_sql = dialect.quote_identifier(column);
    builder.push_sql(&format!(
        "SELECT {column_sql} FROM {} WHERE ",
        dialect.qualify(&table("names"))
    ));
    let marker = builder
        .bind(dialect, pattern, BindTarget::Pattern)
        .expect("a pattern parameter");
    builder.push_sql(&dialect.like_predicate(&column_sql, &marker, form));
    builder.push_sql(&format!(" ORDER BY {column_sql}"));
    connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("a filtered read")
        .rows
        .into_iter()
        .map(|row| crate::support::text(&row[0]))
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn like_escape_matches_literal_underscore_and_percent() {
    for flavour in FLAVOURS {
        let fixture = start(flavour).await;
        let connection = connect(&fixture, false).await;
        setup(
            connection.as_ref(),
            &[
                "CREATE TABLE names (name varchar(20))",
                "INSERT INTO names VALUES ('user_id'), ('userXid'), ('50%'), ('500')",
            ],
        )
        .await;
        let dialect = connection.dialect();
        let contains = |text: &str| Value::Text(format!("%{}%", dialect.escape_like_text(text)));

        let underscore = names_matching(
            connection.as_ref(),
            dialect.as_ref(),
            "name",
            contains("user_id"),
            LikeForm::contains(),
        )
        .await;
        let percent = names_matching(
            connection.as_ref(),
            dialect.as_ref(),
            "name",
            contains("50%"),
            LikeForm::contains(),
        )
        .await;

        assert_eq!(underscore, ["user_id"], "{flavour:?}");
        assert_eq!(percent, ["50%"], "{flavour:?}");
        connection.close().await.expect("a close");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn insensitive_filter_matches_mixed_case() {
    let fixture = start(MysqlFlavour::Mysql).await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE names (name varchar(20) COLLATE utf8mb4_bin)",
            "INSERT INTO names VALUES ('Alpha'), ('Beta')",
        ],
    )
    .await;
    let dialect = connection.dialect();

    let sensitive = names_matching(
        connection.as_ref(),
        dialect.as_ref(),
        "name",
        Value::Text("%alp%".to_owned()),
        LikeForm::raw(false),
    )
    .await;
    let insensitive = names_matching(
        connection.as_ref(),
        dialect.as_ref(),
        "name",
        Value::Text("%alp%".to_owned()),
        LikeForm::insensitive(false),
    )
    .await;

    assert!(sensitive.is_empty(), "a _bin collation compares case: {sensitive:?}");
    assert_eq!(insensitive, ["Alpha"]);
    connection.close().await.expect("a close");
}
