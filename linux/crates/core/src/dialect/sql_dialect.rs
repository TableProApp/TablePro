use crate::column::{ColumnInfo, ColumnType, SqlExpression};
use crate::ddl::DdlDialect;
use crate::filter::{Combinator, FilterOp, operators_for};
use crate::meta::{EngineRowId, EngineRowIdPart, TableRef};
use crate::sql_syntax::{ExpressionSyntaxError, HistoryRecording, SqlGrammar, TypeSyntaxError};
use crate::value::Value;

use super::{
    BindError, BindTarget, DialectCapabilities, InsertBatchLimits, KeysetDirection, LikeCase, LikeForm, LiteralError,
    Placeholder, TablePaging,
};

/// How one engine spells SQL.
///
/// Every builder in core goes through this rather than matching on a
/// driver id, so adding an engine is a new implementation rather than a
/// new branch in the browse, filter and write paths. No method reads
/// session state or knows which driver it belongs to.
///
/// Methods that take SQL fragments must keep them in the order given:
/// the builders bind markers in that order, and an engine with
/// positional markers (`?`) matches parameters by position.
pub trait SqlDialect: Send + Sync + std::fmt::Debug {
    fn capabilities(&self) -> DialectCapabilities;

    /// The grammar the engine's SQL is written in, for validating and
    /// lexing text the user typed.
    fn grammar(&self) -> SqlGrammar;

    /// Wrap an identifier so it cannot be read as anything else,
    /// whatever it contains.
    fn quote_identifier(&self, name: &str) -> String;

    /// The statement that moves an editor session to the server's database
    /// `name`, which a query tab runs before its next statement. `None`
    /// for a name the engine's statement cannot carry whole.
    fn use_database(&self, name: &str) -> Option<String> {
        Some(format!("USE {}", self.quote_identifier(name)))
    }

    /// Bind one value, giving back the SQL that names it.
    ///
    /// `ordinal` is the number of parameters the statement already
    /// holds, so a returned parameter lands at that index in
    /// `Statement::params`. A numbered engine renders `$<ordinal + 1>`;
    /// one with named server-side parameters names it from the ordinal
    /// (ClickHouse `{p<ordinal>:<type>}`) and the driver binds
    /// `params[i]` under the same name. An engine with no parameters
    /// returns a literal and no parameter.
    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError>;

    /// A value written into SQL directly, for the places a parameter
    /// cannot go.
    fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError>;

    /// Escape the wildcards in text the app is turning into a pattern,
    /// so a user searching for `50%` does not match everything.
    fn escape_like_text(&self, text: &str) -> String;

    /// The ORDER BY and row-window tail of a page query. It starts with
    /// a space, because the builders append it straight after the FROM
    /// or WHERE clause.
    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String;

    /// The comparison that reads the page after (or before) a row,
    /// given the key columns and the markers bound to its values.
    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String;

    /// The extra columns a page selects to carry the engine's own row
    /// address, one per part in `EngineRowId::parts` order, or `None`
    /// where the engine has none.
    fn engine_row_id(&self, id: EngineRowId) -> Option<String>;

    /// The column one part of that address is compared against in a
    /// predicate.
    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String>;

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError>;

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError>;

    /// Whether SQL the user ran may be kept in the query history. Each
    /// engine names the statements that can hold a password or a
    /// connection secret (`classify_for_history` with its own
    /// `CredentialRules`), and those are never recorded.
    fn history_recording(&self, sql: &str) -> HistoryRecording;

    /// The engine's structure-change spelling, or `None` where the app
    /// does not edit this engine's structure.
    fn ddl(&self) -> Option<&dyn DdlDialect> {
        None
    }

    /// How a page of a table is read. Where the server pages, a page
    /// carries no ORDER BY and no window, so a user sort is not offered.
    fn table_paging(&self) -> TablePaging {
        TablePaging::InStatement
    }

    /// Words a read with a WHERE clause takes at its end, such as CQL's
    /// ALLOW FILTERING, without which a condition on anything but the
    /// key is refused.
    fn filtered_read_suffix(&self) -> &'static str {
        ""
    }

    /// The filter operators the engine evaluates on the column, in the
    /// order the filter strip lists them.
    fn filter_operators(&self, column: &ColumnInfo) -> &'static [FilterOp] {
        operators_for(&column.column_type.kind)
    }

    /// How the engine joins filter rules. CQL has no OR.
    fn filter_combinators(&self) -> &'static [Combinator] {
        &[Combinator::And, Combinator::Or]
    }

    /// A raw predicate the user wrote, as it joins the generated rules.
    /// The parentheses keep its own OR from binding to them.
    fn raw_predicate_sql(&self, raw: &str) -> String {
        format!("({raw})")
    }

    fn qualify(&self, table: &TableRef) -> String {
        match table.schema.as_deref().filter(|schema| !schema.is_empty()) {
            Some(schema) => format!(
                "{}.{}",
                self.quote_identifier(schema),
                self.quote_identifier(&table.name)
            ),
            None => self.quote_identifier(&table.name),
        }
    }

    /// The table's name as text that stands outside this connection: in
    /// an export replayed elsewhere, and in a foreign key's REFERENCES.
    /// DuckDB names its file's catalogue in `qualify` and leaves it out
    /// here; the other engines name the table the same in both.
    fn portable_name(&self, table: &TableRef) -> String {
        self.qualify(table)
    }

    /// How a column is selected. A type the driver cannot decode is
    /// asked for as text instead, which is what `read_form` says.
    fn projection(&self, column: &ColumnInfo) -> String {
        self.quote_identifier(&column.name)
    }

    fn sort_expression(&self, table: &TableRef, column: &ColumnInfo) -> String {
        format!(
            "{}.{}",
            self.quote_identifier(&table.name),
            self.quote_identifier(&column.name)
        )
    }

    fn count_all(&self) -> &'static str {
        "COUNT(*)"
    }

    /// Whether ordering by the table's key sorts the whole table before
    /// the first row comes back, while a plain scan returns an unchanged
    /// table's rows in the same order every time. An export with no sort
    /// of the user's then keeps the scan's order.
    fn key_order_sorts_the_table(&self) -> bool {
        false
    }

    /// The column as text, where it meets a LIKE pattern or text the user
    /// typed, for a type the engine will not compare with text as it is.
    /// `None` when the column takes text as it is.
    fn text_operand(&self, _column: &ColumnInfo) -> Option<String> {
        None
    }

    /// Whether `=` and `IN` have to compare `text_operand`, because the
    /// type has no equality of its own.
    fn equality_as_text(&self, _column: &ColumnInfo) -> bool {
        false
    }

    /// The column where it meets a bound value of its own type, for a
    /// type the engine compares only once it is cast to another. `None`
    /// when the column compares as it is.
    fn compared_operand(&self, _column: &ColumnInfo) -> Option<String> {
        None
    }

    /// `!` rather than a backslash: a backslash means something else
    /// inside a string literal under some PostgreSQL and MySQL session
    /// modes, and is no escape at all on SQLite and SQL Server.
    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let operator = match (form.negated, form.case) {
            (false, LikeCase::EngineDefault) => "LIKE",
            (true, LikeCase::EngineDefault) => "NOT LIKE",
            (false, LikeCase::Insensitive) => "ILIKE",
            (true, LikeCase::Insensitive) => "NOT ILIKE",
        };
        match form.escaped {
            true => format!("{column_sql} {operator} {pattern_sql} ESCAPE '!'"),
            false => format!("{column_sql} {operator} {pattern_sql}"),
        }
    }

    fn update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        format!("UPDATE {table_sql} SET {assignments_sql} WHERE {predicate_sql}")
    }

    /// An UPDATE of columns that hold one value per partition (CQL
    /// static columns), `predicate_sql` naming the partition. A save
    /// proves its row with a probe, so it carries no condition.
    fn partition_update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        self.update_statement(table_sql, assignments_sql, predicate_sql)
    }

    fn delete_statement(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!("DELETE FROM {table_sql} WHERE {predicate_sql}")
    }

    /// An INSERT of `rows_sql`, each row a parenthesised list of
    /// markers in `columns_sql` order.
    fn insert_statement(&self, table_sql: &str, columns_sql: &str, rows_sql: &str) -> String {
        format!("INSERT INTO {table_sql} ({columns_sql}) VALUES {rows_sql}")
    }

    /// Whether an INSERT names a column whose value is NULL. An engine
    /// that answers false has the column left out, as CQL does: an absent
    /// cell reads as NULL without the tombstone a written one leaves, and
    /// a partition's static row has no clustering value to write.
    fn insert_names_null_cells(&self) -> bool {
        true
    }

    /// How much one multi-row INSERT may carry.
    fn insert_batch_limits(&self) -> InsertBatchLimits {
        InsertBatchLimits::DEFAULT
    }

    /// Insert a row of nothing but defaults, where the engine has a
    /// spelling for it.
    fn insert_default_row(&self, table_sql: &str) -> Option<String> {
        Some(format!("INSERT INTO {table_sql} DEFAULT VALUES"))
    }

    /// The clause between an INSERT's columns and VALUES that lets it set
    /// a column the engine numbers, where the engine refuses one without.
    fn insert_overriding_clause(&self) -> Option<&'static str> {
        None
    }

    /// The lines, `;` and all, that let the INSERTs after them set the
    /// table's identity column, or end that (`on` false), where the engine
    /// refuses a value there otherwise. An engine that runs a script batch
    /// by batch ends it in a batch of its own, so a run that fails partway
    /// still turns it off.
    fn identity_insert(&self, _table_sql: &str, _on: bool) -> Option<String> {
        None
    }

    /// Count the rows a predicate matches, stopping at two: the caller
    /// only needs to know whether it is exactly one.
    fn key_probe(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!("SELECT COUNT(*) FROM (SELECT 1 AS one FROM {table_sql} WHERE {predicate_sql} LIMIT 2) AS probe")
    }
}
