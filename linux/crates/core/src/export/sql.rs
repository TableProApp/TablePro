use crate::column::ResultColumn;
use crate::dialect::SqlDialect;
use crate::value::Value;

/// Rows as `INSERT` statements, in the engine's own spelling.
///
/// One statement per row rather than a single multi-row `VALUES` list:
/// the file is usually replayed against a server, and a failure in the
/// middle of one long statement takes every row with it, while a
/// failure among many takes one.
///
/// A value the engine has no literal for, such as a blob, is written as
/// `NULL` behind a comment saying so. Writing a guess would put the
/// wrong data in the table, and refusing the whole export would lose
/// every other row over one cell.
pub fn render_sql_insert(
    dialect: &dyn SqlDialect,
    table: &str,
    columns: &[ResultColumn],
    rows: &[Vec<Value>],
) -> String {
    if columns.is_empty() {
        return String::new();
    }
    let qualified = dialect.quote_identifier(table);
    let names: Vec<String> = columns
        .iter()
        .map(|column| dialect.quote_identifier(&column.name))
        .collect();
    let names = names.join(", ");

    let mut out = String::with_capacity(rows.len() * columns.len() * 12);
    for row in rows {
        let values: Vec<String> = columns
            .iter()
            .enumerate()
            .map(|(index, column)| match row.get(index) {
                Some(value) => literal(dialect, value, column),
                // A row shorter than its header: the cell is absent,
                // which is as close to unknown as SQL has.
                None => "NULL".to_owned(),
            })
            .collect();
        out.push_str(&format!(
            "INSERT INTO {qualified} ({names}) VALUES ({});\n",
            values.join(", ")
        ));
    }
    out
}

/// One cell as a literal, or a marked `NULL` where the engine has no
/// spelling for it.
pub fn literal(dialect: &dyn SqlDialect, value: &Value, column: &ResultColumn) -> String {
    match dialect.literal(value, &column.column_type) {
        Ok(text) => text,
        Err(_) => format!("/* {} omitted */ NULL", value.variant_name()),
    }
}

#[cfg(test)]
mod tests {
    use crate::dialect::dialect_for;

    use super::super::test_columns::cols;
    use super::*;

    #[test]
    fn a_row_becomes_one_statement_per_row() {
        let rows = vec![
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Int(2), Value::Text("b".into())],
        ];

        let sql = render_sql_insert(dialect_for("postgres"), "users", &cols(&["id", "name"]), &rows);

        assert_eq!(
            sql,
            "INSERT INTO \"users\" (\"id\", \"name\") VALUES (1, 'a');\n\
             INSERT INTO \"users\" (\"id\", \"name\") VALUES (2, 'b');\n"
        );
    }

    #[test]
    fn each_engine_quotes_the_way_it_reads() {
        let rows = vec![vec![Value::Int(1)]];
        let columns = cols(&["id"]);

        let postgres = render_sql_insert(dialect_for("postgres"), "t", &columns, &rows);
        let mysql = render_sql_insert(dialect_for("mysql"), "t", &columns, &rows);

        assert!(postgres.starts_with("INSERT INTO \"t\" (\"id\")"), "{postgres}");
        assert!(mysql.starts_with("INSERT INTO `t` (`id`)"), "{mysql}");
    }

    #[test]
    fn a_quote_in_a_value_cannot_end_the_literal() {
        let rows = vec![vec![Value::Text("O'Brien".into())]];

        let sql = render_sql_insert(dialect_for("postgres"), "t", &cols(&["name"]), &rows);

        assert!(sql.contains("'O''Brien'"), "{sql}");
    }

    #[test]
    fn a_quote_in_an_identifier_cannot_end_it_either() {
        let sql = render_sql_insert(
            dialect_for("postgres"),
            "we\"ird",
            &cols(&["a\"b"]),
            &[vec![Value::Int(1)]],
        );

        assert!(sql.contains("\"we\"\"ird\""), "{sql}");
        assert!(sql.contains("\"a\"\"b\""), "{sql}");
    }

    #[test]
    fn a_null_is_written_as_null() {
        let rows = vec![vec![Value::Null]];

        let sql = render_sql_insert(dialect_for("postgres"), "t", &cols(&["a"]), &rows);

        assert!(sql.contains("VALUES (NULL)"), "{sql}");
    }

    #[test]
    fn a_value_the_engine_has_no_literal_for_says_so_rather_than_guessing() {
        let rows = vec![vec![Value::Bytes(vec![0xde, 0xad])]];

        let sql = render_sql_insert(dialect_for("postgres"), "t", &cols(&["blob"]), &rows);

        assert!(sql.contains("omitted"), "{sql}");
        assert!(sql.contains("NULL"), "{sql}");
        assert!(!sql.contains("dead"), "a blob was guessed into a literal: {sql}");
    }

    #[test]
    fn a_short_row_still_fills_every_column() {
        let rows = vec![vec![Value::Int(1)]];

        let sql = render_sql_insert(dialect_for("postgres"), "t", &cols(&["a", "b"]), &rows);

        assert!(sql.contains("VALUES (1, NULL)"), "{sql}");
    }

    #[test]
    fn a_result_with_no_columns_writes_nothing() {
        assert_eq!(render_sql_insert(dialect_for("postgres"), "t", &[], &[]), "");
    }
}
