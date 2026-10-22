//! Filters on an xml column, which takes neither LIKE nor `=`, and on
//! decimals, whose parameters are cast to one type.

use tablepro_core::filter::{FilterOp, FilterRule, FilterSet, FilterValue, build_filter};
use tablepro_core::statement::StatementBuilder;
use tablepro_core::{RowLimit, Value};

use crate::support::{CALL, columns, connect, dbo, setup, start, within};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn contains_and_equals_on_xml() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.docs (id int PRIMARY KEY, body xml)",
            "INSERT INTO dbo.docs VALUES (1, N'<a>red</a>'), (2, N'<a>blue</a>')",
        ],
    )
    .await;
    let table = dbo("docs");
    let columns = columns(connection.as_ref(), &table).await;
    let dialect = connection.dialect();

    for (op, text) in [(FilterOp::Contains, "red"), (FilterOp::Eq, "<a>red</a>")] {
        let mut builder = StatementBuilder::new();
        builder.push_sql(&format!("SELECT id FROM {} WHERE ", dialect.qualify(&table)));
        let filter = FilterSet {
            rules: vec![FilterRule {
                column: "body".to_owned(),
                op,
                value: Some(FilterValue::Single(text.to_owned())),
            }],
            ..FilterSet::default()
        };
        build_filter(&mut builder, dialect.as_ref(), &columns, &filter).expect("a filter");

        let rows = connection
            .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .expect("the filtered rows")
            .rows;

        assert_eq!(rows, vec![vec![Value::Int(1)]], "{op:?}");
    }
}

/// A decimal parameter is cast so the rows of an import share a type.
/// A filter value with more integer digits or a finer scale than the
/// column still compares as written.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn a_decimal_filter_keeps_the_digits_it_was_given() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.fractions (id int PRIMARY KEY, v decimal(38, 38), price decimal(10, 2))",
            "INSERT INTO dbo.fractions VALUES (1, 0.5, 1.00), (2, 0.25, 1.01)",
        ],
    )
    .await;
    let table = dbo("fractions");
    let columns = columns(connection.as_ref(), &table).await;
    let dialect = connection.dialect();

    for (column, op, text, expected) in [
        ("v", FilterOp::Lt, "1", vec![1, 2]),
        ("price", FilterOp::Gt, "1.005", vec![2]),
    ] {
        let mut builder = StatementBuilder::new();
        builder.push_sql(&format!("SELECT id FROM {} WHERE ", dialect.qualify(&table)));
        let filter = FilterSet {
            rules: vec![FilterRule {
                column: column.to_owned(),
                op,
                value: Some(FilterValue::Single(text.to_owned())),
            }],
            ..FilterSet::default()
        };
        build_filter(&mut builder, dialect.as_ref(), &columns, &filter).expect("a filter");
        builder.push_sql(" ORDER BY id");

        let rows = connection
            .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
            .await
            .unwrap_or_else(|error| panic!("{column} {op:?} {text}: {error:?}"))
            .rows;

        let expected: Vec<Vec<Value>> = expected.into_iter().map(|id| vec![Value::Int(id)]).collect();
        assert_eq!(rows, expected, "{column} {op:?} {text}");
    }
}

/// A binary key followed from another table arrives as its hex text.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires docker"]
async fn equals_on_varbinary_takes_the_hex_form() {
    let fixture = start().await;
    let connection = connect(&fixture, false).await;
    setup(
        connection.as_ref(),
        &[
            "CREATE TABLE dbo.keys (id int PRIMARY KEY, k varbinary(16))",
            "INSERT INTO dbo.keys VALUES (1, 0x0AFF), (2, 0x0A)",
        ],
    )
    .await;
    let table = dbo("keys");
    let columns = columns(connection.as_ref(), &table).await;
    let dialect = connection.dialect();
    let mut builder = StatementBuilder::new();
    builder.push_sql(&format!("SELECT id FROM {} WHERE ", dialect.qualify(&table)));
    let filter = FilterSet {
        rules: vec![FilterRule {
            column: "k".to_owned(),
            op: FilterOp::Eq,
            value: Some(FilterValue::Single("0x0aff".to_owned())),
        }],
        ..FilterSet::default()
    };
    build_filter(&mut builder, dialect.as_ref(), &columns, &filter).expect("a filter");

    let rows = connection
        .query_bound(&builder.finish(), RowLimit::EDITOR_DEFAULT, within(CALL))
        .await
        .expect("the filtered rows")
        .rows;

    assert_eq!(rows, vec![vec![Value::Int(1)]]);
}
