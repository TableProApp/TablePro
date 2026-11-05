use crate::column::{ColumnInfo, ResultColumn};
use crate::dialect::SqlDialect;
use crate::value::Value;

use super::{DumpDialect, DumpStatement};

/// The most rows one INSERT carries, under every engine's own limit:
/// SQL Server takes 1,000 rows in a VALUES list.
const MAX_ROWS: usize = 1_000;

/// The most bytes one INSERT carries, mysqldump's `net_buffer_length`,
/// well under every `max_allowed_packet` MySQL and MariaDB ship with.
pub(crate) const MAX_STATEMENT_BYTES: usize = 1_046_528;

/// A table's rows as multi-row INSERTs with a column list, cut at a row
/// count and a size.
pub(super) struct InsertBatch {
    /// For a table whose every column the server computes, the statement
    /// that inserts one row of defaults, written once per row.
    default_row: Option<String>,
    start: String,
    table_sql: String,
    /// For each result column, whether the INSERT names it. A column the
    /// server computes is left out: every engine refuses a value there.
    written: Vec<bool>,
    writes_numbered: bool,
    max_rows: usize,
    tuples: String,
    rows: usize,
    identity_on: bool,
    /// Per result column, the values that had no literal and went in as
    /// NULL.
    omitted: Vec<u64>,
}

impl InsertBatch {
    /// `None` when no column can be written and the engine has no INSERT
    /// of defaults alone.
    pub(super) fn new(
        dialect: &dyn SqlDialect,
        table_sql: String,
        columns: &[ResultColumn],
        info: &[ColumnInfo],
        one_row_per_insert: bool,
    ) -> Option<Self> {
        let described = |name: &str| info.iter().find(|column| column.name == name);
        let written: Vec<bool> = columns
            .iter()
            .map(|column| described(&column.name).is_none_or(ColumnInfo::is_writable))
            .collect();
        let names: Vec<String> = columns
            .iter()
            .zip(&written)
            .filter(|(_, written)| **written)
            .map(|(column, _)| dialect.quote_identifier(&column.name))
            .collect();
        if names.is_empty() {
            let default_row = dialect.insert_default_row(&table_sql)?;
            return Some(Self {
                default_row: Some(default_row),
                start: String::new(),
                table_sql,
                omitted: vec![0; written.len()],
                written,
                writes_numbered: false,
                max_rows: 1,
                tuples: String::new(),
                rows: 0,
                identity_on: false,
            });
        }
        let writes_numbered = columns
            .iter()
            .zip(&written)
            .any(|(column, written)| *written && described(&column.name).is_some_and(|info| info.is_auto_increment));
        let mut start = format!("INSERT INTO {table_sql} ({}) ", names.join(", "));
        if let Some(clause) = dialect.insert_overriding_clause().filter(|_| writes_numbered) {
            start.push_str(clause);
            start.push(' ');
        }
        start.push_str("VALUES\n");
        let max_rows = match one_row_per_insert {
            true => 1,
            false => dialect.insert_batch_limits().rows.clamp(1, MAX_ROWS),
        };
        Some(Self {
            default_row: None,
            start,
            table_sql,
            omitted: vec![0; written.len()],
            written,
            writes_numbered,
            max_rows,
            tuples: String::new(),
            rows: 0,
            identity_on: false,
        })
    }

    pub(super) fn row(
        &mut self,
        dialect: &dyn SqlDialect,
        dump: &dyn DumpDialect,
        columns: &[ResultColumn],
        row: &[Value],
        out: &mut Vec<DumpStatement>,
    ) {
        if let Some(default_row) = &self.default_row {
            out.push(DumpStatement::new(default_row.clone()));
            return;
        }
        let mut tuple = String::from("(");
        let mut first = true;
        for (index, column) in columns.iter().enumerate() {
            if !self.written.get(index).copied().unwrap_or(false) {
                continue;
            }
            if !first {
                tuple.push_str(", ");
            }
            first = false;
            match row.get(index).map(|value| dialect.literal(value, &column.column_type)) {
                Some(Ok(literal)) => tuple.push_str(&literal),
                Some(Err(_)) => {
                    self.omitted[index] += 1;
                    tuple.push_str("NULL");
                }
                None => tuple.push_str("NULL"),
            }
        }
        tuple.push(')');
        let fits = self.tuples.len() + tuple.len() + 2 <= MAX_STATEMENT_BYTES.saturating_sub(self.start.len());
        if self.rows > 0 && !fits {
            self.flush(dump, out);
        }
        if self.rows > 0 {
            self.tuples.push_str(",\n");
        }
        self.tuples.push_str(&tuple);
        self.rows += 1;
        if self.rows >= self.max_rows {
            self.flush(dump, out);
        }
    }

    /// The last statement, and the identity insert turned off.
    pub(super) fn finish(&mut self, dump: &dyn DumpDialect, out: &mut Vec<DumpStatement>) {
        self.flush(dump, out);
        if self.identity_on {
            self.identity_on = false;
            out.extend(dump.identity_insert(&self.table_sql, false).map(DumpStatement::new));
        }
    }

    /// The columns whose values went in as NULL for want of a literal,
    /// with how many each.
    pub(super) fn omitted<'a>(&'a self, columns: &'a [ResultColumn]) -> impl Iterator<Item = (&'a str, u64)> + 'a {
        columns
            .iter()
            .zip(&self.omitted)
            .filter(|(_, count)| **count > 0)
            .map(|(column, count)| (column.name.as_str(), *count))
    }

    fn flush(&mut self, dump: &dyn DumpDialect, out: &mut Vec<DumpStatement>) {
        if self.rows == 0 {
            return;
        }
        if self.writes_numbered && !self.identity_on {
            self.identity_on = true;
            out.extend(dump.identity_insert(&self.table_sql, true).map(DumpStatement::new));
        }
        let mut sql = String::with_capacity(self.start.len() + self.tuples.len());
        sql.push_str(&self.start);
        sql.push_str(&self.tuples);
        out.push(DumpStatement::new(sql));
        self.tuples.clear();
        self.rows = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::column::{ColumnInfo, ColumnType};
    use crate::dialect::TestDialect;

    #[derive(Debug)]
    struct Plain;
    impl DumpDialect for Plain {
        fn identity_insert(&self, table_sql: &str, on: bool) -> Option<String> {
            Some(format!("IDENTITY {table_sql} {on}"))
        }
    }

    fn text(name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("text"))
    }

    fn info(name: &str, generated: bool, numbered: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: ColumnType::untyped_text("text"),
            nullable: true,
            primary_key: false,
            is_auto_increment: numbered,
            is_generated: generated,
            partition_scoped: false,
            default: crate::column::ColumnDefault::None,
            comment: None,
        }
    }

    /// `count` rows whose first value is `width` characters long. A format
    /// width past `u16::MAX` panics, so the padding is built by hand.
    fn rows(count: usize, width: usize) -> Vec<Vec<Value>> {
        (0..count)
            .map(|row| {
                let digits = row.to_string();
                let padded = format!("{}{digits}", "0".repeat(width.saturating_sub(digits.len())));
                vec![Value::Text(padded), Value::Text("x".to_owned())]
            })
            .collect()
    }

    fn run(batch: &mut InsertBatch, columns: &[ResultColumn], rows: &[Vec<Value>]) -> Vec<String> {
        let mut out = Vec::new();
        for row in rows {
            batch.row(&TestDialect::default(), &Plain, columns, row, &mut out);
        }
        batch.finish(&Plain, &mut out);
        out.into_iter().map(|statement| statement.sql).collect()
    }

    #[test]
    fn a_generated_column_is_left_out_and_rows_share_a_statement() {
        let columns = [text("a"), text("b")];
        let info = [info("a", false, false), info("b", true, false)];
        let mut batch =
            InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &info, false).expect("a column");

        let statements = run(&mut batch, &columns, &rows(3, 1));

        assert_eq!(statements.len(), 1, "{statements:?}");
        assert!(
            statements[0].starts_with("INSERT INTO t (\"a\") VALUES\n"),
            "{}",
            statements[0]
        );
        assert_eq!(statements[0].matches("),\n(").count(), 2, "{}", statements[0]);
    }

    #[test]
    fn a_statement_closes_at_the_size_limit_and_one_wide_row_still_goes() {
        let columns = [text("a"), text("b")];
        let mut batch =
            InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &[], false).expect("a column");

        let statements = run(&mut batch, &columns, &rows(4, MAX_STATEMENT_BYTES / 3));

        assert_eq!(statements.len(), 2, "two rows fit a statement");
        let wide = run(
            &mut InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &[], false).expect("a column"),
            &columns,
            &rows(1, MAX_STATEMENT_BYTES * 2),
        );
        assert_eq!(wide.len(), 1);
    }

    #[test]
    fn a_numbered_column_turns_the_identity_insert_on_for_the_table_and_off_after() {
        let columns = [text("id"), text("b")];
        let info = [info("id", false, true), info("b", false, false)];
        let mut batch =
            InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &info, true).expect("a column");

        let statements = run(&mut batch, &columns, &rows(2, 1));

        assert_eq!(statements.first().map(String::as_str), Some("IDENTITY t true"));
        assert_eq!(statements.last().map(String::as_str), Some("IDENTITY t false"));
        assert_eq!(statements.len(), 4, "one row a statement: {statements:?}");
    }

    #[test]
    fn a_row_of_computed_columns_goes_in_as_defaults() {
        let columns = [text("n")];
        let info = [info("n", true, false)];
        let mut batch =
            InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &info, false).expect("a default row");

        let statements = run(&mut batch, &columns, &[vec![Value::Int(42)], vec![Value::Int(42)]]);

        assert_eq!(
            statements,
            ["INSERT INTO t DEFAULT VALUES", "INSERT INTO t DEFAULT VALUES"]
        );
    }

    #[test]
    fn an_empty_table_writes_nothing() {
        let columns = [text("id")];
        let info = [info("id", false, true)];
        let mut batch =
            InsertBatch::new(&TestDialect::default(), "t".to_owned(), &columns, &info, false).expect("a column");

        assert!(run(&mut batch, &columns, &[]).is_empty());
    }
}
