//! What the catalogue says, and SQL the dialect builds against it.

use tablepro_core::column::{ColumnKind, TemporalZone, TextLength};
use tablepro_core::meta::{IndexKey, ObjectKind, ObjectScope, RowCountEstimate, RowIdentity};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{Connection, FilterOp, FilterRule, FilterSet, FilterValue, RowLimit, Value, build_filter};

use crate::support::{CALL, DATABASE, connect, quoted, setup, start, table, unique, within};

async fn matching(connection: &dyn Connection, name: &str, rule: FilterRule) -> Vec<String> {
    let table = table(name);
    let columns = connection
        .fetch_columns(&table, within(CALL))
        .await
        .expect("the columns");
    let dialect = connection.dialect();
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("SELECT v FROM {} WHERE ", dialect.qualify(&table)));
    let filter = FilterSet {
        rules: vec![rule],
        ..FilterSet::default()
    };
    build_filter(&mut builder, dialect.as_ref(), &columns, &filter).expect("a filter");
    builder.push_sql(" ORDER BY v");
    let result = connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("a filtered read");
    result
        .rows
        .into_iter()
        .map(|row| match &row[0] {
            Value::Text(text) => text.clone(),
            other => format!("{other:?}"),
        })
        .collect()
}

fn rule(op: FilterOp, value: &str) -> FilterRule {
    FilterRule {
        column: "v".to_owned(),
        op,
        value: Some(FilterValue::Single(value.to_owned())),
    }
}

#[tokio::test]
#[ignore = "requires docker"]
async fn catalog_classifies_datetime64_decimal76() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("catalog");
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {} (id UInt64, ts DateTime64(3, 'UTC'), d Decimal(76, 20), \
             s LowCardinality(Nullable(String)), m Map(String, UInt8)) ENGINE = MergeTree ORDER BY id",
            quoted(&name)
        )],
    )
    .await;

    let columns = connection
        .fetch_columns(&table(&name), within(CALL))
        .await
        .expect("the columns");

    let kinds: Vec<&ColumnKind> = columns.iter().map(|column| &column.column_type.kind).collect();
    assert_eq!(
        kinds[1],
        &ColumnKind::Timestamp {
            fractional_digits: Some(3),
            zone: TemporalZone::Named("UTC".to_owned())
        }
    );
    assert_eq!(
        kinds[2],
        &ColumnKind::Decimal {
            precision: Some(76),
            scale: Some(20)
        }
    );
    assert_eq!(
        kinds[3],
        &ColumnKind::Text {
            length: TextLength::Unbounded
        }
    );
    assert!(columns[3].nullable && !columns[1].nullable);
    assert_eq!(kinds[4], &ColumnKind::Composite);
    assert!(columns[0].primary_key);
    connection.close().await.expect("a close");
}

/// The server refuses an UPDATE of any sorting or partition key column,
/// so the grid locks and keys rows by all of them, past the PRIMARY KEY.
#[tokio::test]
#[ignore = "requires docker"]
async fn every_sorting_and_partition_key_column_keys_the_grid() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("keyed");
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {} (region String, a Int32, b Int32, v String) ENGINE = MergeTree \
             PARTITION BY region ORDER BY (a, b) PRIMARY KEY a",
            quoted(&name)
        )],
    )
    .await;

    let columns = connection
        .fetch_columns(&table(&name), within(CALL))
        .await
        .expect("the columns");
    let definition = connection
        .fetch_table_definition(&table(&name), within(CALL))
        .await
        .expect("the definition");

    let keyed: Vec<(&str, bool)> = columns
        .iter()
        .map(|column| (column.name.as_str(), column.primary_key))
        .collect();
    assert_eq!(keyed, [("region", true), ("a", true), ("b", true), ("v", false)]);
    assert_eq!(
        definition.primary_key.map(|key| key.columns),
        Some(vec!["a".to_owned()])
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn fetch_table_definition_reports_keys_comment_and_source() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("definition");
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {} (d Date, id UInt32 COMMENT 'the row', s String MATERIALIZED toString(id), \
             INDEX by_s s TYPE bloom_filter GRANULARITY 1) \
             ENGINE = MergeTree PARTITION BY toYYYYMM(d) ORDER BY (toYYYYMM(d), id)",
            quoted(&name)
        )],
    )
    .await;

    let definition = connection
        .fetch_table_definition(&table(&name), within(CALL))
        .await
        .expect("the definition");
    let identity = connection
        .row_identity(&table(&name), within(CALL))
        .await
        .expect("the identity");
    let estimate = connection
        .table_estimate(&table(&name), within(CALL))
        .await
        .expect("an estimate");

    let id = definition.column("id").expect("the id column");
    assert_eq!(id.info.comment.as_deref(), Some("the row"));
    assert!(id.attributes.key_roles.sorting_key && !id.attributes.key_roles.partition_key);
    let d = definition.column("d").expect("the date column");
    assert!(d.attributes.key_roles.sorting_key && d.attributes.key_roles.partition_key);
    assert!(definition.column("s").is_some_and(|s| s.info.is_generated));
    assert_eq!(
        definition.primary_key.as_ref().map(|key| key.columns.clone()),
        Some(vec!["d".to_owned(), "id".to_owned()])
    );
    let sorting = &definition.indexes[0];
    assert!(sorting.primary && !sorting.unique);
    assert_eq!(
        sorting.keys,
        vec![
            IndexKey::Expression {
                sql: "toYYYYMM(d)".to_owned(),
                descending: false
            },
            IndexKey::Column {
                name: "id".to_owned(),
                descending: false
            }
        ]
    );
    assert!(definition.indexes.iter().any(|index| index.name == "by_s"));
    assert!(
        definition
            .source
            .as_ref()
            .is_some_and(|source| source.create_statement.starts_with("CREATE TABLE"))
    );
    assert_eq!(
        identity,
        RowIdentity::SortingKey {
            expressions: vec!["d".to_owned(), "id".to_owned()]
        }
    );
    assert_eq!(estimate.rows, RowCountEstimate::Exact(0));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn objects_and_schemas_are_listed_by_kind() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let base = unique("base");
    let view = unique("view");
    let function = unique("fn");
    setup(
        connection.as_ref(),
        &[
            &format!(
                "CREATE TABLE {} (id UInt64) ENGINE = MergeTree ORDER BY id",
                quoted(&base)
            ),
            &format!("CREATE VIEW {} AS SELECT id FROM {}", quoted(&view), quoted(&base)),
            &format!("CREATE FUNCTION {function} AS (x) -> x + 1"),
        ],
    )
    .await;

    let objects = connection
        .list_objects(&ObjectScope::DefaultSchema, within(CALL))
        .await
        .expect("the objects");
    let schemas = connection.list_schemas(within(CALL)).await.expect("the schemas");

    let kind_of = |name: &str| {
        objects
            .iter()
            .find(|object| object.name == name)
            .map(|object| object.kind)
    };
    assert_eq!(kind_of(&base), Some(ObjectKind::Table));
    assert_eq!(kind_of(&view), Some(ObjectKind::View));
    assert_eq!(kind_of(&function), Some(ObjectKind::Function));
    assert!(
        schemas
            .iter()
            .any(|schema| schema.name == DATABASE && schema.is_default)
    );
    assert!(schemas.iter().any(|schema| schema.name == "system" && schema.is_system));
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn like_escape_matches_literal_underscore_and_percent() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("like");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (v String) ENGINE = MergeTree ORDER BY v"),
            &format!("INSERT INTO {qualified} VALUES ('user_id'), ('userXid'), ('50%'), ('500')"),
        ],
    )
    .await;

    assert_eq!(
        matching(connection.as_ref(), &name, rule(FilterOp::Contains, "user_id")).await,
        ["user_id"]
    );
    assert_eq!(
        matching(connection.as_ref(), &name, rule(FilterOp::Contains, "50%")).await,
        ["50%"]
    );
    connection.close().await.expect("a close");
}

#[tokio::test]
#[ignore = "requires docker"]
async fn clickhouse_ilike_is_case_insensitive() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("ilike");
    let qualified = quoted(&name);
    setup(
        connection.as_ref(),
        &[
            &format!("CREATE TABLE {qualified} (v String) ENGINE = MergeTree ORDER BY v"),
            &format!("INSERT INTO {qualified} VALUES ('Alpha'), ('beta')"),
        ],
    )
    .await;

    assert_eq!(
        matching(connection.as_ref(), &name, rule(FilterOp::Ilike, "aLP%")).await,
        ["Alpha"]
    );
    connection.close().await.expect("a close");
}

/// A skipping index's statement, run after the index is dropped, makes
/// the same index again with its type and granularity. The sorting key
/// has no statement of its own.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn skipping_index_statements_recreate_their_indexes() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    let name = unique("skipping");
    setup(
        connection.as_ref(),
        &[&format!(
            "CREATE TABLE {} (id UInt32, s String, \
             INDEX by_s lower(s) TYPE bloom_filter(0.01) GRANULARITY 4, INDEX by_id id TYPE minmax GRANULARITY 1) \
             ENGINE = MergeTree ORDER BY id",
            quoted(&name)
        )],
    )
    .await;
    let table = table(&name);
    let indexes = connection
        .fetch_indexes(&table, within(CALL))
        .await
        .expect("the indexes");

    assert!(
        indexes
            .iter()
            .filter(|index| index.primary)
            .all(|index| index.definition.is_none()),
        "{indexes:#?}"
    );
    let by_s = indexes.iter().find(|index| index.name == "by_s").expect("by_s");
    assert_eq!(
        by_s.definition.as_deref(),
        Some(
            format!(
                "ALTER TABLE `{DATABASE}`.`{name}` ADD INDEX `by_s` lower(s) TYPE bloom_filter(0.01) GRANULARITY 4"
            )
            .as_str()
        )
    );
    for index in indexes.iter().filter(|index| !index.primary) {
        let statement = index.definition.clone().expect("a statement");
        let drop = format!("ALTER TABLE {} DROP INDEX `{}`", quoted(&name), index.name);
        setup(connection.as_ref(), &[drop.as_str(), statement.as_str()]).await;
        let remade = connection
            .fetch_indexes(&table, within(CALL))
            .await
            .expect("the indexes");
        assert_eq!(
            remade.iter().find(|remade| remade.name == index.name),
            Some(index),
            "{statement}"
        );
    }
    connection.close().await.expect("a close");
}
