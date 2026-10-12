use crate::column::{
    BoolStorage, CatalogType, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm,
    SqlExpression, SqlTypeExpr, TemporalZone, TextLength, classify_type_name, has_dynamic_storage,
};
use crate::meta::{EngineRowId, EngineRowIdPart};
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
/// written once. It stands in until each driver crate has its own
/// dialect, and goes when the last one does.
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
            // nothing useful about how many rows it touched, and SQL
            // Server adds the rows its triggers touch to the count, so
            // a write on either proves itself with a probe.
            exact_row_counts: !matches!(self.driver_id, "clickhouse" | "mssql"),
        }
    }

    fn grammar(&self) -> SqlGrammar {
        self.grammar
    }

    fn quote_identifier(&self, name: &str) -> String {
        quote_ident(self.driver_id, name)
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let (param_type, cast) = match target {
            BindTarget::Pattern => (ParamType::Text, None),
            BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid) => (ParamType::Int64, None),
            // A PostgreSQL row address travels as text and is cast back
            // to its own type, which has no binary form the binder knows.
            BindTarget::EngineRowId(part) => {
                let cast = postgres_row_id_type(part);
                (ParamType::ServerText(SqlTypeExpr::from_catalog_text(cast)), Some(cast))
            }
            BindTarget::Column(column) => (param_type_for(column)?, None),
        };
        let param = BoundParam::new(value, param_type)?;
        let marker = marker(self.driver_id, ordinal);
        let sql = match cast {
            Some(cast) => format!("{marker}::{cast}"),
            None => marker,
        };
        Ok(Placeholder::bound(sql, param))
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
        let escapes: &[char] = match self.driver_id {
            // ClickHouse reads a backslash as the escape and has no
            // ESCAPE clause to name another.
            "clickhouse" => &['\\', '%', '_'],
            // `[` opens a character class in T-SQL patterns.
            "mssql" => &['!', '%', '_', '['],
            _ => &['!', '%', '_'],
        };
        let escape = match self.driver_id {
            "clickhouse" => '\\',
            _ => '!',
        };
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if escapes.contains(&character) {
                escaped.push(escape);
            }
            escaped.push(character);
        }
        escaped
    }

    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let insensitive = matches!(form.case, LikeCase::Insensitive);
        // PostgreSQL and ClickHouse spell it ILIKE. Elsewhere LOWER() on
        // both sides is what makes it certain whatever the collation.
        let (left, right, operator) = match (insensitive, self.driver_id) {
            (true, "postgres" | "clickhouse") => (column_sql.to_owned(), pattern_sql.to_owned(), "ILIKE"),
            (true, _) => (format!("LOWER({column_sql})"), format!("LOWER({pattern_sql})"), "LIKE"),
            (false, _) => (column_sql.to_owned(), pattern_sql.to_owned(), "LIKE"),
        };
        let operator = match form.negated {
            true => format!("NOT {operator}"),
            false => operator.to_owned(),
        };
        match (form.escaped, self.driver_id) {
            (true, "clickhouse") | (false, _) => format!("{left} {operator} {right}"),
            (true, _) => format!("{left} {operator} {right} ESCAPE '!'"),
        }
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        let order_by = order_by.map(str::trim).filter(|order| !order.is_empty());
        // OFFSET … FETCH is a suffix of ORDER BY in T-SQL, so a page
        // with no sort still needs one; `(SELECT NULL)` orders nothing.
        if self.driver_id == "mssql" {
            let order = order_by.unwrap_or("(SELECT NULL)");
            return format!(" ORDER BY {order} OFFSET {offset} ROWS FETCH NEXT {limit} ROWS ONLY");
        }
        match order_by {
            Some(order) => format!(" ORDER BY {order} LIMIT {limit} OFFSET {offset}"),
            None => format!(" LIMIT {limit} OFFSET {offset}"),
        }
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
        let projections: Option<Vec<String>> = id
            .parts()
            .iter()
            .map(|part| {
                let column = self.engine_row_id_column(*part)?;
                let alias = self.quote_identifier(part.projection_alias());
                // The PostgreSQL address types have no binary form the
                // driver decodes, so they are read as their text.
                Some(match self.driver_id {
                    "postgres" => format!("{column}::text AS {alias}"),
                    _ => format!("{column} AS {alias}"),
                })
            })
            .collect();
        projections.map(|projections| projections.join(", "))
    }

    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
        match (self.driver_id, part) {
            ("postgres", EngineRowIdPart::PostgresCtid) => Some("ctid".to_owned()),
            ("postgres", EngineRowIdPart::PostgresTableOid) => Some("tableoid".to_owned()),
            ("postgres", EngineRowIdPart::PostgresXmin) => Some("xmin".to_owned()),
            ("sqlite", EngineRowIdPart::SqliteRowid) => Some("rowid".to_owned()),
            _ => None,
        }
    }

    fn count_all(&self) -> &'static str {
        match self.driver_id {
            // COUNT(*) is an int on SQL Server and overflows past two
            // billion rows.
            "mssql" => "COUNT_BIG(*)",
            "clickhouse" => "count()",
            _ => "COUNT(*)",
        }
    }

    fn update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        match self.driver_id {
            // Standard UPDATE only arrived in ClickHouse 25.7; the
            // mutation spelling works on every supported release.
            "clickhouse" => format!("ALTER TABLE {table_sql} UPDATE {assignments_sql} WHERE {predicate_sql}"),
            _ => format!("UPDATE {table_sql} SET {assignments_sql} WHERE {predicate_sql}"),
        }
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
            // The lock hints hold the probed key until commit, so the
            // row cannot change between the probe and the write.
            "mssql" => format!(
                "SELECT COUNT_BIG(*) FROM (SELECT TOP (2) 1 AS one FROM {table_sql} WITH (UPDLOCK, HOLDLOCK) WHERE {predicate_sql}) AS probe"
            ),
            // No FINAL, so unmerged duplicates of a sorting key count.
            "clickhouse" => format!("SELECT count() FROM (SELECT 1 FROM {table_sql} WHERE {predicate_sql} LIMIT 2)"),
            _ => format!(
                "SELECT COUNT(*) FROM (SELECT 1 AS one FROM {table_sql} WHERE {predicate_sql} LIMIT 2) AS probe"
            ),
        }
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(self.grammar, text, MAX_TYPE_LEN)?;
        let kind = classify_type_name(&parsed.text);
        let declaration = SqlTypeExpr::from_catalog_text(parsed.text.as_str());
        Ok(ColumnType {
            dynamic_storage: has_dynamic_storage(&kind),
            kind,
            // Before the column exists its declaration is the only
            // spelling there is, and nothing binds against a draft.
            catalog: Some(CatalogType {
                cast_target: declaration.clone(),
                declaration,
            }),
            name: parsed.text,
            read_form: ReadForm::Native,
        })
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(self.grammar, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }
}

pub(crate) fn quote_ident(driver_id: &str, name: &str) -> String {
    match driver_id {
        "mysql" => format!("`{}`", name.replace('`', "``")),
        "clickhouse" => quote_clickhouse_ident(name),
        "mssql" => format!("[{}]", name.replace(']', "]]")),
        _ => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

/// ClickHouse's lexer reads a backslash inside backticks as an escape,
/// so doubling the delimiter alone lets `\`` close the identifier early.
fn quote_clickhouse_ident(name: &str) -> String {
    let mut quoted = String::with_capacity(name.len() + 2);
    quoted.push('`');
    for character in name.chars() {
        if matches!(character, '\\' | '\'' | '`' | '\t' | '\n') {
            quoted.push('\\');
        }
        quoted.push(character);
    }
    quoted.push('`');
    quoted
}

/// The marker for the parameter at `ordinal`, which counts the ones
/// already bound.
fn marker(driver_id: &str, ordinal: usize) -> String {
    match driver_id {
        "postgres" => format!("${}", ordinal + 1),
        "mssql" => format!("@P{}", ordinal + 1),
        _ => "?".to_owned(),
    }
}

fn postgres_row_id_type(part: EngineRowIdPart) -> &'static str {
    match part {
        EngineRowIdPart::PostgresTableOid => "oid",
        EngineRowIdPart::PostgresXmin => "xid",
        EngineRowIdPart::PostgresCtid | EngineRowIdPart::SqliteRowid => "tid",
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
fn param_type_for(column: &ColumnInfo) -> Result<ParamType, BindError> {
    let column_type = &column.column_type;
    Ok(match &column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => ParamType::Bool,
        ColumnKind::Bool(BoolStorage::Integer) => ParamType::Int64,
        ColumnKind::Integer(kind) => integer_param_type(*kind),
        ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => ParamType::Decimal,
        ColumnKind::Float(FloatWidth::F32) => ParamType::Float32,
        ColumnKind::Float(FloatWidth::F64) => ParamType::Float64,
        ColumnKind::Text {
            length: TextLength::Fixed(_),
        } => ParamType::FixedText,
        ColumnKind::Bytes { .. } => ParamType::Bytes,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time { with_offset: false, .. } => ParamType::Time,
        ColumnKind::Time { with_offset: true, .. } => ParamType::TimeTz,
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => ParamType::TimestampTz,
        ColumnKind::Timestamp { .. } => ParamType::Timestamp,
        ColumnKind::Interval => ParamType::Interval,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Json { binary: false } => ParamType::Json,
        ColumnKind::Json { binary: true } => ParamType::JsonBinary,
        // A type only the server names binds as text and is cast on the
        // way in, to the type the catalogue gave: guessing a cast from
        // the display name could pick the wrong type.
        ColumnKind::Enum { .. }
        | ColumnKind::Network(_)
        | ColumnKind::Xml
        | ColumnKind::Spatial
        | ColumnKind::Variant
        | ColumnKind::Composite
        | ColumnKind::Other => match &column_type.catalog {
            Some(catalog) => ParamType::ServerText(catalog.cast_target.clone()),
            None => {
                return Err(BindError::MissingCatalogType {
                    column: column.name.clone(),
                });
            }
        },
        ColumnKind::Text { .. } | ColumnKind::BitString { .. } | ColumnKind::Array { .. } => ParamType::Text,
    })
}

fn integer_param_type(kind: IntegerKind) -> ParamType {
    match (kind.width, kind.signed) {
        (IntegerWidth::W8 | IntegerWidth::W16, true) | (IntegerWidth::W8, false) => ParamType::Int16,
        (IntegerWidth::W24 | IntegerWidth::W32, true) | (IntegerWidth::W16 | IntegerWidth::W24, false) => {
            ParamType::Int32
        }
        (IntegerWidth::W64 | IntegerWidth::W128 | IntegerWidth::W256, false) => ParamType::UInt64,
        (IntegerWidth::W64 | IntegerWidth::W128 | IntegerWidth::W256, true) | (IntegerWidth::W32, false) => {
            ParamType::Int64
        }
    }
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
    fn postgres_and_clickhouse_spell_it_ilike() {
        let insensitive = LikeForm::insensitive(false);

        assert_eq!(
            dialect_for("postgres").like_predicate("\"a\"", "$1", insensitive),
            "\"a\" ILIKE $1"
        );
        assert_eq!(
            dialect_for("clickhouse").like_predicate("`a`", "'x'", insensitive),
            "`a` ILIKE 'x'"
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
            Some(
                r#"tableoid::text AS "__tablepro_row_oid", ctid::text AS "__tablepro_row_id", xmin::text AS "__tablepro_row_xmin""#
                    .to_owned()
            )
        );
        assert_eq!(
            dialect_for("sqlite").engine_row_id(EngineRowId::SqliteRowid),
            Some(r#"rowid AS "__tablepro_row_id""#.to_owned())
        );
        assert_eq!(dialect_for("mysql").engine_row_id(EngineRowId::SqliteRowid), None);
    }

    #[test]
    fn a_postgres_row_address_is_cast_back_to_its_own_type() {
        let placeholder = dialect_for("postgres")
            .placeholder(
                2,
                Value::Text("742".to_owned()),
                BindTarget::EngineRowId(EngineRowIdPart::PostgresXmin),
            )
            .expect("a bound xmin");

        assert_eq!(placeholder.sql, "$3::xid");
        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::ServerText(SqlTypeExpr::from_catalog_text("xid")))
        );
    }

    #[test]
    fn markers_count_from_the_parameters_already_bound() {
        let column = info(
            ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            None,
        );
        let text = || Value::Text("x".to_owned());

        let first = dialect_for("postgres").placeholder(0, text(), BindTarget::Column(&column));
        let third = dialect_for("mssql").placeholder(2, text(), BindTarget::Column(&column));

        assert_eq!(first.map(|placeholder| placeholder.sql), Ok("$1".to_owned()));
        assert_eq!(third.map(|placeholder| placeholder.sql), Ok("@P3".to_owned()));
    }

    #[test]
    fn sql_server_counts_with_count_big() {
        let statement = crate::browse::build_count(
            dialect_for("mssql"),
            &crate::meta::TableRef::new(Some("dbo".to_owned()), "orders"),
            &[],
            &crate::filter::FilterSet::default(),
        )
        .expect("the count");

        assert_eq!(statement.sql(), "SELECT COUNT_BIG(*) FROM [dbo].[orders]");
        assert!(
            dialect_for("mssql")
                .key_probe("t", "p")
                .starts_with("SELECT COUNT_BIG(*)")
        );
        assert_eq!(dialect_for("postgres").count_all(), "COUNT(*)");
    }

    #[test]
    fn like_escapes_with_bang_except_on_clickhouse() {
        let contains = LikeForm::contains();

        assert_eq!(dialect_for("postgres").escape_like_text("5!0%_"), "5!!0!%!_");
        assert_eq!(dialect_for("mssql").escape_like_text("[a]"), "![a]");
        assert_eq!(dialect_for("clickhouse").escape_like_text("a\\%_"), "a\\\\\\%\\_");
        assert_eq!(
            dialect_for("sqlite").like_predicate("\"a\"", "?", contains),
            "\"a\" LIKE ? ESCAPE '!'"
        );
        assert_eq!(
            dialect_for("clickhouse").like_predicate("`a`", "'x'", contains),
            "`a` LIKE 'x'",
            "ClickHouse got an ESCAPE clause"
        );
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
        let column = ColumnType::untyped_text("text");

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
        let column = ColumnType::untyped_text("bytea");

        let error = dialect.literal(&Value::Bytes(vec![0xff]), &column).expect_err("a blob");

        assert_eq!(error, LiteralError::Unrepresentable { found: "Bytes" });
    }

    #[test]
    fn sql_server_has_no_boolean_literal() {
        let column = ColumnType::untyped_text("bit");

        assert_eq!(
            dialect_for("mssql").literal(&Value::Bool(true), &column),
            Ok("1".to_owned())
        );
        assert_eq!(
            dialect_for("postgres").literal(&Value::Bool(true), &column),
            Ok("true".to_owned())
        );
    }

    fn info(kind: ColumnKind, catalog: Option<&str>) -> ColumnInfo {
        ColumnInfo {
            name: "mood".to_owned(),
            column_type: ColumnType {
                name: "mood".to_owned(),
                kind,
                catalog: catalog.map(|text| CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text(text),
                    cast_target: SqlTypeExpr::from_catalog_text(text),
                }),
                dynamic_storage: true,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: crate::column::ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn a_server_named_type_binds_as_text_cast_to_its_catalogue_type() {
        let mood = info(
            ColumnKind::Enum {
                labels: vec!["happy".to_owned()],
                multiple: false,
            },
            Some("public.mood"),
        );

        let placeholder = dialect_for("postgres")
            .placeholder(1, Value::Text("happy".to_owned()), BindTarget::Column(&mood))
            .expect("a bound enum");

        assert_eq!(
            placeholder.param.as_ref().map(BoundParam::param_type),
            Some(&ParamType::ServerText(SqlTypeExpr::from_catalog_text("public.mood")))
        );
    }

    #[test]
    fn a_server_named_type_without_a_catalogue_type_is_not_guessed() {
        let mood = info(ColumnKind::Other, None);

        let error = dialect_for("postgres")
            .placeholder(1, Value::Text("happy".to_owned()), BindTarget::Column(&mood))
            .expect_err("a cast from nothing");

        assert_eq!(
            error,
            BindError::MissingCatalogType {
                column: "mood".to_owned()
            }
        );
    }

    #[test]
    fn an_offset_timestamp_binds_with_its_offset() {
        let column = info(
            ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset,
            },
            None,
        );

        let error = dialect_for("postgres")
            .placeholder(1, Value::Text("2024-06-15".to_owned()), BindTarget::Column(&column))
            .expect_err("text for a timestamptz");

        assert_eq!(
            error,
            BindError::ValueTypeMismatch {
                expected: "TimestampTz",
                found: "Text"
            }
        );
    }

    #[test]
    fn a_probe_stops_at_two_rows_on_every_engine() {
        for driver in ["postgres", "mysql", "sqlite", "mssql", "clickhouse"] {
            let probe = dialect_for(driver).key_probe("t", "id = 1");
            assert!(
                probe.contains("LIMIT 2") || probe.contains("TOP (2)"),
                "{driver}: {probe}"
            );
        }
    }
}
