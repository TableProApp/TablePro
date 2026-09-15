use crate::column::{ColumnInfo, ColumnType, SqlExpression, SqlTypeExpr, classify_type_name, has_dynamic_storage};
use crate::edit::parse_literal_text;
use crate::meta::{EngineRowId, EngineRowIdPart};
use crate::sql_dialect::{placeholder_for, quote_ident};
use crate::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use crate::statement::{BoundParam, ParamType};
use crate::value::Value;

use super::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LikeCase, LikeForm, LiteralError, Placeholder,
    SqlDialect,
};

/// One engine's SQL, built from the driver id the registry knows it by.
///
/// Every difference between the engines lives here rather than in a
/// branch inside a builder, so the browse, filter and write paths are
/// written once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EngineDialect {
    driver_id: &'static str,
    grammar: SqlGrammar,
}

const POSTGRES: EngineDialect = EngineDialect {
    driver_id: "postgres",
    grammar: SqlGrammar::PostgreSql,
};
const MYSQL: EngineDialect = EngineDialect {
    driver_id: "mysql",
    grammar: SqlGrammar::MySql,
};
const SQLITE: EngineDialect = EngineDialect {
    driver_id: "sqlite",
    grammar: SqlGrammar::Sqlite,
};
const MSSQL: EngineDialect = EngineDialect {
    driver_id: "mssql",
    grammar: SqlGrammar::MsSql,
};
const CLICKHOUSE: EngineDialect = EngineDialect {
    driver_id: "clickhouse",
    grammar: SqlGrammar::ClickHouse,
};

/// The dialect for a driver id, defaulting to the ANSI-shaped one so an
/// engine added later still builds working SQL before it has its own.
pub fn dialect_for(driver_id: &str) -> &'static dyn SqlDialect {
    match driver_id {
        "mysql" => &MYSQL,
        "sqlite" => &SQLITE,
        "mssql" => &MSSQL,
        "clickhouse" => &CLICKHOUSE,
        _ => &POSTGRES,
    }
}

impl EngineDialect {
    pub fn driver_id(&self) -> &'static str {
        self.driver_id
    }

    pub fn grammar(&self) -> SqlGrammar {
        self.grammar
    }
}

/// The grammar a driver's SQL is written in, for lexing a script the
/// user typed.
pub fn grammar_for(driver_id: &str) -> SqlGrammar {
    match driver_id {
        "mysql" => MYSQL.grammar,
        "sqlite" => SQLITE.grammar,
        "mssql" => MSSQL.grammar,
        "clickhouse" => CLICKHOUSE.grammar,
        _ => POSTGRES.grammar,
    }
}

impl SqlDialect for EngineDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities {
            // ClickHouse applies a change as a mutation and reports
            // nothing useful about how many rows it touched, so a
            // write there proves itself with a probe.
            exact_row_counts: self.driver_id != "clickhouse",
        }
    }

    fn quote_identifier(&self, name: &str) -> String {
        quote_ident(self.driver_id, name)
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let param_type = match target {
            BindTarget::Pattern => ParamType::Text,
            // A row address is text the server parses back into its own
            // address type.
            BindTarget::EngineRowId(_) => ParamType::Text,
            BindTarget::Column(column) => param_type_for(&column.column_type),
        };
        let param = BoundParam::new(value, param_type)?;
        // `placeholder_for` counts from zero.
        Ok(Placeholder::bound(
            placeholder_for(self.driver_id, ordinal.saturating_sub(1)),
            param,
        ))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        match value {
            Value::Null => Ok("NULL".to_owned()),
            Value::Bool(flag) => Ok(match self.driver_id {
                // SQL Server has no boolean literal; BIT takes 0 or 1.
                "mssql" => if *flag { "1" } else { "0" }.to_owned(),
                _ => flag.to_string(),
            }),
            Value::Undecodable(undecodable) => Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            }),
            // Bytes have a different spelling on every engine, and
            // getting it wrong writes the wrong data rather than
            // failing, so it is refused here.
            Value::Bytes(_) => Err(LiteralError::Unrepresentable { found: "Bytes" }),
            other => match crate::export::value_to_text(other) {
                Some(text) if is_bare_literal(other) => Ok(text),
                Some(text) => Ok(format!("'{}'", text.replace('\'', "''"))),
                None => Err(LiteralError::Unrepresentable {
                    found: other.variant_name(),
                }),
            },
        }
    }

    fn escape_like_text(&self, text: &str) -> String {
        text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_")
    }

    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let insensitive = matches!(form.case, LikeCase::Insensitive);
        // Only PostgreSQL spells it ILIKE. Elsewhere the collation
        // usually already ignores case, and LOWER() on both sides is
        // what makes it certain without an engine-specific operator.
        let (left, right, operator) = match (insensitive, self.driver_id) {
            (true, "postgres") => (column_sql.to_owned(), pattern_sql.to_owned(), "ILIKE"),
            (true, _) => (format!("LOWER({column_sql})"), format!("LOWER({pattern_sql})"), "LIKE"),
            (false, _) => (column_sql.to_owned(), pattern_sql.to_owned(), "LIKE"),
        };
        let operator = match form.negated {
            true => format!("NOT {operator}"),
            false => operator.to_owned(),
        };
        match form.escaped {
            true => format!("{left} {operator} {right} ESCAPE '\\'"),
            false => format!("{left} {operator} {right}"),
        }
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        crate::sql_dialect::build_order_and_pagination(self.driver_id, order_by, limit, offset)
    }

    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        let comparison = direction.comparison();
        // SQL Server has no row-value comparison, so it gets the
        // expanded form: the same predicate, written out.
        if self.driver_id == "mssql" {
            return expanded_row_comparison(key_sql, markers, comparison);
        }
        format!("({}) {comparison} ({})", key_sql.join(", "), markers.join(", "))
    }

    fn engine_row_id(&self, id: EngineRowId) -> Option<String> {
        match (self.driver_id, id) {
            ("postgres", EngineRowId::PostgresCtid) => Some("ctid".to_owned()),
            ("postgres", EngineRowId::PostgresTableoidCtid) => Some("tableoid, ctid".to_owned()),
            ("sqlite", EngineRowId::SqliteRowid) => Some("rowid".to_owned()),
            _ => None,
        }
    }

    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
        match (self.driver_id, part) {
            ("postgres", EngineRowIdPart::PostgresCtid) => Some("ctid".to_owned()),
            ("postgres", EngineRowIdPart::PostgresTableOid) => Some("tableoid".to_owned()),
            ("sqlite", EngineRowIdPart::SqliteRowid) => Some("rowid".to_owned()),
            _ => None,
        }
    }

    fn update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        crate::sql_dialect::build_update(self.driver_id, table_sql, assignments_sql, predicate_sql)
    }

    fn delete_statement(&self, table_sql: &str, predicate_sql: &str) -> String {
        match self.driver_id {
            // ClickHouse applies a delete as a mutation.
            "clickhouse" => format!("ALTER TABLE {table_sql} DELETE WHERE {predicate_sql}"),
            _ => format!("DELETE FROM {table_sql} WHERE {predicate_sql}"),
        }
    }

    fn insert_default_row(&self, table_sql: &str) -> Option<String> {
        match self.driver_id {
            "postgres" | "sqlite" => Some(format!("INSERT INTO {table_sql} DEFAULT VALUES")),
            "mysql" => Some(format!("INSERT INTO {table_sql} () VALUES ()")),
            "mssql" => Some(format!("INSERT INTO {table_sql} DEFAULT VALUES")),
            // ClickHouse has no spelling for a row of nothing.
            _ => None,
        }
    }

    fn key_probe(&self, table_sql: &str, predicate_sql: &str) -> String {
        match self.driver_id {
            "mssql" => {
                format!("SELECT COUNT(*) FROM (SELECT TOP 2 1 AS one FROM {table_sql} WHERE {predicate_sql}) AS probe")
            }
            _ => format!(
                "SELECT COUNT(*) FROM (SELECT 1 AS one FROM {table_sql} WHERE {predicate_sql} LIMIT 2) AS probe"
            ),
        }
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(self.grammar, text, MAX_TYPE_LEN)?;
        let kind = classify_type_name(&parsed.text);
        Ok(ColumnType::new(
            SqlTypeExpr::from_catalog_text(parsed.text),
            kind,
            crate::column::CatalogType::Unknown,
            has_dynamic_storage(kind),
            crate::column::ReadForm::Native,
        ))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(self.grammar, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }
}

/// Whether a value's text is already a SQL literal, so quoting it would
/// make it a string instead of a number.
fn is_bare_literal(value: &Value) -> bool {
    matches!(
        value,
        Value::Int(_) | Value::UInt(_) | Value::WideInt(_) | Value::Decimal(_)
    ) || matches!(value, Value::Float32(f) if f.is_finite())
        || matches!(value, Value::Float64(f) if f.is_finite())
}

/// `(a, b) > (?, ?)` written out, for an engine that has no row-value
/// comparison: `a > ? OR (a = ? AND b > ?)`.
fn expanded_row_comparison(key_sql: &[String], markers: &[String], comparison: &str) -> String {
    let mut branches = Vec::with_capacity(key_sql.len());
    for last in 0..key_sql.len() {
        let mut terms: Vec<String> = (0..last)
            .map(|earlier| format!("{} = {}", key_sql[earlier], markers[earlier]))
            .collect();
        terms.push(format!("{} {comparison} {}", key_sql[last], markers[last]));
        branches.push(match terms.len() {
            1 => terms.remove(0),
            _ => format!("({})", terms.join(" AND ")),
        });
    }
    branches.join(" OR ")
}

/// The parameter type a column takes.
fn param_type_for(column_type: &ColumnType) -> ParamType {
    use crate::column::{ColumnKind, FloatKind, IntegerKind};

    match column_type.kind() {
        ColumnKind::Boolean => ParamType::Bool,
        ColumnKind::Integer(IntegerKind::I8 | IntegerKind::U8 | IntegerKind::I16) => ParamType::Int16,
        ColumnKind::Integer(IntegerKind::U16 | IntegerKind::I32) => ParamType::Int32,
        ColumnKind::Integer(IntegerKind::U64 | IntegerKind::U128) => ParamType::UInt64,
        ColumnKind::Integer(_) => ParamType::Int64,
        ColumnKind::Decimal => ParamType::Decimal,
        ColumnKind::Float(FloatKind::F32) => ParamType::Float32,
        ColumnKind::Float(FloatKind::F64) => ParamType::Float64,
        ColumnKind::Text(crate::column::TextKind::Fixed) => ParamType::FixedText,
        ColumnKind::Binary => ParamType::Bytes,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time => ParamType::Time,
        ColumnKind::Timestamp => ParamType::Timestamp,
        ColumnKind::Interval => ParamType::Interval,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Json => ParamType::Json,
        // A type only the server names binds as text and is cast on the
        // way in.
        ColumnKind::Enumeration | ColumnKind::Set | ColumnKind::Network | ColumnKind::Geometry | ColumnKind::Other => {
            ParamType::ServerText(column_type.name().clone())
        }
        _ => ParamType::Text,
    }
}

/// Text the user typed, as a value of the column's type.
pub fn parse_for_column(text: &str, column: &ColumnInfo) -> Result<Value, crate::edit::EditParseError> {
    parse_literal_text(text, &column.column_type)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn markers(count: usize) -> Vec<String> {
        (1..=count).map(|n| format!("${n}")).collect()
    }

    #[test]
    fn each_engine_quotes_the_way_it_reads() {
        assert_eq!(dialect_for("postgres").quote_identifier("a\"b"), "\"a\"\"b\"");
        assert_eq!(dialect_for("mysql").quote_identifier("a`b"), "`a``b`");
        assert_eq!(dialect_for("mssql").quote_identifier("a]b"), "[a]]b]");
    }

    #[test]
    fn only_postgres_spells_it_ilike() {
        let insensitive = LikeForm::insensitive(false);

        assert_eq!(
            dialect_for("postgres").like_predicate("\"a\"", "$1", insensitive),
            "\"a\" ILIKE $1"
        );
        assert_eq!(
            dialect_for("mysql").like_predicate("`a`", "?", insensitive),
            "LOWER(`a`) LIKE LOWER(?)",
            "a case-insensitive filter silently became case-sensitive"
        );
    }

    #[test]
    fn sql_server_gets_the_expanded_row_comparison() {
        let keys = vec!["\"a\"".to_owned(), "\"b\"".to_owned()];

        let expanded = dialect_for("mssql").row_value_after(&keys, &markers(2), KeysetDirection::After);
        let row_value = dialect_for("postgres").row_value_after(&keys, &markers(2), KeysetDirection::After);

        assert_eq!(expanded, "\"a\" > $1 OR (\"a\" = $1 AND \"b\" > $2)");
        assert_eq!(row_value, "(\"a\", \"b\") > ($1, $2)");
    }

    #[test]
    fn a_keyset_page_backward_flips_the_comparison() {
        let keys = vec!["\"a\"".to_owned()];

        let before = dialect_for("postgres").row_value_after(&keys, &markers(1), KeysetDirection::Before);

        assert_eq!(before, "(\"a\") < ($1)");
    }

    #[test]
    fn only_the_engines_with_a_row_address_offer_one() {
        assert_eq!(
            dialect_for("postgres").engine_row_id(EngineRowId::PostgresTableoidCtid),
            Some("tableoid, ctid".to_owned())
        );
        assert_eq!(
            dialect_for("sqlite").engine_row_id(EngineRowId::SqliteRowid),
            Some("rowid".to_owned())
        );
        assert_eq!(dialect_for("mysql").engine_row_id(EngineRowId::SqliteRowid), None);
    }

    #[test]
    fn clickhouse_counts_are_not_exact_and_it_writes_as_a_mutation() {
        let clickhouse = dialect_for("clickhouse");

        assert!(!clickhouse.capabilities().exact_row_counts);
        assert_eq!(
            clickhouse.delete_statement("t", "id = 1"),
            "ALTER TABLE t DELETE WHERE id = 1"
        );
        assert!(
            clickhouse.insert_default_row("t").is_none(),
            "an engine with no all-defaults insert offered one"
        );
    }

    #[test]
    fn a_number_is_a_bare_literal_and_text_is_quoted() {
        let dialect = dialect_for("postgres");
        let column = ColumnType::untyped_text(SqlTypeExpr::from_catalog_text("text"));

        assert_eq!(dialect.literal(&Value::Int(7), &column), Ok("7".to_owned()));
        assert_eq!(
            dialect.literal(&Value::Text("it's".to_owned()), &column),
            Ok("'it''s'".to_owned())
        );
        assert_eq!(dialect.literal(&Value::Null, &column), Ok("NULL".to_owned()));
    }

    #[test]
    fn bytes_have_no_portable_literal() {
        let dialect = dialect_for("postgres");
        let column = ColumnType::untyped_text(SqlTypeExpr::from_catalog_text("bytea"));

        let error = dialect.literal(&Value::Bytes(vec![0xff]), &column).expect_err("a blob");

        assert_eq!(error, LiteralError::Unrepresentable { found: "Bytes" });
    }

    #[test]
    fn sql_server_has_no_boolean_literal() {
        let column = ColumnType::untyped_text(SqlTypeExpr::from_catalog_text("bit"));

        assert_eq!(
            dialect_for("mssql").literal(&Value::Bool(true), &column),
            Ok("1".to_owned())
        );
        assert_eq!(
            dialect_for("postgres").literal(&Value::Bool(true), &column),
            Ok("true".to_owned())
        );
    }

    #[test]
    fn a_probe_stops_at_two_rows_on_every_engine() {
        for driver in ["postgres", "mysql", "sqlite", "mssql", "clickhouse"] {
            let probe = dialect_for(driver).key_probe("t", "id = 1");
            assert!(
                probe.contains("LIMIT 2") || probe.contains("TOP 2"),
                "{driver}: {probe}"
            );
        }
    }
}
