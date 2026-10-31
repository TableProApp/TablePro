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
/// refuses a value for a column it computes. The columns `numbered`
/// names keep their values, written the way the engine lets an INSERT
/// set a column it numbers, so a row keeps the key other rows point at.
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
    numbered: &[String],
    rows: &[Vec<Value>],
) -> String {
    let Some(mut writer) = InsertWriter::new(dialect, table, columns, generated, numbered) else {
        return String::new();
    };
    let mut out = String::with_capacity(rows.len() * columns.len() * 12);
    for row in rows {
        writer.row(&mut out, dialect, columns, row);
    }
    writer.finish(&mut out, dialect);
    out
}

/// An export's statements, a row at a time. Every row's statement
/// shares `start`, `INSERT INTO table (columns) VALUES `, and the quoted
/// name of each of the result's columns it writes. An engine of
/// documents writes `insertOne(` instead, and each value under its
/// field's name, which `columns` then holds unquoted.
pub(super) struct InsertWriter {
    start: String,
    table_sql: String,
    columns: Vec<Option<WrittenColumn>>,
    document: bool,
    /// Whether the last statement left the table's identity insert on.
    identity_on: bool,
}

struct WrittenColumn {
    name: String,
    numbered: bool,
}

impl InsertWriter {
    /// `None` for a result with no column to write, which has no
    /// statement.
    pub(super) fn new(
        dialect: &dyn SqlDialect,
        table: &TableRef,
        columns: &[ResultColumn],
        generated: &[String],
        numbered: &[String],
    ) -> Option<Self> {
        let document = crate::document::speaks_shell(dialect);
        let written: Vec<Option<WrittenColumn>> = columns
            .iter()
            .map(|column| {
                (!generated.contains(&column.name)).then(|| WrittenColumn {
                    name: match document {
                        true => column.name.clone(),
                        false => dialect.quote_identifier(&column.name),
                    },
                    numbered: !document && numbered.contains(&column.name),
                })
            })
            .collect();
        let names: Vec<&str> = written.iter().flatten().map(|column| column.name.as_str()).collect();
        if names.is_empty() {
            return None;
        }
        if document {
            return Some(Self {
                start: crate::document::insert_start(table),
                table_sql: String::new(),
                columns: written,
                document,
                identity_on: false,
            });
        }
        let table_sql = dialect.portable_name(table);
        let mut start = format!("INSERT INTO {table_sql} ({}) ", names.join(", "));
        let writes_numbered = written.iter().flatten().any(|column| column.numbered);
        push_overriding(&mut start, dialect, writes_numbered);
        start.push_str("VALUES ");
        Some(Self {
            start,
            table_sql,
            columns: written,
            document,
            identity_on: false,
        })
    }

    pub(super) fn row<'a>(
        &mut self,
        out: &mut String,
        dialect: &dyn SqlDialect,
        columns: &[ResultColumn],
        row: impl IntoIterator<Item = &'a Value>,
    ) {
        let mut cells = row.into_iter();
        // A row shorter than its header leaves its last cells absent, which
        // is as close to unknown as SQL has.
        let cells: Vec<(&ResultColumn, &WrittenColumn, Option<&Value>)> = columns
            .iter()
            .zip(&self.columns)
            .filter_map(|(column, written)| {
                let cell = cells.next();
                Some((column, written.as_ref()?, cell))
            })
            .collect();
        let leaves_out_nulls = !dialect.insert_names_null_cells() && cells.iter().any(|(_, _, cell)| !is_null(*cell));
        let cells: Vec<(&ResultColumn, &WrittenColumn, Option<&Value>)> = cells
            .into_iter()
            .filter(|(_, _, cell)| !(leaves_out_nulls && is_null(*cell)))
            .collect();
        let writes_numbered = cells.iter().any(|(_, written, _)| written.numbered);
        if let Some(line) = identity_switch(dialect, &self.table_sql, &mut self.identity_on, writes_numbered) {
            out.push_str(&line);
            out.push('\n');
        }
        let (names, values): (Vec<&str>, Vec<String>) = cells
            .into_iter()
            .map(|(column, written, cell)| {
                let text = cell.map_or_else(|| "NULL".to_owned(), |value| literal(dialect, value, column));
                (written.name.as_str(), text)
            })
            .unzip();
        if self.document {
            let pairs: Vec<(String, String)> = names.into_iter().map(str::to_owned).zip(values).collect();
            out.push_str(&self.start);
            out.push_str(&crate::document::insert_document(&pairs));
            out.push_str(");\n");
            return;
        }
        match leaves_out_nulls {
            true => {
                out.push_str("INSERT INTO ");
                out.push_str(&self.table_sql);
                out.push_str(" (");
                out.push_str(&names.join(", "));
                out.push_str(") ");
                push_overriding(out, dialect, writes_numbered);
                out.push_str("VALUES ");
            }
            false => out.push_str(&self.start),
        }
        out.push('(');
        out.push_str(&values.join(", "));
        out.push_str(");\n");
    }

    /// Ends a run of statements the identity insert is still on for.
    pub(super) fn finish(&mut self, out: &mut String, dialect: &dyn SqlDialect) {
        if let Some(line) = identity_switch(dialect, &self.table_sql, &mut self.identity_on, false) {
            out.push_str(&line);
            out.push('\n');
        }
    }
}

fn is_null(cell: Option<&Value>) -> bool {
    matches!(cell, None | Some(Value::Null))
}

/// What turns the table's identity insert on before a run of
/// statements that write a numbered column, or off before one that does
/// not. SQL Server fails an INSERT that leaves the identity column out
/// while it is on, and lets one table of a session have it on at a
/// time, so it is on for no more than the run.
fn identity_switch(dialect: &dyn SqlDialect, table_sql: &str, on: &mut bool, wanted: bool) -> Option<String> {
    if *on == wanted {
        return None;
    }
    *on = wanted;
    dialect.identity_insert(table_sql, wanted)
}

fn push_overriding(sql: &mut String, dialect: &dyn SqlDialect, writes_numbered: bool) {
    if let Some(clause) = dialect.insert_overriding_clause().filter(|_| writes_numbered) {
        sql.push_str(clause);
        sql.push(' ');
    }
}

/// Rows as `INSERT` statements the user can paste and run, one a line.
///
/// Unlike an export, a value with no literal is an error rather than a
/// marked `NULL`: a statement copied to run again is worth nothing with
/// a cell quietly swapped out. A `Default` cell and a generated column
/// are left out, as a save leaves them, so the server fills them. A
/// value in a column the server numbers is kept, written the way the
/// engine lets an INSERT set one, so a copied row lands with its key.
pub fn render_inserts(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    columns: &[ColumnInfo],
    rows: &[Vec<CellInput>],
) -> Result<String, RenderInsertError> {
    let table_sql = dialect.portable_name(table);
    let mut lines = Vec::with_capacity(rows.len());
    let mut identity_on = false;
    for cells in rows {
        let (sql, writes_numbered) = row_insert(dialect, table, &table_sql, columns, cells)?;
        lines.extend(identity_switch(dialect, &table_sql, &mut identity_on, writes_numbered));
        lines.push(sql);
    }
    lines.extend(identity_switch(dialect, &table_sql, &mut identity_on, false));
    Ok(lines.join("\n"))
}

/// One row's statement, and whether it writes a column the server
/// numbers.
fn row_insert(
    dialect: &dyn SqlDialect,
    table: &TableRef,
    table_sql: &str,
    columns: &[ColumnInfo],
    cells: &[CellInput],
) -> Result<(String, bool), RenderInsertError> {
    let mut names = Vec::with_capacity(columns.len());
    let mut values = Vec::with_capacity(columns.len());
    let mut writes_numbered = false;
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
        writes_numbered |= column.is_auto_increment;
        names.push(dialect.quote_identifier(&column.name));
        values.push(value);
    }
    if crate::document::speaks_shell(dialect) {
        let pairs = document_fields(columns, cells, dialect)?;
        let sql = format!(
            "{}{});",
            crate::document::insert_start(table),
            crate::document::insert_document(&pairs)
        );
        return Ok((sql, false));
    }
    if names.is_empty() {
        let sql = dialect
            .insert_default_row(table_sql)
            .ok_or(RenderInsertError::NoValues)?;
        return Ok((format!("{sql};"), false));
    }
    let mut sql = format!("INSERT INTO {table_sql} ({}) ", names.join(", "));
    push_overriding(&mut sql, dialect, writes_numbered);
    sql.push_str("VALUES (");
    sql.push_str(&values.join(", "));
    sql.push_str(");");
    Ok((sql, writes_numbered))
}

/// A document's fields for Copy As INSERT: each cell set, under its
/// field's name, a field left to the server left out.
fn document_fields(
    columns: &[ColumnInfo],
    cells: &[CellInput],
    dialect: &dyn SqlDialect,
) -> Result<Vec<(String, String)>, RenderInsertError> {
    let mut fields = Vec::with_capacity(columns.len());
    for (index, column) in columns.iter().enumerate() {
        let value = match cells.get(index) {
            Some(CellInput::Default) | None => continue,
            Some(CellInput::Value(value)) => dialect.literal(value, &column.column_type)?,
        };
        fields.push((column.name.clone(), value));
    }
    Ok(fields)
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
    use std::sync::Arc;

    use super::super::test_columns::cols;
    use super::super::{RowEncoder, SqlInsertEncoder};
    use super::*;
    use crate::column::{ColumnType, SqlExpression};
    use crate::dialect::{
        BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, TestDialect,
    };
    use crate::meta::{EngineRowId, EngineRowIdPart};
    use crate::sql_syntax::{ExpressionSyntaxError, HistoryRecording, SqlGrammar, TypeSyntaxError};

    fn render(table: &str, columns: &[ResultColumn], rows: &[Vec<Value>]) -> String {
        render_sql_insert(
            &TestDialect::default(),
            &TableRef::unqualified(table),
            columns,
            &[],
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
            &[],
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

    fn numbered(name: &str) -> ColumnInfo {
        ColumnInfo {
            primary_key: true,
            is_auto_increment: true,
            nullable: false,
            ..column(name, false)
        }
    }

    fn values(row: &[Value]) -> Vec<CellInput> {
        row.iter().cloned().map(CellInput::Value).collect()
    }

    fn insert_one(dialect: &dyn SqlDialect, table: &TableRef, columns: &[ColumnInfo], cells: Vec<CellInput>) -> String {
        render_inserts(dialect, table, columns, &[cells]).expect("the statement")
    }

    #[test]
    fn render_inserts_qualifies_schema_and_skips_generated() {
        let columns = [column("id", false), column("total", true), column("name", false)];
        let row = [Value::Int(1), Value::Int(9), Value::Text("O'Brien".into())];

        let sql = insert_one(
            &TestDialect::default(),
            &TableRef::new(Some("sales".to_owned()), "orders"),
            &columns,
            values(&row),
        );

        assert_eq!(
            sql,
            "INSERT INTO \"sales\".\"orders\" (\"id\", \"name\") VALUES (1, 'O''Brien');"
        );
    }

    #[test]
    fn render_inserts_puts_one_statement_on_each_line() {
        let columns = [column("id", false)];
        let rows = [values(&[Value::Int(1)]), values(&[Value::Int(2)])];

        let sql = render_inserts(&TestDialect::default(), &TableRef::unqualified("t"), &columns, &rows);

        assert_eq!(
            sql.as_deref(),
            Ok("INSERT INTO \"t\" (\"id\") VALUES (1);\nINSERT INTO \"t\" (\"id\") VALUES (2);")
        );
    }

    #[test]
    fn render_inserts_refuses_a_value_with_no_literal() {
        let sql = render_inserts(
            &TestDialect::default(),
            &TableRef::unqualified("t"),
            &[column("blob", false)],
            &[values(&[Value::Bytes(vec![0xde, 0xad])])],
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
    fn render_inserts_leaves_a_default_cell_to_the_server() {
        let columns = [column("id", false), column("name", false), column("created_at", false)];
        let cells = vec![
            CellInput::Default,
            CellInput::Value(Value::Text("x".into())),
            CellInput::Default,
        ];

        let sql = insert_one(&TestDialect::default(), &TableRef::unqualified("t"), &columns, cells);

        assert_eq!(sql, "INSERT INTO \"t\" (\"name\") VALUES ('x');");
    }

    #[test]
    fn render_inserts_with_nothing_to_write_needs_a_default_row_form() {
        let columns = [column("id", false)];
        let rows = [vec![CellInput::Default]];
        let table = TableRef::unqualified("t");

        let with_form = render_inserts(&TestDialect::default(), &table, &columns, &rows);
        let without = render_inserts(&TestDialect::default().without_default_row(), &table, &columns, &rows);

        assert_eq!(with_form.as_deref(), Ok("INSERT INTO \"t\" DEFAULT VALUES;"));
        assert_eq!(without, Err(RenderInsertError::NoValues));
    }

    /// The test dialect, with an engine's ways of letting an INSERT
    /// write a column the server numbers.
    #[derive(Debug, Default)]
    struct Numbering {
        inner: TestDialect,
        overriding: bool,
        identity_insert: bool,
        null_cells_left_out: bool,
    }

    impl Numbering {
        fn overriding_only() -> Self {
            Self {
                overriding: true,
                ..Self::default()
            }
        }

        fn identity_insert_only() -> Self {
            Self {
                identity_insert: true,
                ..Self::default()
            }
        }

        fn both() -> Self {
            Self {
                overriding: true,
                identity_insert: true,
                ..Self::default()
            }
        }
    }

    impl SqlDialect for Numbering {
        fn capabilities(&self) -> DialectCapabilities {
            self.inner.capabilities()
        }

        fn grammar(&self) -> SqlGrammar {
            self.inner.grammar()
        }

        fn quote_identifier(&self, name: &str) -> String {
            self.inner.quote_identifier(name)
        }

        fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
            self.inner.placeholder(ordinal, value, target)
        }

        fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
            self.inner.literal(value, column)
        }

        fn escape_like_text(&self, text: &str) -> String {
            self.inner.escape_like_text(text)
        }

        fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
            self.inner.row_window(order_by, limit, offset)
        }

        fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
            self.inner.row_value_after(key_sql, markers, direction)
        }

        fn engine_row_id(&self, id: EngineRowId) -> Option<String> {
            self.inner.engine_row_id(id)
        }

        fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
            self.inner.engine_row_id_column(part)
        }

        fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
            self.inner.parse_type(text)
        }

        fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
            self.inner.parse_expression(text)
        }

        fn history_recording(&self, sql: &str) -> HistoryRecording {
            self.inner.history_recording(sql)
        }

        fn insert_names_null_cells(&self) -> bool {
            !self.null_cells_left_out
        }

        fn insert_overriding_clause(&self) -> Option<&'static str> {
            self.overriding.then_some("OVERRIDING SYSTEM VALUE")
        }

        fn identity_insert(&self, table_sql: &str, on: bool) -> Option<String> {
            let state = match on {
                true => "ON",
                false => "OFF",
            };
            self.identity_insert
                .then(|| format!("SET IDENTITY_INSERT {table_sql} {state};"))
        }
    }

    fn saved(id: i64, name: &str) -> Vec<CellInput> {
        values(&[Value::Int(id), Value::Text(name.into())])
    }

    fn draft(name: &str) -> Vec<CellInput> {
        vec![CellInput::Default, CellInput::Value(Value::Text(name.into()))]
    }

    #[test]
    fn only_a_statement_that_writes_a_numbered_column_overrides_it() {
        let columns = [numbered("id"), column("name", false)];

        let sql = render_inserts(
            &Numbering::overriding_only(),
            &TableRef::unqualified("t"),
            &columns,
            &[saved(7, "a"), draft("b")],
        );

        assert_eq!(
            sql.as_deref(),
            Ok(
                "INSERT INTO \"t\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE VALUES (7, 'a');\n\
                INSERT INTO \"t\" (\"name\") VALUES ('b');"
            )
        );
    }

    #[test]
    fn identity_insert_is_on_for_each_run_of_rows_that_write_the_numbered_column() {
        let columns = [numbered("id"), column("name", false)];
        let rows = [saved(1, "a"), saved(2, "b"), draft("c"), saved(3, "d")];

        let sql = render_inserts(
            &Numbering::identity_insert_only(),
            &TableRef::new(Some("dbo".to_owned()), "t"),
            &columns,
            &rows,
        );

        assert_eq!(
            sql.as_deref(),
            Ok("SET IDENTITY_INSERT \"dbo\".\"t\" ON;\n\
                INSERT INTO \"dbo\".\"t\" (\"id\", \"name\") VALUES (1, 'a');\n\
                INSERT INTO \"dbo\".\"t\" (\"id\", \"name\") VALUES (2, 'b');\n\
                SET IDENTITY_INSERT \"dbo\".\"t\" OFF;\n\
                INSERT INTO \"dbo\".\"t\" (\"name\") VALUES ('c');\n\
                SET IDENTITY_INSERT \"dbo\".\"t\" ON;\n\
                INSERT INTO \"dbo\".\"t\" (\"id\", \"name\") VALUES (3, 'd');\n\
                SET IDENTITY_INSERT \"dbo\".\"t\" OFF;")
        );
    }

    #[test]
    fn rows_that_write_no_numbered_column_need_neither() {
        let columns = [numbered("id"), column("name", false)];

        let sql = render_inserts(
            &Numbering::both(),
            &TableRef::unqualified("t"),
            &columns,
            &[draft("a"), vec![CellInput::Default, CellInput::Default]],
        );

        assert_eq!(
            sql.as_deref(),
            Ok("INSERT INTO \"t\" (\"name\") VALUES ('a');\nINSERT INTO \"t\" DEFAULT VALUES;")
        );
    }

    #[test]
    fn a_shell_insert_never_overrides() {
        let dialect = Numbering {
            inner: TestDialect::default().parsing_as(SqlGrammar::Mongo),
            ..Numbering::both()
        };
        let table = TableRef::unqualified("t");

        let copied = render_inserts(
            &dialect,
            &table,
            &[numbered("_id"), column("name", false)],
            &[saved(1, "a")],
        )
        .expect("the insert");
        let exported = render_sql_insert(
            &dialect,
            &table,
            &cols(&["_id", "name"]),
            &[],
            &["_id".to_owned()],
            &[vec![Value::Int(1), Value::Text("a".into())]],
        );

        for sql in [copied, exported] {
            assert!(sql.contains("insertOne("), "{sql}");
            assert!(!sql.contains("OVERRIDING"), "{sql}");
            assert!(!sql.contains("IDENTITY_INSERT"), "{sql}");
        }
    }

    #[test]
    fn an_export_overrides_the_numbered_column_inside_one_run() {
        let rows = [
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Int(2), Value::Text("b".into())],
        ];

        let sql = render_sql_insert(
            &Numbering::both(),
            &TableRef::unqualified("t"),
            &cols(&["id", "name"]),
            &[],
            &["id".to_owned()],
            &rows,
        );

        assert_eq!(
            sql,
            "SET IDENTITY_INSERT \"t\" ON;\n\
             INSERT INTO \"t\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE VALUES (1, 'a');\n\
             INSERT INTO \"t\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE VALUES (2, 'b');\n\
             SET IDENTITY_INSERT \"t\" OFF;\n"
        );
    }

    #[test]
    fn an_export_that_leaves_out_null_cells_overrides_only_where_the_number_is_written() {
        let dialect = Numbering {
            null_cells_left_out: true,
            ..Numbering::both()
        };
        let rows = [
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Null, Value::Text("b".into())],
        ];

        let sql = render_sql_insert(
            &dialect,
            &TableRef::unqualified("t"),
            &cols(&["id", "name"]),
            &[],
            &["id".to_owned()],
            &rows,
        );

        assert_eq!(
            sql,
            "SET IDENTITY_INSERT \"t\" ON;\n\
             INSERT INTO \"t\" (\"id\", \"name\") OVERRIDING SYSTEM VALUE VALUES (1, 'a');\n\
             SET IDENTITY_INSERT \"t\" OFF;\n\
             INSERT INTO \"t\" (\"name\") VALUES ('b');\n"
        );
    }

    /// Every call's output taken as soon as it is written, as an export
    /// sink takes it.
    fn streamed(mut encoder: SqlInsertEncoder, rows: &[Vec<Value>]) -> String {
        let mut taken = Vec::new();
        let mut out = Vec::new();
        encoder.begin(&mut out);
        taken.append(&mut out);
        for row in rows {
            encoder.row(&mut out, &mut row.iter()).expect("the row");
            taken.append(&mut out);
        }
        encoder.finish(&mut out);
        taken.append(&mut out);
        String::from_utf8(taken).expect("utf-8")
    }

    #[test]
    fn the_encoder_switches_identity_insert_where_the_export_does() {
        let leaving_out_nulls = Numbering {
            null_cells_left_out: true,
            ..Numbering::both()
        };
        let columns: Arc<[ResultColumn]> = cols(&["id", "name"]).into();
        let numbered = ["id".to_owned()];
        let table = TableRef::unqualified("t");
        let rows = [
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Null, Value::Text("b".into())],
            vec![Value::Int(3), Value::Text("c".into())],
        ];
        for dialect in [Numbering::both(), leaving_out_nulls] {
            let dialect: Arc<dyn SqlDialect> = Arc::new(dialect);
            let encoder = SqlInsertEncoder::new(dialect.clone(), &table, columns.clone(), &[], &numbered);

            assert_eq!(
                streamed(encoder, &rows),
                render_sql_insert(&*dialect, &table, &columns, &[], &numbered, &rows)
            );
        }
    }
}
