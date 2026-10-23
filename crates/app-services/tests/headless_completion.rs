#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use tablepro_app_services::completion::SchemaIndex;
use tablepro_app_services::completion_proposals::candidates;
use tablepro_core::sql_syntax::SqlGrammar;

#[test]
fn quoted_table_completion_preserves_the_replacement_and_catalog_identity() {
    let mut index = SchemaIndex::default();
    index.set_tables(vec![r#""odd.schema"."Users""#.into()]);
    index.grammar = Some(SqlGrammar::PostgreSql);
    let sql = r#"SELECT * FROM "odd.schema"."Us" WHERE true"#;
    let cursor = sql.find("Us").unwrap() + 2;
    let result = candidates(sql, cursor, &index);
    assert_eq!(&sql[result.range], r#""odd.schema"."Us""#);
    assert!(
        result
            .values
            .iter()
            .any(|(_, value)| value == r#""odd.schema"."Users""#)
    );
}

#[test]
fn clearing_metadata_retires_requests_and_keeps_keyword_completion_available() {
    let mut index = SchemaIndex::default();
    index.set_tables(vec!["public.previous_connection".into()]);
    index.set_columns("public.previous_connection", vec!["private_column".into()]);
    let request = index.request("public.previous_connection".into());
    index.clear();
    assert!(!index.accepts(&request));
    assert!(!index.knows_columns("public.previous_connection"));
    let result = candidates("SEL", 3, &index);
    assert!(
        result
            .values
            .iter()
            .any(|(label, value)| label == "SELECT" && value == "SELECT")
    );
    let result = candidates("SELECT * FROM ", 14, &index);
    assert!(
        !result
            .values
            .iter()
            .any(|(_, value)| value == "public.previous_connection")
    );
}
