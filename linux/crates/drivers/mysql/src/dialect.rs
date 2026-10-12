use tablepro_core::ServerInfo;
use tablepro_core::column::{
    BoolStorage, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, SqlExpression,
    TemporalZone, TextLength,
};
use tablepro_core::ddl::{DdlCapabilities, DdlDialect};
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LikeCase, LikeForm, LiteralError, Placeholder,
    SqlDialect,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

use crate::catalog::{TypeFacts, column_type};
use crate::flavour::MySqlFlavour;

/// How MySQL and MariaDB spell the SQL the app generates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MySqlDialect {
    major: u32,
    minor: u32,
    patch: u32,
    flavour: MySqlFlavour,
}

impl MySqlDialect {
    pub fn new(flavour: MySqlFlavour, server: &ServerInfo) -> Self {
        Self {
            major: server.major,
            minor: server.minor,
            patch: server.patch,
            flavour,
        }
    }

    pub fn flavour(&self) -> MySqlFlavour {
        self.flavour
    }

    pub fn version(&self) -> (u32, u32, u32) {
        (self.major, self.minor, self.patch)
    }

    /// Whether this is MySQL at `version` or later. MariaDB numbers its
    /// releases on its own line, so no MySQL version gate applies to it.
    pub fn mysql_at_least(&self, version: (u32, u32, u32)) -> bool {
        self.flavour == MySqlFlavour::MySql && self.version() >= version
    }

    /// Indexes on expressions, and the STATISTICS column naming them,
    /// arrived in MySQL 8.0.13.
    pub fn has_functional_key_parts(&self) -> bool {
        self.mysql_at_least((8, 0, 13))
    }
}

const fn ddl_capabilities(expression_index_keys: bool) -> DdlCapabilities {
    DdlCapabilities {
        create_table: true,
        rename_table: true,
        add_column: true,
        drop_column: true,
        rename_column: true,
        alter_column_type: true,
        alter_column_nullability: true,
        nullability_switch: true,
        alter_column_default: true,
        alter_primary_key: true,
        alter_auto_increment: true,
        create_index: true,
        drop_index: true,
        expression_index_keys,
        partial_indexes: false,
        add_foreign_key: true,
        drop_foreign_key: true,
        // MySQL parses CASCADE on DROP TABLE and does nothing with it.
        drop_table_cascade: false,
    }
}

static FUNCTIONAL_KEY_DDL: MySqlDdl = MySqlDdl {
    capabilities: ddl_capabilities(true),
};
static COLUMN_KEY_DDL: MySqlDdl = MySqlDdl {
    capabilities: ddl_capabilities(false),
};

#[derive(Debug)]
struct MySqlDdl {
    capabilities: DdlCapabilities,
}

impl DdlDialect for MySqlDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }
}

impl SqlDialect for MySqlDialect {
    fn capabilities(&self) -> DialectCapabilities {
        // CLIENT_FOUND_ROWS is on, so an UPDATE reports the rows it
        // matched, including ones it left unchanged.
        DialectCapabilities { exact_row_counts: true }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::MySql
    }

    fn quote_identifier(&self, name: &str) -> String {
        format!("`{}`", name.replace('`', "``"))
    }

    fn placeholder(&self, _ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let param_type = match target {
            BindTarget::Pattern => ParamType::Text,
            BindTarget::EngineRowId(_) => {
                return Err(BindError::Unrepresentable {
                    expected: "a MySQL column",
                    found: "an engine row address",
                });
            }
            BindTarget::Column(column) => column_param_type(column),
        };
        let (value, param_type) = adapt(value, param_type)?;
        Ok(Placeholder::bound("?", BoundParam::new(value, param_type)?))
    }

    fn literal(&self, value: &Value, _column: &ColumnType) -> Result<String, LiteralError> {
        literal(value)
    }

    fn escape_like_text(&self, text: &str) -> String {
        let mut escaped = String::with_capacity(text.len());
        for character in text.chars() {
            if matches!(character, '!' | '%' | '_') {
                escaped.push('!');
            }
            escaped.push(character);
        }
        escaped
    }

    /// LOWER() on both sides is what makes a match case-insensitive
    /// whatever the column's collation, `_bin` included.
    fn like_predicate(&self, column_sql: &str, pattern_sql: &str, form: LikeForm) -> String {
        let (left, right) = match form.case {
            LikeCase::Insensitive => (format!("LOWER({column_sql})"), format!("LOWER({pattern_sql})")),
            LikeCase::EngineDefault => (column_sql.to_owned(), pattern_sql.to_owned()),
        };
        let operator = match form.negated {
            true => "NOT LIKE",
            false => "LIKE",
        };
        match form.escaped {
            true => format!("{left} {operator} {right} ESCAPE '!'"),
            false => format!("{left} {operator} {right}"),
        }
    }

    fn row_window(&self, order_by: Option<&str>, limit: u64, offset: u64) -> String {
        match order_by.map(str::trim).filter(|order| !order.is_empty()) {
            Some(order) => format!(" ORDER BY {order} LIMIT {limit} OFFSET {offset}"),
            None => format!(" LIMIT {limit} OFFSET {offset}"),
        }
    }

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
        let parsed = parse_type(SqlGrammar::MySql, text, MAX_TYPE_LEN)?;
        let declared = parsed.text.as_str();
        let data_type = data_type_of(declared);
        let args = arguments(declared);
        let first = args.first().copied();
        let lower = data_type.to_ascii_lowercase();
        let facts = TypeFacts {
            data_type: &data_type,
            column_type: declared,
            numeric_precision: match lower.as_str() {
                "decimal" | "numeric" | "fixed" | "bit" => first,
                _ => None,
            },
            numeric_scale: match lower.as_str() {
                "decimal" | "numeric" | "fixed" => Some(args.get(1).copied().unwrap_or(0)),
                _ => None,
            },
            datetime_precision: match lower.as_str() {
                "time" | "datetime" | "timestamp" => Some(first.unwrap_or(0)),
                _ => None,
            },
            character_maximum_length: match lower.as_str() {
                "char" | "varchar" | "binary" | "varbinary" => first,
                _ => None,
            },
            has_character_set: true,
        };
        Ok(column_type(&facts))
    }

    fn parse_expression(&self, text: &str) -> Result<SqlExpression, ExpressionSyntaxError> {
        let parsed = parse_expression(SqlGrammar::MySql, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(match self.has_functional_key_parts() {
            true => &FUNCTIONAL_KEY_DDL,
            false => &COLUMN_KEY_DDL,
        })
    }

    fn insert_default_row(&self, table_sql: &str) -> Option<String> {
        Some(format!("INSERT INTO {table_sql} () VALUES ()"))
    }
}

/// The type's leading name, as DATA_TYPE would spell it.
fn data_type_of(declared: &str) -> String {
    let lower = declared.trim().to_ascii_lowercase();
    if lower.starts_with("double precision") {
        return "double precision".to_owned();
    }
    lower
        .chars()
        .take_while(|character| character.is_ascii_alphanumeric() || *character == '_')
        .collect()
}

/// The numbers inside the type's parentheses, where they are numbers.
fn arguments(declared: &str) -> Vec<u64> {
    let Some((_, inner)) = declared.split_once('(') else {
        return Vec::new();
    };
    let inner = inner.split(')').next().unwrap_or_default();
    inner
        .split(',')
        .map_while(|part| part.trim().parse::<u64>().ok())
        .collect()
}

/// The parameter type a column takes. Only BIGINT UNSIGNED runs past
/// `i64`, so only it binds unsigned.
fn column_param_type(column: &ColumnInfo) -> ParamType {
    let column_type = &column.column_type;
    match &column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => ParamType::Bool,
        ColumnKind::Bool(BoolStorage::Integer) => ParamType::Int64,
        ColumnKind::Integer(kind) => integer_param_type(*kind),
        ColumnKind::Decimal { .. } | ColumnKind::Money { .. } => ParamType::Decimal,
        ColumnKind::Float(FloatWidth::F32) => ParamType::Float32,
        ColumnKind::Float(FloatWidth::F64) => ParamType::Float64,
        ColumnKind::Text {
            length: TextLength::Fixed(_),
        } => ParamType::FixedText,
        ColumnKind::Text { .. } | ColumnKind::Enum { .. } => ParamType::Text,
        ColumnKind::Bytes { .. } | ColumnKind::Spatial => ParamType::Bytes,
        ColumnKind::Uuid => ParamType::Uuid,
        ColumnKind::Json { binary: false } => ParamType::Json,
        ColumnKind::Json { binary: true } => ParamType::JsonBinary,
        ColumnKind::Date => ParamType::Date,
        ColumnKind::Time { with_offset: false, .. } => ParamType::Time,
        ColumnKind::Time { with_offset: true, .. } => ParamType::TimeTz,
        // A workspace session's zone is UTC, so the instant binds as
        // its UTC wall time.
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => ParamType::TimestampTz,
        ColumnKind::Timestamp { .. } => ParamType::Timestamp,
        ColumnKind::Interval => ParamType::Interval,
        ColumnKind::BitString { .. } => ParamType::UInt64,
        ColumnKind::Network(_)
        | ColumnKind::Xml
        | ColumnKind::Variant
        | ColumnKind::Composite
        | ColumnKind::Array { .. }
        | ColumnKind::Other => match &column_type.catalog {
            Some(catalog) => ParamType::ServerText(catalog.cast_target.clone()),
            None => ParamType::Text,
        },
    }
}

fn integer_param_type(kind: IntegerKind) -> ParamType {
    match (kind.width, kind.signed) {
        (IntegerWidth::W64 | IntegerWidth::W128 | IntegerWidth::W256, false) => ParamType::UInt64,
        (IntegerWidth::W8 | IntegerWidth::W16, true) | (IntegerWidth::W8, false) => ParamType::Int16,
        (IntegerWidth::W24 | IntegerWidth::W32, true) | (IntegerWidth::W16 | IntegerWidth::W24, false) => {
            ParamType::Int32
        }
        _ => ParamType::Int64,
    }
}

/// Values the grid holds in a form the column's own parameter does not
/// take: a BIT read back as bits binds as the number they spell, a value
/// kept as the server's text (a zero date) goes back as that text, and a
/// non-negative integer fits an unsigned column.
fn adapt(value: Value, param_type: ParamType) -> Result<(Value, ParamType), BindError> {
    Ok(match (value, param_type) {
        (Value::Bits(bits), ParamType::UInt64) => match bits.to_u64() {
            Some(number) => (Value::UInt(number), ParamType::UInt64),
            None => {
                return Err(BindError::Unrepresentable {
                    expected: "BIT(64) or narrower",
                    found: "a longer bit string",
                });
            }
        },
        (Value::Int(number), ParamType::UInt64) if number >= 0 => {
            (Value::UInt(number.unsigned_abs()), ParamType::UInt64)
        }
        (Value::Other(other), _) => (Value::Text(other.text), ParamType::Text),
        (value, param_type) => (value, param_type),
    })
}

fn literal(value: &Value) -> Result<String, LiteralError> {
    Ok(match value {
        Value::Null => "NULL".to_owned(),
        Value::Bool(flag) => match flag {
            true => "TRUE".to_owned(),
            false => "FALSE".to_owned(),
        },
        Value::Int(integer) => integer.to_string(),
        Value::UInt(integer) => integer.to_string(),
        Value::WideInt(integer) => integer.to_string(),
        Value::Float32(float) if float.is_finite() => float.to_string(),
        Value::Float64(float) if float.is_finite() => float.to_string(),
        Value::Decimal(decimal) if decimal.is_finite() => decimal.to_string(),
        Value::Bytes(bytes) => format!("X'{}'", tablepro_core::hex::encode_lower(bytes)),
        Value::Bits(bits) => format!("b'{bits}'"),
        Value::Date(Temporal::Finite(date)) => format!("'{}'", date.format("%Y-%m-%d")),
        Value::Timestamp(Temporal::Finite(stamp)) => format!("'{}'", stamp.format("%Y-%m-%d %H:%M:%S%.6f")),
        Value::Time(time) => format!("'{}'", time.format(Some(6))),
        // An offset literal is mis-converted into TIMESTAMP for fractions
        // of .5 or more (MySQL bug #118011), and named zones need the
        // time zone tables loaded. FROM_UNIXTIME gives the instant in
        // whatever zone the session that runs the SQL is in.
        Value::TimestampTz(Temporal::Finite(stamp)) => {
            let instant = stamp.utc().and_utc();
            let seconds = instant.timestamp();
            if seconds < 0 {
                return Err(LiteralError::Unrepresentable {
                    found: "a TIMESTAMP before 1970",
                });
            }
            format!("FROM_UNIXTIME({seconds}.{:06})", instant.timestamp_subsec_micros())
        }
        Value::Undecodable(undecodable) => {
            return Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            });
        }
        Value::Float32(_)
        | Value::Float64(_)
        | Value::Decimal(_)
        | Value::Date(_)
        | Value::Timestamp(_)
        | Value::TimestampTz(_)
        | Value::Array(_) => {
            return Err(LiteralError::Unrepresentable {
                found: value.variant_name(),
            });
        }
        other => match value_to_text(other) {
            Some(text) => string_literal(&text),
            None => {
                return Err(LiteralError::Unrepresentable {
                    found: other.variant_name(),
                });
            }
        },
    })
}

/// A string literal that reads the same under any sql_mode. A backslash
/// is an escape unless NO_BACKSLASH_ESCAPES is set, and a control
/// character may not survive a copy, so text holding either goes as the
/// hex of its UTF-8 bytes.
fn string_literal(text: &str) -> String {
    if text
        .chars()
        .any(|character| character == '\\' || character.is_control())
    {
        return format!("_utf8mb4 X'{}'", tablepro_core::hex::encode_lower(text.as_bytes()));
    }
    format!("'{}'", text.replace('\'', "''"))
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, NaiveDate};
    use tablepro_core::column::{CatalogType, ColumnDefault, ReadForm, SqlTypeExpr};
    use tablepro_core::value::{BitString, OffsetTimestamp};

    use super::*;

    fn dialect(flavour: MySqlFlavour) -> MySqlDialect {
        MySqlDialect::new(flavour, &ServerInfo::new(flavour.product(), "8.4.3", 8, 4, 3))
    }

    #[test]
    fn renames_quote_with_backticks() {
        let dialect = dialect(MySqlFlavour::MySql);

        assert_eq!(
            tablepro_core::sql_ddl::build_rename_table("mysql", &dialect, None, "old", "new`t").unwrap(),
            "ALTER TABLE `old` RENAME TO `new``t`"
        );
        assert_eq!(
            tablepro_core::sql_ddl::build_rename_column("mysql", &dialect, None, "t", "old", "new").unwrap(),
            "ALTER TABLE `t` RENAME COLUMN `old` TO `new`"
        );
    }

    #[test]
    fn an_sql_export_quotes_with_backticks() {
        let columns = [tablepro_core::column::ResultColumn::new(
            "a`b",
            tablepro_core::column::ColumnType::untyped_text("int"),
        )];

        let sql = tablepro_core::export::render_sql_insert(
            &dialect(MySqlFlavour::MySql),
            "t",
            &columns,
            &[vec![Value::Int(1)]],
        );

        assert_eq!(sql, "INSERT INTO `t` (`a``b`) VALUES (1);\n");
    }

    #[test]
    fn functional_key_parts_are_gated_on_mysql_8_0_13() {
        let mysql = |patch| {
            MySqlDialect::new(
                MySqlFlavour::MySql,
                &ServerInfo::new("MySQL", format!("8.0.{patch}"), 8, 0, patch),
            )
        };
        let expression_keys = |dialect: MySqlDialect| {
            dialect
                .ddl()
                .is_some_and(|ddl| ddl.capabilities().expression_index_keys)
        };

        assert!(!expression_keys(mysql(12)));
        assert!(expression_keys(mysql(13)));
        assert!(!mysql(20).mysql_at_least((8, 0, 21)));
        assert!(mysql(21).mysql_at_least((8, 0, 21)));
        assert!(
            !MySqlDialect::new(
                MySqlFlavour::MariaDb,
                &ServerInfo::new("MariaDB", "11.4.5-MariaDB", 11, 4, 5)
            )
            .mysql_at_least((8, 0, 13)),
            "MariaDB's version is not on MySQL's line"
        );
    }

    fn column(kind: ColumnKind) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: ColumnType {
                name: "c".to_owned(),
                kind,
                catalog: Some(CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text("c"),
                    cast_target: SqlTypeExpr::from_catalog_text("c"),
                }),
                dynamic_storage: false,
                read_form: ReadForm::Native,
            },
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            is_generated: false,
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn bind(value: Value, kind: ColumnKind) -> Result<Placeholder, BindError> {
        dialect(MySqlFlavour::MySql).placeholder(3, value, BindTarget::Column(&column(kind)))
    }

    #[test]
    fn a_backslash_or_control_character_goes_as_hex() {
        assert_eq!(
            literal(&Value::Text("abc\\".to_owned())),
            Ok("_utf8mb4 X'6162635c'".to_owned())
        );
        assert_eq!(
            literal(&Value::Text("a\nb".to_owned())),
            Ok("_utf8mb4 X'610a62'".to_owned())
        );
        assert_eq!(literal(&Value::Text("it's".to_owned())), Ok("'it''s'".to_owned()));
        assert_eq!(literal(&Value::Bytes(vec![0xab, 0x01])), Ok("X'ab01'".to_owned()));
        assert_eq!(
            literal(&Value::Bits(BitString::from_u64(5, 4))),
            Ok("b'0101'".to_owned())
        );
        assert!(literal(&Value::Float64(f64::NAN)).is_err());
    }

    #[test]
    fn a_timestamp_with_offset_is_an_epoch_instant() {
        let instant = DateTime::parse_from_rfc3339("2025-04-01T00:00:00.5+00:00").expect("an instant");
        let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(instant)));

        assert_eq!(literal(&value), Ok("FROM_UNIXTIME(1743465600.500000)".to_owned()));

        let before_epoch = DateTime::parse_from_rfc3339("1969-12-31T23:59:59+00:00").expect("an instant");
        let value = Value::TimestampTz(Temporal::Finite(OffsetTimestamp::from_datetime(before_epoch)));
        assert!(literal(&value).is_err());
    }

    #[test]
    fn temporal_literals() {
        let date = NaiveDate::from_ymd_opt(2025, 4, 1).expect("a date");
        assert_eq!(
            literal(&Value::Date(Temporal::Finite(date))),
            Ok("'2025-04-01'".to_owned())
        );
        let stamp = date.and_hms_micro_opt(1, 2, 3, 4).expect("a time");
        assert_eq!(
            literal(&Value::Timestamp(Temporal::Finite(stamp))),
            Ok("'2025-04-01 01:02:03.000004'".to_owned())
        );
        let time = "-838:59:59".parse().expect("a time");
        assert_eq!(literal(&Value::Time(time)), Ok("'-838:59:59.000000'".to_owned()));
    }

    #[test]
    fn mysql_has_no_engine_row_address() {
        let dialect = dialect(MySqlFlavour::MySql);

        assert_eq!(dialect.engine_row_id(EngineRowId::SqliteRowid), None);
        assert_eq!(dialect.engine_row_id_column(EngineRowIdPart::PostgresCtid), None);
        assert!(matches!(
            dialect.placeholder(0, Value::Int(1), BindTarget::EngineRowId(EngineRowIdPart::SqliteRowid)),
            Err(BindError::Unrepresentable { .. })
        ));
    }

    #[test]
    fn values_bind_as_their_columns_type() {
        let unsigned = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: false,
        });
        let placeholder = bind(Value::UInt(u64::MAX), unsigned.clone()).expect("an unsigned bind");
        assert_eq!(placeholder.sql, "?");
        assert_eq!(
            placeholder.param.map(|param| param.param_type().clone()),
            Some(ParamType::UInt64)
        );
        assert!(bind(Value::Int(7), unsigned).is_ok(), "a non-negative Int fits");

        let bits = bind(
            Value::Bits(BitString::from_u64(5, 10)),
            ColumnKind::BitString {
                length: Some(10),
                varying: false,
            },
        )
        .expect("bits");
        assert_eq!(bits.param.map(|param| param.value().clone()), Some(Value::UInt(5)));

        let stamp = bind(
            Value::Null,
            ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset,
            },
        )
        .expect("a typed null");
        assert_eq!(
            stamp.param.map(|param| param.param_type().clone()),
            Some(ParamType::TimestampTz)
        );
        assert!(matches!(
            bind(Value::Text("x".to_owned()), ColumnKind::Date),
            Err(BindError::ValueTypeMismatch { .. })
        ));
    }

    #[test]
    fn like_and_keyset_spelling() {
        let dialect = dialect(MySqlFlavour::MariaDb);

        assert_eq!(dialect.escape_like_text("50%_!"), "50!%!_!!");
        assert_eq!(
            dialect.like_predicate("`a`", "?", LikeForm::insensitive(false)),
            "LOWER(`a`) LIKE LOWER(?)"
        );
        assert_eq!(
            dialect.like_predicate("`a`", "?", LikeForm::contains()),
            "`a` LIKE ? ESCAPE '!'"
        );
        assert_eq!(
            dialect.row_value_after(
                &["`a`".to_owned(), "`b`".to_owned()],
                &["?".to_owned(), "?".to_owned()],
                KeysetDirection::After
            ),
            "(`a`, `b`) > (?, ?)"
        );
        assert_eq!(dialect.quote_identifier("a`b"), "`a``b`");
        assert_eq!(
            dialect.insert_default_row("`t`"),
            Some("INSERT INTO `t` () VALUES ()".to_owned())
        );
        assert!(
            dialect
                .ddl()
                .is_some_and(|ddl| !ddl.capabilities().expression_index_keys)
        );
        assert!(
            self::dialect(MySqlFlavour::MySql)
                .ddl()
                .is_some_and(|ddl| ddl.capabilities().expression_index_keys)
        );
    }

    #[test]
    fn a_draft_type_classifies_like_the_catalogue() {
        let dialect = dialect(MySqlFlavour::MySql);

        assert_eq!(
            dialect.parse_type("tinyint(1)").map(|column| column.kind),
            Ok(ColumnKind::Bool(BoolStorage::Integer))
        );
        assert_eq!(
            dialect.parse_type("decimal(65,30)").map(|column| column.kind),
            Ok(ColumnKind::Decimal {
                precision: Some(65),
                scale: Some(30)
            })
        );
        assert_eq!(
            dialect.parse_type("varchar(20)").map(|column| column.kind),
            Ok(ColumnKind::Text {
                length: TextLength::Varying(20)
            })
        );
        assert!(dialect.parse_type("int; DROP TABLE t").is_err());
    }
}
