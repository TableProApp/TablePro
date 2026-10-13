use super::RenderInsertError;
use crate::column::{ColumnInfo, ResultColumn};
use crate::dialect::SqlDialect;
use crate::edit::CellInput;
use crate::meta::TableRef;
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

/// One row as an `INSERT` the user can paste and run.
///
/// Unlike an export, a value with no literal is an error rather than a
/// marked `NULL`: a single statement copied to run again is worth
/// nothing with a cell quietly swapped out. A `Default` cell and a
/// generated column are left out, as a save leaves them, so the server
/// fills them.
pub fn render_insert(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    cells: &[CellInput],
) -> Result<String, RenderInsertError> {
    let table_sql = dialect.qualify(table);
    let mut names = Vec::with_capacity(columns.len());
    let mut values = Vec::with_capacity(columns.len());
    for (index, column) in columns.iter().enumerate() {
        if !column.is_writable() {
            continue;
        }
        let value = match cells.get(index) {
            Some(CellInput::Default) => continue,
            Some(CellInput::Value(value)) => dialect.literal(value, &column.column_type)?,
            None => "NULL".to_owned(),
        };
        names.push(dialect.quote_identifier(&column.name));
        values.push(value);
    }
    if names.is_empty() {
        let sql = dialect
            .insert_default_row(&table_sql)
            .ok_or(RenderInsertError::NoValues)?;
        return Ok(format!("{sql};"));
    }
    Ok(format!(
        "INSERT INTO {table_sql} ({}) VALUES ({});",
        names.join(", "),
        values.join(", ")
    ))
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
    use super::super::test_columns::cols;
    use super::*;
    use crate::dialect::{LiteralError, TestDialect};

    fn render(table: &str, columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
        render_sql_insert(&TestDialect::default(), table, columns, rows)
    }

    #[test]
    fn a_row_becomes_one_statement_per_row() {
        let rows = vec![
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Int(2), Value::Text("b".into())],
        ];

        let sql = render("users", &cols(&["id", "name"]), &rows);

        assert_eq!(
            sql,
            "INSERT INTO \"users\" (\"id\", \"name\") VALUES (1, 'a');\n\
             INSERT INTO \"users\" (\"id\", \"name\") VALUES (2, 'b');\n"
        );
    }

    #[test]
    fn a_quote_in_a_value_cannot_end_the_literal() {
        let rows = vec![vec![Value::Text("O'Brien".into())]];

        let sql = render("t", &cols(&["name"]), &rows);

        assert!(sql.contains("'O''Brien'"), "{sql}");
    }

    #[test]
    fn a_quote_in_an_identifier_cannot_end_it_either() {
        let sql = render("we\"ird", &cols(&["a\"b"]), &[vec![Value::Int(1)]]);

        assert!(sql.contains("\"we\"\"ird\""), "{sql}");
        assert!(sql.contains("\"a\"\"b\""), "{sql}");
    }

    #[test]
    fn a_null_is_written_as_null() {
        let rows = vec![vec![Value::Null]];

        let sql = render("t", &cols(&["a"]), &rows);

        assert!(sql.contains("VALUES (NULL)"), "{sql}");
    }

    #[test]
    fn a_value_the_engine_has_no_literal_for_says_so_rather_than_guessing() {
        let rows = vec![vec![Value::Bytes(vec![0xde, 0xad])]];

        let sql = render("t", &cols(&["blob"]), &rows);

        assert!(sql.contains("omitted"), "{sql}");
        assert!(sql.contains("NULL"), "{sql}");
        assert!(!sql.contains("dead"), "a blob was guessed into a literal: {sql}");
    }

    #[test]
    fn a_short_row_still_fills_every_column() {
        let rows = vec![vec![Value::Int(1)]];

        let sql = render("t", &cols(&["a", "b"]), &rows);

        assert!(sql.contains("VALUES (1, NULL)"), "{sql}");
    }

    #[test]
    fn a_result_with_no_columns_writes_nothing() {
        assert_eq!(render("t", &[], &[]), "");
    }

    fn column(name: &str, generated: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: crate::column::ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: generated,
            default: crate::column::ColumnDefault::None,
            comment: None,
        }
    }

    fn values(row: &[Value]) -> Vec<CellInput> {
        row.iter().cloned().map(CellInput::Value).collect()
    }

    #[test]
    fn render_insert_qualifies_schema_and_skips_generated() {
        let columns = [column("id", false), column("total", true), column("name", false)];
        let row = [Value::Int(1), Value::Int(9), Value::Text("O'Brien".into())];

        let sql = render_insert(
            &TestDialect::default(),
            &TableRef::new(Some("sales".to_owned()), "orders"),
            &columns,
            &values(&row),
        );

        assert_eq!(
            sql.as_deref(),
            Ok("INSERT INTO \"sales\".\"orders\" (\"id\", \"name\") VALUES (1, 'O''Brien');")
        );
    }

    #[test]
    fn render_insert_refuses_a_value_with_no_literal() {
        let sql = render_insert(
            &TestDialect::default(),
            &TableRef::unqualified("t"),
            &[column("blob", false)],
            &values(&[Value::Bytes(vec![0xde, 0xad])]),
        );

        assert!(
            matches!(
                sql,
                Err(RenderInsertError::Literal(LiteralError::Unrepresentable { .. }))
            ),
            "{sql:?}"
        );
    }

    #[test]
    fn render_insert_leaves_a_default_cell_to_the_server() {
        let columns = [column("id", false), column("name", false), column("created_at", false)];
        let cells = [
            CellInput::Default,
            CellInput::Value(Value::Text("x".into())),
            CellInput::Default,
        ];

        let sql = render_insert(&TestDialect::default(), &TableRef::unqualified("t"), &columns, &cells);

        assert_eq!(sql.as_deref(), Ok("INSERT INTO \"t\" (\"name\") VALUES ('x');"));
    }

    #[test]
    fn render_insert_with_nothing_to_write_needs_a_default_row_form() {
        let columns = [column("id", false)];
        let cells = [CellInput::Default];
        let table = TableRef::unqualified("t");

        let with_form = render_insert(&TestDialect::default(), &table, &columns, &cells);
        let without = render_insert(&TestDialect::default().without_default_row(), &table, &columns, &cells);

        assert_eq!(with_form.as_deref(), Ok("INSERT INTO \"t\" DEFAULT VALUES;"));
        assert_eq!(without, Err(RenderInsertError::NoValues));
    }
}
