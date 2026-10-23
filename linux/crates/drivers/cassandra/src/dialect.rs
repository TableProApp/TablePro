use tablepro_core::column::{ColumnInfo, ColumnType, SqlExpression};
use tablepro_core::ddl::DdlDialect;
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, InsertBatchLimits, InsertConflict, KeysetDirection, LikeForm,
    LiteralError, Placeholder, SqlDialect, TablePaging,
};
use tablepro_core::filter::{Combinator, FilterOp};
use tablepro_core::meta::{EngineRowId, EngineRowIdPart, TableRef};
use tablepro_core::sql_syntax::{
    CredentialRules, ExpressionSyntaxError, HistoryRecording, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar,
    TypeSyntaxError, classify_for_history, parse_expression,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};
use tablepro_core::{ServerInfo, column::SqlTypeExpr};

use crate::cql_type::{CqlType, Native};
use crate::decode::{blob_literal, duration_literal, float_literal, quoted};

/// How CQL spells the statements the app generates.
///
/// Values travel as markers of a prepared statement, which the server
/// types by the column, so a value reaches it exactly as the column
/// takes it. A plain UPDATE of a missing row creates it and a plain
/// INSERT of a taken key replaces the row, so writes are lightweight
/// transactions, whose `IF EXISTS` and `IF NOT EXISTS` say whether the
/// row was there. ScyllaDB before 2026.1 refuses one on a table in a
/// keyspace with tablets, its default, so there a write is plain and a
/// probe for its key goes first.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CqlDialect {
    scylla: bool,
    conditional_writes: bool,
    in_outside_key: bool,
}

/// The first ScyllaDB release that takes a lightweight transaction on a
/// table with tablets.
const SCYLLA_TABLET_LWT: (u32, u32) = (2026, 1);

/// The product name a ScyllaDB server is reported under.
pub(crate) const SCYLLA_PRODUCT: &str = "ScyllaDB";

impl CqlDialect {
    pub fn new(server: &ServerInfo) -> Self {
        let scylla = server.product == SCYLLA_PRODUCT;
        let release = (server.major, server.minor);
        Self {
            scylla,
            conditional_writes: !scylla || release >= SCYLLA_TABLET_LWT,
            in_outside_key: scylla || release >= CASSANDRA_IN_OUTSIDE_KEY,
        }
    }

    fn condition<'a>(&self, condition: &'a str) -> &'a str {
        match self.conditional_writes {
            true => condition,
            false => "",
        }
    }

    fn param_type(column: &ColumnInfo, cql_type: &CqlType) -> Result<ParamType, BindError> {
        let native = cql_type.native().ok_or(BindError::Unrepresentable {
            expected: "a CQL scalar",
            found: "a collection",
        })?;
        Ok(match native {
            Native::Ascii | Native::Text => ParamType::Text,
            Native::BigInt | Native::Counter | Native::Int | Native::SmallInt | Native::TinyInt => ParamType::Int64,
            Native::Varint | Native::Decimal => ParamType::Decimal,
            Native::Float => ParamType::Float32,
            Native::Double => ParamType::Float64,
            Native::Boolean => ParamType::Bool,
            Native::Blob => ParamType::Bytes,
            Native::Uuid | Native::Timeuuid => ParamType::Uuid,
            Native::Timestamp => ParamType::TimestampTz,
            Native::Date => ParamType::Date,
            Native::Time => ParamType::Time,
            Native::Duration => ParamType::Interval,
            Native::Inet => ParamType::ServerText(declared(column)?),
        })
    }
}

/// The column's CQL type, from the catalogue's spelling of it.
pub(crate) fn column_cql_type(column: &ColumnType) -> Option<CqlType> {
    let text = column
        .catalog
        .as_ref()
        .map_or(column.name.as_str(), |catalog| catalog.declaration.as_sql());
    CqlType::parse(text)
}

fn declared(column: &ColumnInfo) -> Result<SqlTypeExpr, BindError> {
    column
        .column_type
        .catalog
        .as_ref()
        .map(|catalog| catalog.declaration.clone())
        .ok_or_else(|| BindError::MissingCatalogType {
            column: column.name.clone(),
        })
}

const COMPARED: &[FilterOp] = &[
    FilterOp::Eq,
    FilterOp::Lt,
    FilterOp::LtEq,
    FilterOp::Gt,
    FilterOp::GtEq,
    FilterOp::In,
];
/// ScyllaDB evaluates LIKE under ALLOW FILTERING; Apache Cassandra only
/// on a column with a SASI index, which nothing here can know.
const SCYLLA_TEXT: &[FilterOp] = &[
    FilterOp::Eq,
    FilterOp::Contains,
    FilterOp::StartsWith,
    FilterOp::EndsWith,
    FilterOp::Like,
    FilterOp::Lt,
    FilterOp::LtEq,
    FilterOp::Gt,
    FilterOp::GtEq,
    FilterOp::In,
];
const EQUALITY: &[FilterOp] = &[FilterOp::Eq, FilterOp::In];
/// Cassandra before 5.0 refuses IN on a column outside the key, under
/// ALLOW FILTERING too.
const COMPARED_WITHOUT_IN: &[FilterOp] = &[FilterOp::Eq, FilterOp::Lt, FilterOp::LtEq, FilterOp::Gt, FilterOp::GtEq];
/// A duration has no order, so it can only be matched; so is a value
/// without one where IN is refused.
const DURATION: &[FilterOp] = &[FilterOp::Eq];

/// The first Apache Cassandra release that filters a column outside the
/// key with IN.
const CASSANDRA_IN_OUTSIDE_KEY: (u32, u32) = (5, 0);

impl SqlDialect for CqlDialect {
    fn capabilities(&self) -> DialectCapabilities {
        match self.conditional_writes {
            true => DialectCapabilities {
                exact_row_counts: true,
                insert_conflict: InsertConflict::Skipped,
            },
            false => DialectCapabilities {
                exact_row_counts: false,
                insert_conflict: InsertConflict::Replaced,
            },
        }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::Cql
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("\"{}\"", name.replace('"', "\"\""))
    }

    /// A collection or tuple has no parameter type the app holds a value
    /// in, so a key of one goes inline as the literal of its own value.
    fn placeholder(&self, _ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let column = match target {
            BindTarget::Pattern => return Ok(Placeholder::bound("?", BoundParam::new(value, ParamType::Text)?)),
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a CQL value",
                    found: "an engine row address",
                });
            }
            BindTarget::Column(column) => column,
        };
        let cql_type = column_cql_type(&column.column_type).ok_or_else(|| BindError::MissingCatalogType {
            column: column.name.clone(),
        })?;
        if cql_type.native().is_none() {
            return match cql_type.is_opaque_composite() {
                true => Err(BindError::Unrepresentable {
                    expected: "a value the app can write",
                    found: "a map or a user-defined type",
                }),
                false => literal_of(&value, &cql_type)
                    .map(Placeholder::inline)
                    .map_err(|error| match error {
                        LiteralError::Undecodable { reason } => BindError::Undecodable { reason },
                        LiteralError::Unrepresentable { found } => BindError::Unrepresentable {
                            expected: "a CQL collection",
                            found,
                        },
                    }),
            };
        }
        let param_type = Self::param_type(column, &cql_type)?;
        Ok(Placeholder::bound("?", BoundParam::new(value, param_type)?))
    }

    fn literal(&self, value: &Value, column: &ColumnType) -> Result<String, LiteralError> {
        match column_cql_type(column) {
            Some(cql_type) => literal_of(value, &cql_type),
            None => scalar_literal(value),
        }
    }

    /// ScyllaDB reads a backslash as the escape of `%` and `_`, measured.
    fn escape_like_text(&self, text: &str) -> String {
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if matches!(character, '\\' | '%' | '_') {
                escaped.push('\\');
            }
            escaped.push(character);
        }
        escaped
    }

    /// CQL has no ESCAPE clause, NOT LIKE or ILIKE; the operators offered
    /// never ask for one.
    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, _form: LikeForm) -> String {
        format!("{column_sql} LIKE {pattern_sql}")
    }

    /// A table is paged by the server's paging state (`table_paging`), so
    /// no page window comes through here. A LIMIT is all CQL has.
    fn row_window(&self, order_by: Option<&str>, limit: u64, _offset: u64) -> String {
        match order_by.map(str::trim).filter(|order| !order.is_empty()) {
            Some(order) => format!(" ORDER BY {order} LIMIT {limit}"),
            None => format!(" LIMIT {limit}"),
        }
    }

    /// CQL compares clustering columns as a tuple.
    fn row_value_after(&self, key_sql: &[String], markers: &[String], direction: KeysetDirection) -> String {
        format!(
            "({}) {} ({})",
            key_sql.join(", "),
            direction.comparison(),
            markers.join(", ")
        )
    }

    fn engine_row_id(&self, _id: EngineRowId) -> Option<String> {
        None
    }

    fn engine_row_id_column(&self, _part: EngineRowIdPart) -> Option<String> {
        None
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let text = text.trim();
        if text.is_empty() {
            return Err(TypeSyntaxError::Empty);
        }
        if text.chars().count() > MAX_TYPE_LEN {
            return Err(TypeSyntaxError::TooLong { max: MAX_TYPE_LEN });
        }
        if text.contains("--") || text.contains("//") || text.contains("/*") {
            return Err(TypeSyntaxError::Comment);
        }
        let parsed = CqlType::parse(text).ok_or(TypeSyntaxError::Invalid)?;
        Ok(parsed.column_type(None))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::Cql, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn history_recording(&self, sql: &str) -> HistoryRecording {
        classify_for_history(SqlGrammar::Cql, &CREDENTIAL_RULES, sql)
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(self)
    }

    fn table_paging(&self) -> TablePaging {
        TablePaging::ServerState
    }

    fn filtered_read_suffix(&self) -> &'static str {
        " ALLOW FILTERING"
    }

    fn filter_operators(&self, column: &ColumnInfo) -> &'static [FilterOp] {
        let Some(native) = column_cql_type(&column.column_type).and_then(|cql_type| cql_type.native()) else {
            return &[];
        };
        let in_refused = !self.in_outside_key && !column.primary_key;
        match native {
            Native::Ascii | Native::Text if self.scylla => SCYLLA_TEXT,
            Native::Boolean | Native::Blob | Native::Uuid | Native::Inet if in_refused => DURATION,
            _ if in_refused && native != Native::Duration => COMPARED_WITHOUT_IN,
            Native::Ascii
            | Native::Text
            | Native::BigInt
            | Native::Counter
            | Native::Int
            | Native::SmallInt
            | Native::TinyInt
            | Native::Varint
            | Native::Decimal
            | Native::Float
            | Native::Double
            | Native::Timestamp
            | Native::Date
            | Native::Time
            | Native::Timeuuid => COMPARED,
            Native::Boolean | Native::Blob | Native::Uuid | Native::Inet => EQUALITY,
            Native::Duration => DURATION,
        }
    }

    fn filter_combinators(&self) -> &'static [Combinator] {
        &[Combinator::And]
    }

    /// Rules join only with AND, which nothing in the predicate can bind
    /// looser than, and CQL takes no parentheses around a conjunction.
    fn raw_predicate_sql(&self, raw: &str) -> String {
        raw.to_owned()
    }

    /// CQL takes no table-qualified column name.
    fn sort_expression(&self, _table: &TableRef, column: &ColumnInfo) -> String {
        self.quote_identifier(&column.name)
    }

    fn update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        let condition = self.condition(" IF EXISTS");
        format!("UPDATE {table_sql} SET {assignments_sql} WHERE {predicate_sql}{condition}")
    }

    /// `IF EXISTS` on an update of static columns alone asks whether the
    /// partition's static row exists, not the row the user edited, so it
    /// goes plain and the save probes for the row.
    fn partition_update_statement(&self, table_sql: &str, assignments_sql: &str, predicate_sql: &str) -> String {
        format!("UPDATE {table_sql} SET {assignments_sql} WHERE {predicate_sql}")
    }

    fn delete_statement(&self, table_sql: &str, predicate_sql: &str) -> String {
        let condition = self.condition(" IF EXISTS");
        format!("DELETE FROM {table_sql} WHERE {predicate_sql}{condition}")
    }

    fn insert_statement(&self, table_sql: &str, columns_sql: &str, rows_sql: &str) -> String {
        let condition = self.condition(" IF NOT EXISTS");
        format!("INSERT INTO {table_sql} ({columns_sql}) VALUES {rows_sql}{condition}")
    }

    /// One row per INSERT: CQL has no multi-row VALUES.
    fn insert_batch_limits(&self) -> InsertBatchLimits {
        InsertBatchLimits {
            rows: 1,
            params: 65_535,
            value_bytes: 1 << 20,
        }
    }

    fn insert_default_row(&self, _table_sql: &str) -> Option<String> {
        None
    }

    /// A row is named by its whole primary key, so the count is 0 or 1.
    fn key_probe(&self, table_sql: &str, predicate_sql: &str) -> String {
        format!("SELECT COUNT(*) FROM {table_sql} WHERE {predicate_sql}")
    }
}

/// `value` as a literal of `cql_type`.
pub(crate) fn literal_of(value: &Value, cql_type: &CqlType) -> Result<String, LiteralError> {
    let unfrozen = cql_type.unfrozen();
    match (unfrozen, value) {
        (_, Value::Null) => Ok("null".to_owned()),
        (CqlType::List(element) | CqlType::Vector(element, _), Value::Array(items)) => {
            Ok(format!("[{}]", items_literal(items, element)?))
        }
        (CqlType::Set(element), Value::Array(items)) => Ok(format!("{{{}}}", items_literal(items, element)?)),
        (CqlType::Tuple(elements), Value::Array(items)) if elements.len() == items.len() => {
            let parts = items
                .iter()
                .zip(elements)
                .map(|(item, element)| literal_of(item, element))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(format!("({})", parts.join(", ")))
        }
        // The text of a map or a user-defined type is the CQL literal the
        // driver wrote from the server's own value, and such a cell is
        // never edited, so it goes back as it came.
        (CqlType::Map(..) | CqlType::Udt(_), Value::Other(other)) => Ok(other.text.clone()),
        (CqlType::Native(Native::Inet), Value::Other(other)) => Ok(quoted(other.text.trim())),
        _ => scalar_literal(value),
    }
}

fn items_literal(items: &[Value], element: &CqlType) -> Result<String, LiteralError> {
    Ok(items
        .iter()
        .map(|item| literal_of(item, element))
        .collect::<Result<Vec<_>, _>>()?
        .join(", "))
}

fn scalar_literal(value: &Value) -> Result<String, LiteralError> {
    let unrepresentable = || LiteralError::Unrepresentable {
        found: value.variant_name(),
    };
    Ok(match value {
        Value::Null => "null".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Int(number) => number.to_string(),
        Value::UInt(number) => number.to_string(),
        Value::WideInt(number) => number.to_string(),
        Value::Float32(number) => float_literal(f64::from(*number)),
        Value::Float64(number) => float_literal(*number),
        Value::Decimal(decimal) if decimal.is_finite() => decimal.to_string(),
        Value::Text(text) => quoted(text),
        Value::Bytes(bytes) => blob_literal(bytes),
        Value::Uuid(uuid) => uuid.to_string(),
        Value::Date(Temporal::Finite(day)) => quoted(&day.format("%Y-%m-%d").to_string()),
        Value::Time(time) => quoted(&time.format(Some(9))),
        Value::TimestampTz(Temporal::Finite(instant)) => {
            quoted(&instant.utc().format("%Y-%m-%d %H:%M:%S%.3f+0000").to_string())
        }
        Value::Timestamp(Temporal::Finite(naive)) => quoted(&naive.format("%Y-%m-%d %H:%M:%S%.3f+0000").to_string()),
        Value::Interval(interval) => duration_literal(scylla::value::CqlDuration {
            months: interval.months,
            days: interval.days,
            nanoseconds: interval.microseconds.checked_mul(1_000).ok_or_else(unrepresentable)?,
        }),
        Value::Other(other) => quoted(&other.text),
        Value::Undecodable(undecodable) => {
            return Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            });
        }
        _ => return Err(unrepresentable()),
    })
}

/// Statements whose text can hold a password. `CREATE ROLE` and
/// `ALTER ROLE` carry one only with PASSWORD or HASHED PASSWORD; the
/// older `CREATE USER` and `ALTER USER` exist to set one.
const CREDENTIAL_RULES: CredentialRules = CredentialRules {
    statement_prefixes: &[&["CREATE", "USER"], &["ALTER", "USER"]],
    conditional_prefixes: &[
        (&["CREATE", "ROLE"], &["PASSWORD", "HASHED"]),
        (&["ALTER", "ROLE"], &["PASSWORD", "HASHED"]),
    ],
    carriers: &[],
};

#[cfg(test)]
mod tests {
    use chrono::{DateTime, NaiveDate};
    use tablepro_core::column::{ColumnDefault, ColumnKind};
    use tablepro_core::sql_syntax::WithholdReason;
    use tablepro_core::value::{OffsetTimestamp, SqlInterval, SqlTime};

    use super::*;

    fn dialect(product: &str) -> CqlDialect {
        CqlDialect::new(&ServerInfo::new(product, "5.0.9", 5, 0, 9))
    }

    fn column(name: &str, declaration: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.to_owned(),
            column_type: CqlType::parse(declaration)
                .expect("a CQL type")
                .column_type(Some(declaration)),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            partition_scoped: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    #[test]
    fn identifiers_double_their_quotes() {
        assert_eq!(dialect("Cassandra").quote_identifier("a\"b"), "\"a\"\"b\"");
        assert_eq!(
            dialect("Cassandra").qualify(&TableRef::new(Some("Shop".to_owned()), "orders")),
            "\"Shop\".\"orders\""
        );
    }

    #[test]
    fn writes_say_whether_their_row_was_there() {
        let cql = dialect("Cassandra");

        assert_eq!(
            cql.update_statement("t", "\"a\" = ?", "\"id\" = ?"),
            "UPDATE t SET \"a\" = ? WHERE \"id\" = ? IF EXISTS"
        );
        assert_eq!(
            cql.delete_statement("t", "\"id\" = ?"),
            "DELETE FROM t WHERE \"id\" = ? IF EXISTS"
        );
        assert_eq!(
            cql.insert_statement("t", "\"id\"", "(?)"),
            "INSERT INTO t (\"id\") VALUES (?) IF NOT EXISTS"
        );
        assert_eq!(SqlDialect::capabilities(&cql).insert_conflict, InsertConflict::Skipped);
        assert!(SqlDialect::capabilities(&cql).exact_row_counts);
        assert_eq!(cql.insert_batch_limits().rows, 1);
    }

    #[test]
    fn scylla_before_2026_1_writes_plainly_and_probes_first() {
        let scylla = |major, minor| CqlDialect::new(&ServerInfo::new(SCYLLA_PRODUCT, "x", major, minor, 0));

        let old = scylla(2025, 1);
        assert_eq!(
            old.update_statement("t", "\"a\" = ?", "\"id\" = ?"),
            "UPDATE t SET \"a\" = ? WHERE \"id\" = ?"
        );
        assert_eq!(
            old.delete_statement("t", "\"id\" = ?"),
            "DELETE FROM t WHERE \"id\" = ?"
        );
        assert_eq!(
            old.insert_statement("t", "\"id\"", "(?)"),
            "INSERT INTO t (\"id\") VALUES (?)"
        );
        assert_eq!(
            SqlDialect::capabilities(&old),
            DialectCapabilities {
                exact_row_counts: false,
                insert_conflict: InsertConflict::Replaced,
            }
        );
        for current in [scylla(2026, 1), scylla(2026, 3), scylla(2027, 0)] {
            assert!(
                current.delete_statement("t", "k = ?").ends_with(" IF EXISTS"),
                "{current:?}"
            );
            assert_eq!(
                SqlDialect::capabilities(&current).insert_conflict,
                InsertConflict::Skipped
            );
        }
    }

    #[test]
    fn a_scalar_binds_as_a_marker_typed_by_the_column() {
        let cql = dialect("Cassandra");
        let bound = cql
            .placeholder(0, Value::Int(5), BindTarget::Column(&column("n", "smallint")))
            .unwrap();

        assert_eq!(bound.sql, "?");
        assert_eq!(bound.param.unwrap().param_type(), &ParamType::Int64);
        assert!(
            cql.placeholder(0, Value::Text("x".to_owned()), BindTarget::Column(&column("n", "int")))
                .is_err()
        );
    }

    #[test]
    fn a_collection_key_goes_inline_and_a_map_key_is_refused() {
        let cql = dialect("Cassandra");
        let list = Value::Array(vec![Value::Text("it's".to_owned()), Value::Text("b".to_owned())]);

        let inline = cql
            .placeholder(0, list, BindTarget::Column(&column("tags", "frozen<list<text>>")))
            .unwrap();
        assert_eq!(inline, Placeholder::inline("['it''s', 'b']"));

        let set = Value::Array(vec![Value::Int(1)]);
        assert_eq!(
            cql.placeholder(0, set, BindTarget::Column(&column("ids", "frozen<set<int>>")))
                .unwrap(),
            Placeholder::inline("{1}")
        );
        let tuple = Value::Array(vec![Value::Int(1), Value::Null]);
        assert_eq!(
            cql.placeholder(
                0,
                tuple,
                BindTarget::Column(&column("pair", "frozen<tuple<int, text>>"))
            )
            .unwrap(),
            Placeholder::inline("(1, null)")
        );
        let map = Value::Other(Box::new(tablepro_core::value::OtherValue {
            type_name: "frozen<map<int, int>>".to_owned(),
            text: "{1: 2}".to_owned(),
        }));
        assert!(
            cql.placeholder(0, map, BindTarget::Column(&column("m", "frozen<map<int, int>>")))
                .is_err()
        );
    }

    #[test]
    fn literals_spell_every_type_as_cql_reads_it() {
        let cql = dialect("Cassandra");
        let literal = |value: Value, declaration: &str| {
            cql.literal(
                &value,
                &CqlType::parse(declaration).unwrap().column_type(Some(declaration)),
            )
            .unwrap()
        };
        let instant = DateTime::parse_from_rfc3339("2024-06-15T13:45:30.5+07:00").unwrap();

        assert_eq!(literal(Value::Text("it's".to_owned()), "text"), "'it''s'");
        assert_eq!(literal(Value::Bytes(vec![0xab]), "blob"), "0xab");
        assert_eq!(
            literal(
                Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(instant))),
                "timestamp"
            ),
            "'2024-06-15 06:45:30.500+0000'"
        );
        assert_eq!(
            literal(
                Value::Date(Temporal::Finite(NaiveDate::from_ymd_opt(2024, 2, 29).unwrap())),
                "date"
            ),
            "'2024-02-29'"
        );
        assert_eq!(
            literal(Value::Time(SqlTime::new(false, 1, 2, 3, 4).unwrap()), "time"),
            "'01:02:03.000000004'"
        );
        assert_eq!(
            literal(
                Value::Interval(SqlInterval {
                    months: 1,
                    days: 2,
                    microseconds: 3
                }),
                "duration"
            ),
            "1mo2d3us"
        );
        assert_eq!(literal(Value::Float64(f64::NAN), "double"), "NaN");
        assert_eq!(literal(Value::Null, "list<int>"), "null");
        assert!(
            cql.literal(
                &Value::Decimal(tablepro_core::value::SqlDecimal::nan()),
                &ColumnType::unknown()
            )
            .is_err()
        );
    }

    #[test]
    fn filters_offer_what_each_server_evaluates() {
        let text = column("name", "text");
        let tags = column("tags", "list<text>");

        assert!(!dialect("Cassandra").filter_operators(&text).contains(&FilterOp::Like));
        assert!(
            dialect(SCYLLA_PRODUCT)
                .filter_operators(&text)
                .contains(&FilterOp::Like)
        );
        assert!(dialect("Cassandra").filter_operators(&tags).is_empty());
        assert_eq!(dialect("Cassandra").filter_combinators(), &[Combinator::And]);
        assert_eq!(
            dialect("Cassandra").filter_operators(&column("d", "duration")),
            &[FilterOp::Eq]
        );
        assert!(
            !dialect("Cassandra")
                .filter_operators(&column("n", "int"))
                .contains(&FilterOp::NotEq)
        );
    }

    #[test]
    fn cassandra_before_5_0_offers_in_only_on_the_key() {
        let old = CqlDialect::new(&ServerInfo::new("Cassandra", "4.1.12", 4, 1, 12));
        let mut key = column("id", "int");
        key.primary_key = true;

        assert!(!old.filter_operators(&column("n", "int")).contains(&FilterOp::In));
        assert!(!old.filter_operators(&column("u", "uuid")).contains(&FilterOp::In));
        assert!(old.filter_operators(&key).contains(&FilterOp::In));
        assert!(
            dialect("Cassandra")
                .filter_operators(&column("n", "int"))
                .contains(&FilterOp::In)
        );
        let scylla = CqlDialect::new(&ServerInfo::new(SCYLLA_PRODUCT, "3.0.8", 3, 0, 8));
        assert!(scylla.filter_operators(&column("n", "int")).contains(&FilterOp::In));
    }

    #[test]
    fn a_type_parses_as_cql_writes_it() {
        let cql = dialect("Cassandra");

        assert_eq!(cql.parse_type(" Map<Text, Int> ").unwrap().name, "map<text, int>");
        assert_eq!(cql.parse_type("int; DROP TABLE t"), Err(TypeSyntaxError::Invalid));
        assert_eq!(cql.parse_type("int -- x"), Err(TypeSyntaxError::Comment));
        assert_eq!(
            cql.parse_type("vector<float, 3>").unwrap().kind,
            ColumnKind::Array {
                element: Box::new(ColumnKind::Float(tablepro_core::column::FloatWidth::F32))
            }
        );
    }

    #[test]
    fn a_password_never_reaches_the_history() {
        let cql = dialect("Cassandra");
        for sql in [
            "CREATE ROLE r WITH PASSWORD = 'secret' AND LOGIN = true",
            "ALTER ROLE r WITH PASSWORD = 'secret'",
            "CREATE ROLE r WITH HASHED PASSWORD = '$2a$10$x'",
            "CREATE USER u WITH PASSWORD 'secret'",
            "alter user u with password 'secret'",
        ] {
            assert_eq!(
                cql.history_recording(sql),
                HistoryRecording::Withhold(WithholdReason::CredentialStatement),
                "{sql}"
            );
        }
        for sql in [
            "CREATE ROLE r WITH LOGIN = true",
            "SELECT password FROM t",
            "GRANT SELECT ON ks.t TO r",
        ] {
            assert_eq!(cql.history_recording(sql), HistoryRecording::Record, "{sql}");
        }
    }
}
