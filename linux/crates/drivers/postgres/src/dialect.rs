use postgres_protocol::escape::{escape_identifier, escape_literal};
use tablepro_core::ServerInfo;
use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnInfo, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm,
    SqlExpression, SqlTypeExpr, TemporalZone, TextLength, classify_type_name, has_dynamic_storage,
};
use tablepro_core::ddl::{DdlCapabilities, DdlDialect};
use tablepro_core::dialect::{
    BindError, BindTarget, DialectCapabilities, KeysetDirection, LiteralError, Placeholder, SqlDialect,
};
use tablepro_core::export::value_to_text;
use tablepro_core::meta::{EngineRowId, EngineRowIdPart};
use tablepro_core::sql_syntax::{
    ExpressionSyntaxError, MAX_EXPRESSION_LEN, MAX_TYPE_LEN, SqlGrammar, TypeSyntaxError, parse_expression, parse_type,
};
use tablepro_core::statement::{BoundParam, ParamType};
use tablepro_core::value::{Temporal, Value};

/// The type a bit string is cast to. A cast to the column's own `bit`
/// would silently truncate to one bit, while `varbit` keeps every bit and
/// leaves the length check to the column's assignment cast.
const BIT_CAST: &str = "varbit";

/// How PostgreSQL spells the SQL the app generates.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PgDialect {
    server_version_num: u32,
}

impl PgDialect {
    pub fn new(server: &ServerInfo) -> Self {
        Self {
            server_version_num: server.major * 10_000 + server.minor,
        }
    }

    pub fn server_version_num(&self) -> u32 {
        self.server_version_num
    }
}

static PG_DDL: PgDdl = PgDdl {
    capabilities: DdlCapabilities {
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
        expression_index_keys: true,
        partial_indexes: true,
        add_foreign_key: true,
        drop_foreign_key: true,
        drop_table_cascade: true,
    },
};

#[derive(Debug)]
struct PgDdl {
    capabilities: DdlCapabilities,
}

impl DdlDialect for PgDdl {
    fn capabilities(&self) -> &DdlCapabilities {
        &self.capabilities
    }
}

impl SqlDialect for PgDialect {
    fn capabilities(&self) -> DialectCapabilities {
        DialectCapabilities { exact_row_counts: true }
    }

    fn grammar(&self) -> SqlGrammar {
        SqlGrammar::PostgreSql
    }

    fn quote_identifier(&self, name: &str) -> String {
        escape_identifier(name)
    }

    fn placeholder(&self, ordinal: usize, value: Value, target: BindTarget<'_>) -> Result<Placeholder, BindError> {
        let marker = format!("${}", ordinal + 1);
        let binding = match target {
            BindTarget::Pattern => Binding::plain(ParamType::Text),
            BindTarget::EngineRowId(part) => row_id_binding(part, &value)?,
            BindTarget::Column(column) => column_binding(column)?,
        };
        let value = match &binding.param_type {
            ParamType::ServerText(_) => as_server_text(value),
            _ => value,
        };
        let param = BoundParam::new(value, binding.param_type)?;
        let sql = match binding.cast {
            Some(cast) => format!("{marker}::{cast}"),
            None => marker,
        };
        Ok(Placeholder::bound(sql, param))
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

    fn engine_row_id(&self, id: EngineRowId) -> Option<String> {
        let projections: Option<Vec<String>> = id
            .parts()
            .iter()
            .map(|part| {
                let column = self.engine_row_id_column(*part)?;
                let alias = self.quote_identifier(part.projection_alias());
                Some(match part {
                    EngineRowIdPart::PostgresTableOid => format!("{column}::oid::int8 AS {alias}"),
                    _ => format!("{column}::text AS {alias}"),
                })
            })
            .collect();
        projections.map(|projections| projections.join(", "))
    }

    fn engine_row_id_column(&self, part: EngineRowIdPart) -> Option<String> {
        match part {
            EngineRowIdPart::PostgresCtid => Some(self.quote_identifier("ctid")),
            EngineRowIdPart::PostgresTableOid => Some(self.quote_identifier("tableoid")),
            EngineRowIdPart::PostgresXmin => Some(self.quote_identifier("xmin")),
            EngineRowIdPart::SqliteRowid => None,
        }
    }

    fn parse_type(&self, text: &str) -> Result<ColumnType, TypeSyntaxError> {
        let parsed = parse_type(SqlGrammar::PostgreSql, text, MAX_TYPE_LEN)?;
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
        let parsed = parse_expression(SqlGrammar::PostgreSql, text, MAX_EXPRESSION_LEN)?;
        Ok(SqlExpression::from_catalog_text(parsed.text))
    }

    fn ddl(&self) -> Option<&dyn DdlDialect> {
        Some(&PG_DDL)
    }

    /// A column without a binary decoder is read as the server's text,
    /// and money as the numeric it is, so no row ever carries a type the
    /// driver would have to look up by name.
    fn projection(&self, column: &ColumnInfo) -> String {
        let name = self.quote_identifier(&column.name);
        match column.column_type.read_form {
            ReadForm::ServerText => format!("{name}::text AS {name}"),
            ReadForm::ServerNumeric => format!("{name}::numeric AS {name}"),
            ReadForm::Native => name,
        }
    }
}

/// What a value binds as, and the cast that turns the parameter into the
/// column's own type.
struct Binding {
    param_type: ParamType,
    cast: Option<SqlTypeExpr>,
}

impl Binding {
    fn plain(param_type: ParamType) -> Self {
        Self { param_type, cast: None }
    }

    fn cast(param_type: ParamType, cast: SqlTypeExpr) -> Self {
        Self {
            param_type,
            cast: Some(cast),
        }
    }

    fn server_text(cast: SqlTypeExpr) -> Self {
        Self::cast(ParamType::ServerText(cast.clone()), cast)
    }
}

fn row_id_binding(part: EngineRowIdPart, value: &Value) -> Result<Binding, BindError> {
    let named = |name: &str| SqlTypeExpr::from_catalog_text(name);
    Ok(match (part, value) {
        // The page reads tableoid as an integer, and a ctid window may
        // hand one back as text, so both forms bind.
        (EngineRowIdPart::PostgresTableOid, Value::Int(_) | Value::UInt(_)) => {
            Binding::cast(ParamType::Int64, named("oid"))
        }
        (EngineRowIdPart::PostgresTableOid, _) => Binding::server_text(named("oid")),
        (EngineRowIdPart::PostgresCtid, _) => Binding::server_text(named("tid")),
        (EngineRowIdPart::PostgresXmin, _) => Binding::server_text(named("xid")),
        (EngineRowIdPart::SqliteRowid, _) => {
            return Err(BindError::Unrepresentable {
                expected: "a PostgreSQL row address",
                found: "a SQLite rowid",
            });
        }
    })
}

fn column_binding(column: &ColumnInfo) -> Result<Binding, BindError> {
    let column_type = &column.column_type;
    let catalog_cast = || {
        column_type
            .catalog
            .as_ref()
            .map(|catalog| catalog.cast_target.clone())
            .ok_or_else(|| BindError::MissingCatalogType {
                column: column.name.clone(),
            })
    };
    Ok(match &column_type.kind {
        ColumnKind::Bool(BoolStorage::Native) => Binding::plain(ParamType::Bool),
        ColumnKind::Bool(BoolStorage::Integer) => Binding::plain(ParamType::Int64),
        ColumnKind::Integer(kind) => Binding::plain(integer_param_type(*kind)),
        ColumnKind::Decimal { .. } => Binding::plain(ParamType::Decimal),
        // money has no binary form the driver writes; a numeric parameter
        // cast to money keeps every digit.
        ColumnKind::Money { .. } => Binding::cast(ParamType::Decimal, SqlTypeExpr::from_catalog_text("money")),
        ColumnKind::Float(FloatWidth::F32) => Binding::plain(ParamType::Float32),
        ColumnKind::Float(FloatWidth::F64) => Binding::plain(ParamType::Float64),
        ColumnKind::Text {
            length: TextLength::Fixed(_),
        } => Binding::plain(ParamType::FixedText),
        ColumnKind::Text { .. } => Binding::plain(ParamType::Text),
        ColumnKind::Bytes { .. } => Binding::plain(ParamType::Bytes),
        ColumnKind::Date => Binding::plain(ParamType::Date),
        ColumnKind::Time { with_offset: false, .. } => Binding::plain(ParamType::Time),
        ColumnKind::Time { with_offset: true, .. } => Binding::plain(ParamType::TimeTz),
        ColumnKind::Timestamp {
            zone: TemporalZone::Offset,
            ..
        } => Binding::plain(ParamType::TimestampTz),
        ColumnKind::Timestamp { .. } => Binding::plain(ParamType::Timestamp),
        ColumnKind::Interval => Binding::plain(ParamType::Interval),
        ColumnKind::Uuid => Binding::plain(ParamType::Uuid),
        ColumnKind::Json { binary: false } => Binding::plain(ParamType::Json),
        ColumnKind::Json { binary: true } => Binding::plain(ParamType::JsonBinary),
        ColumnKind::BitString { .. } => Binding::server_text(SqlTypeExpr::from_catalog_text(BIT_CAST)),
        // A type only the server names binds as text cast to the type the
        // catalogue gave: guessing from the display name could pick the
        // wrong one.
        ColumnKind::Enum { .. }
        | ColumnKind::Network(_)
        | ColumnKind::Xml
        | ColumnKind::Spatial
        | ColumnKind::Variant
        | ColumnKind::Composite
        | ColumnKind::Array { .. }
        | ColumnKind::Other => Binding::server_text(catalog_cast()?),
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

/// A value bound as the server's text. A network address or a bit
/// string the grid read back is carried as its own value, and it is that
/// value's text the server parses.
fn as_server_text(value: Value) -> Value {
    match value {
        Value::Other(other) => Value::Text(other.text),
        Value::Bits(bits) => Value::Text(bits.to_string()),
        other => other,
    }
}

fn literal(value: &Value) -> Result<String, LiteralError> {
    Ok(match value {
        Value::Null => "NULL".to_owned(),
        Value::Bool(flag) => flag.to_string(),
        Value::Int(int) => int.to_string(),
        Value::UInt(int) => int.to_string(),
        Value::WideInt(int) => int.to_string(),
        Value::Float32(float) if float.is_finite() => float.to_string(),
        Value::Float64(float) if float.is_finite() => float.to_string(),
        Value::Float32(_) | Value::Float64(_) => {
            format!("{}::float8", quoted(&value_to_text(value).unwrap_or_default()))
        }
        Value::Decimal(decimal) if decimal.is_finite() => decimal.to_string(),
        Value::Decimal(decimal) => format!("{}::numeric", quoted(&decimal.to_string())),
        Value::Bytes(bytes) => format!("decode('{}', 'hex')", tablepro_core::hex::encode_lower(bytes)),
        Value::Bits(bits) => format!("B'{bits}'"),
        Value::Interval(interval) => format!("INTERVAL '{interval}'"),
        Value::Date(Temporal::Infinity)
        | Value::Timestamp(Temporal::Infinity)
        | Value::TimestampTz(Temporal::Infinity) => "'infinity'".to_owned(),
        Value::Date(Temporal::NegInfinity)
        | Value::Timestamp(Temporal::NegInfinity)
        | Value::TimestampTz(Temporal::NegInfinity) => "'-infinity'".to_owned(),
        Value::Undecodable(undecodable) => {
            return Err(LiteralError::Undecodable {
                reason: format!("{:?}", undecodable.reason),
            });
        }
        other => match value_to_text(other) {
            Some(text) => quoted(&text),
            None => {
                return Err(LiteralError::Unrepresentable {
                    found: other.variant_name(),
                });
            }
        },
    })
}

/// A string literal that reads the same whatever
/// `standard_conforming_strings` is.
fn quoted(text: &str) -> String {
    escape_literal(text).trim_start().to_owned()
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, IntegerKind};
    use tablepro_core::value::SqlDecimal;

    use super::*;

    fn dialect() -> PgDialect {
        PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0))
    }

    fn column(kind: ColumnKind, catalog: Option<&str>) -> ColumnInfo {
        ColumnInfo {
            name: "c".to_owned(),
            column_type: ColumnType {
                name: catalog.unwrap_or("c").to_owned(),
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
            default: ColumnDefault::None,
            comment: None,
        }
    }

    fn bind(ordinal: usize, value: Value, column: &ColumnInfo) -> Result<Placeholder, BindError> {
        dialect().placeholder(ordinal, value, BindTarget::Column(column))
    }

    fn int(width: IntegerWidth) -> ColumnKind {
        ColumnKind::Integer(IntegerKind { width, signed: true })
    }

    #[test]
    fn a_null_binds_as_the_columns_own_type() {
        let cases = [
            (int(IntegerWidth::W32), ParamType::Int32),
            (int(IntegerWidth::W64), ParamType::Int64),
            (ColumnKind::Bool(BoolStorage::Native), ParamType::Bool),
            (ColumnKind::Date, ParamType::Date),
            (ColumnKind::Uuid, ParamType::Uuid),
            (
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(2),
                },
                ParamType::Decimal,
            ),
            (
                ColumnKind::Timestamp {
                    fractional_digits: None,
                    zone: TemporalZone::Offset,
                },
                ParamType::TimestampTz,
            ),
        ];
        for (kind, expected) in cases {
            let placeholder = bind(0, Value::Null, &column(kind.clone(), None)).expect("a typed null");
            assert_eq!(placeholder.sql, "$1", "{kind:?}");
            assert_eq!(
                placeholder.param.as_ref().map(BoundParam::param_type),
                Some(&expected),
                "{kind:?}"
            );
        }
    }

    #[test]
    fn server_named_types_cast_to_their_catalogue_type() {
        let mood = column(
            ColumnKind::Enum {
                labels: vec!["happy".to_owned()],
                multiple: false,
            },
            Some("mood"),
        );
        assert_eq!(
            bind(0, Value::Text("happy".to_owned()), &mood).map(|p| p.sql),
            Ok("$1::mood".to_owned())
        );

        let array = column(
            ColumnKind::Array {
                element: Box::new(int(IntegerWidth::W32)),
            },
            Some("integer[]"),
        );
        assert_eq!(
            bind(1, Value::Text("{1,2}".to_owned()), &array).map(|p| p.sql),
            Ok("$2::integer[]".to_owned())
        );

        let fixed = column(
            ColumnKind::Text {
                length: TextLength::Fixed(10),
            },
            Some("character(10)"),
        );
        assert_eq!(
            bind(0, Value::Text("a".to_owned()), &fixed)
                .ok()
                .and_then(|p| p.param.map(|param| param.param_type().clone())),
            Some(ParamType::FixedText)
        );

        let money = column(ColumnKind::Money { scale: None }, Some("money"));
        assert_eq!(
            bind(0, Value::Decimal("1.25".parse().expect("a decimal")), &money).map(|p| p.sql),
            Ok("$1::money".to_owned())
        );
    }

    #[test]
    fn text_into_a_uuid_is_a_bind_error() {
        let uuid = column(ColumnKind::Uuid, None);

        assert!(matches!(
            bind(0, Value::Text("not a uuid".to_owned()), &uuid),
            Err(BindError::ValueTypeMismatch { .. })
        ));
    }

    #[test]
    fn row_addresses_cast_back_to_their_own_types() {
        let dialect = dialect();
        let ctid = dialect
            .placeholder(
                0,
                Value::Text("(0,1)".to_owned()),
                BindTarget::EngineRowId(EngineRowIdPart::PostgresCtid),
            )
            .expect("a ctid");
        let oid = dialect
            .placeholder(
                1,
                Value::Int(16_384),
                BindTarget::EngineRowId(EngineRowIdPart::PostgresTableOid),
            )
            .expect("a tableoid");
        let xmin = dialect
            .placeholder(
                2,
                Value::Text("742".to_owned()),
                BindTarget::EngineRowId(EngineRowIdPart::PostgresXmin),
            )
            .expect("an xmin");

        assert_eq!(ctid.sql, "$1::tid");
        assert_eq!(oid.sql, "$2::oid");
        assert_eq!(xmin.sql, "$3::xid");
        assert_eq!(
            dialect.engine_row_id(EngineRowId::PostgresTableoidCtid),
            Some(
                r#""tableoid"::oid::int8 AS "__tablepro_row_oid", "ctid"::text AS "__tablepro_row_id", "xmin"::text AS "__tablepro_row_xmin""#
                    .to_owned()
            )
        );
    }

    #[test]
    fn network_and_bit_values_bind_as_their_text() {
        let inet = column(
            ColumnKind::Network(tablepro_core::column::NetworkFamily::Inet),
            Some("inet"),
        );
        let placeholder = bind(
            0,
            Value::Other(Box::new(tablepro_core::value::OtherValue {
                type_name: "inet".to_owned(),
                text: "10.0.0.1".to_owned(),
            })),
            &inet,
        )
        .expect("an address");
        assert_eq!(placeholder.sql, "$1::inet");
        assert_eq!(
            placeholder.param.map(|param| param.value().clone()),
            Some(Value::Text("10.0.0.1".to_owned()))
        );

        let bits = column(
            ColumnKind::BitString {
                length: Some(8),
                varying: false,
            },
            Some("bit"),
        );
        let placeholder =
            bind(0, Value::Bits(tablepro_core::value::BitString::from_u64(5, 8)), &bits).expect("a bit string");
        assert_eq!(placeholder.sql, "$1::varbit", "a cast to bit truncates to one bit");
    }

    #[test]
    fn a_backslash_literal_uses_the_escape_form() {
        assert_eq!(literal(&Value::Text("a\\b".to_owned())), Ok("E'a\\\\b'".to_owned()));
        assert_eq!(literal(&Value::Text("it's".to_owned())), Ok("'it''s'".to_owned()));
        assert_eq!(
            literal(&Value::Decimal(SqlDecimal::nan())),
            Ok("'NaN'::numeric".to_owned())
        );
        assert_eq!(
            literal(&Value::Bytes(vec![0xab, 0x01])),
            Ok("decode('ab01', 'hex')".to_owned())
        );
        assert_eq!(literal(&Value::Date(Temporal::Infinity)), Ok("'infinity'".to_owned()));
    }

    #[test]
    fn like_and_keyset_spelling() {
        let dialect = dialect();
        assert_eq!(dialect.escape_like_text("50%_!"), "50!%!_!!");
        assert_eq!(
            dialect.row_value_after(
                &["\"a\"".to_owned(), "\"b\"".to_owned()],
                &["$1".to_owned(), "$2".to_owned()],
                KeysetDirection::Before
            ),
            "(\"a\", \"b\") < ($1, $2)"
        );
        assert_eq!(dialect.quote_identifier("a\"b"), "\"a\"\"b\"");
        assert!(dialect.ddl().is_some_and(|ddl| ddl.capabilities().partial_indexes));
    }
}
