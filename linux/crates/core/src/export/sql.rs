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
/// The table is written with its schema, and the columns `generated`
/// names are left out, as Copy As INSERT leaves them out: every engine
/// refuses a value for a column it computes.
///
/// A value the engine has no literal for, such as a blob, is written as
/// `NULL` behind a comment saying so. Writing a guess would put the
/// wrong data in the table, and refusing the whole export would lose
/// every other row over one cell.
pub fn render_sql_insert(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ResultColumn],
    generated: &[String],
    rows: &[Vec<Value>],
) -> String {
    let Some(shape) = insert_shape(dialect, table, columns, generated) else {
        return String::new();
    };
    let mut out = String::with_capacity(rows.len() * columns.len() * 12);
    for row in rows {
        insert_row(&mut out, dialect, &shape, columns, row);
    }
    out
}

/// What every row's statement shares: `INSERT INTO table (columns)
/// VALUES `, and the quoted name of each of the result's columns it
/// writes.
pub(super) struct InsertShape {
    start: String,
    table_sql: String,
    names: Vec<Option<String>>,
}

/// The shape of every row's statement, or `None` for a result with no
/// column to write, which has no statement.
pub(super) fn insert_shape(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ResultColumn],
    generated: &[String],
) -> Option<InsertShape> {
    let names: Vec<Option<String>> = columns
        .iter()
        .map(|column| (!generated.contains(&column.name)).then(|| dialect.quote_identifier(&column.name)))
        .collect();
    let written: Vec<&str> = names.iter().flatten().map(String::as_str).collect();
    if written.is_empty() {
        return None;
    }
    let table_sql = dialect.qualify(table);
    Some(InsertShape {
        start: format!("INSERT INTO {table_sql} ({}) VALUES ", written.join(", ")),
        table_sql,
        names,
    })
}

pub(super) fn insert_row<'a>(
    out: &mut String,
    dialect: &dyn SqlDialect,
    shape: &InsertShape,
    columns: &[ResultColumn],
    row: impl IntoIterator<Item = &'a Value>,
) {
    let mut cells = row.into_iter();
    // A row shorter than its header leaves its last cells absent, which
    // is as close to unknown as SQL has.
    let cells: Vec<(&ResultColumn, &str, Option<&Value>)> = columns
        .iter()
        .zip(&shape.names)
        .filter_map(|(column, name)| {
            let cell = cells.next();
            Some((column, name.as_deref()?, cell))
        })
        .collect();
    let leaves_out_nulls = !dialect.insert_names_null_cells() && cells.iter().any(|(_, _, cell)| !is_null(*cell));
    let (names, values): (Vec<&str>, Vec<String>) = cells
        .into_iter()
        .filter(|(_, _, cell)| !(leaves_out_nulls && is_null(*cell)))
        .map(|(column, name, cell)| {
            let text = cell.map_or_else(|| "NULL".to_owned(), |value| literal(dialect, value, column));
            (name, text)
        })
        .unzip();
    match leaves_out_nulls {
        true => {
            out.push_str("INSERT INTO ");
            out.push_str(&shape.table_sql);
            out.push_str(" (");
            out.push_str(&names.join(", "));
            out.push_str(") VALUES ");
        }
        false => out.push_str(&shape.start),
    }
    out.push('(');
    out.push_str(&values.join(", "));
    out.push_str(");\n");
}

fn is_null(cell: Option<&Value>) -> bool {
    matches!(cell, None | Some(Value::Null))
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
            Some(CellInput::Value(Value::Null)) | None if !dialect.insert_names_null_cells() => continue,
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
        render_sql_insert(
            &TestDialect::default(),
            &TableRef::unqualified(table),
            columns,
            &[],
            rows,
        )
    }

    #[test]
    fn the_table_is_written_with_its_schema() {
        let sql = render_sql_insert(
            &TestDialect::default(),
            &TableRef::new(Some("sales".to_owned()), "orders"),
            &cols(&["id"]),
            &[],
            &[vec![Value::Int(1)]],
        );

        assert_eq!(sql, "INSERT INTO \"sales\".\"orders\" (\"id\") VALUES (1);\n");
    }

    #[test]
    fn a_generated_column_is_left_to_the_server() {
        let sql = render_sql_insert(
            &TestDialect::default(),
            &TableRef::unqualified("orders"),
            &cols(&["id", "total", "name"]),
            &["total".to_owned()],
            &[vec![Value::Int(1), Value::Int(9), Value::Text("a".into())]],
        );

        assert_eq!(sql, "INSERT INTO \"orders\" (\"id\", \"name\") VALUES (1, 'a');\n");
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
            partition_scoped: false,
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
