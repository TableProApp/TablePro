//! Filters on an xml column, which takes neither LIKE nor `=`.

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
