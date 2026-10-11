use sqlx::encode::IsNull;
use sqlx::postgres::{PgArgumentBuffer, PgConnection, PgTypeInfo, PgTypeKind};
use sqlx::{Encode, Executor, Postgres, SqlSafeStr, Statement, Type, TypeInfo};
use tablepro_core::{ColumnInfo, DriverError, Value};

use crate::array::MAX_ARRAY_TEXT_BYTES;
use crate::map_sqlx_error;
use crate::query::{statement_column_origins, statement_columns, statement_type_infos};

const PG_LSN_OID: u32 = 3220;
const XML_OID: u32 = 142;
const MACADDR8_OID: u32 = 774;
const MACADDR_OID: u32 = 829;
const CIDR_OID: u32 = 650;
const INET_OID: u32 = 869;

pub(super) struct PgParameterDescription {
    pub(super) inferred_text_types: Vec<Option<PgTypeInfo>>,
    pub(super) columns: Vec<ColumnInfo>,
    pub(super) column_type_infos: Vec<PgTypeInfo>,
    pub(super) column_origins: Vec<Option<(i64, i16)>>,
}

pub(super) async fn describe_query_parameters(
    connection: &mut PgConnection,
    sql: &str,
    params: &[Value],
) -> Result<PgParameterDescription, DriverError> {
    let described_sql = format!("{sql}\n/* Bookie parameter type description */");
    let described_sql = sqlx::AssertSqlSafe(described_sql.as_str()).into_sql_str();
    let statement = match connection.prepare(described_sql.clone()).await {
        Ok(statement) => statement,
        Err(error) => {
            let ambiguous = error
                .as_database_error()
                .and_then(|error| error.code())
                .is_some_and(|code| matches!(code.as_ref(), "42P08" | "42P18"));
            if !ambiguous {
                return Err(map_sqlx_error(error));
            }
            let parameter_types = pg_parameter_type_infos(params);
            match connection.prepare_with(described_sql, &parameter_types).await {
                Ok(statement) => statement,
                Err(fallback_error) => {
                    let text_operator_mismatch = fallback_error
                        .as_database_error()
                        .and_then(|error| error.code())
                        .is_some_and(|code| code.as_ref() == "42883");
                    return Err(map_sqlx_error(if text_operator_mismatch {
                        error
                    } else {
                        fallback_error
                    }));
                }
            }
        }
    };
    let parameters = statement
        .parameters()
        .and_then(|types| types.left())
        .unwrap_or_default();
    let inferred_text_types = parameters
        .iter()
        .map(inferred_text_type_info)
        .collect::<Result<Vec<_>, _>>()?;
    Ok(PgParameterDescription {
        inferred_text_types,
        columns: statement_columns(statement.columns()),
        column_type_infos: statement_type_infos(statement.columns()),
        column_origins: statement_column_origins(statement.columns()),
    })
}

fn inferred_text_type_info(type_info: &PgTypeInfo) -> Result<Option<PgTypeInfo>, DriverError> {
    inferred_text_type_info_at(type_info, 0)
}

fn inferred_text_type_info_at(type_info: &PgTypeInfo, domain_depth: usize) -> Result<Option<PgTypeInfo>, DriverError> {
    match type_info.kind() {
        PgTypeKind::Enum(_) => {
            if domain_depth >= 64 {
                return Err(DriverError::Unsupported(
                    "PostgreSQL enum domain hierarchy exceeds the driver's resolvable depth".into(),
                ));
            }
            Ok(Some(type_info.clone()))
        }
        PgTypeKind::Domain(base) => inferred_text_type_info_at(base, domain_depth + 1),
        PgTypeKind::Array(element) if is_inferred_text_element(element, 0)? => Ok(Some(type_info.clone())),
        _ => Ok(None),
    }
}

fn is_inferred_text_element(type_info: &PgTypeInfo, domain_depth: usize) -> Result<bool, DriverError> {
    match type_info.kind() {
        PgTypeKind::Enum(_) => {
            if domain_depth >= 64 {
                return Err(DriverError::Unsupported(
                    "PostgreSQL enum domain hierarchy exceeds the driver's resolvable depth".into(),
                ));
            }
            Ok(true)
        }
        PgTypeKind::Simple
            if type_info.name().eq_ignore_ascii_case("citext")
                || type_info.oid().is_some_and(|oid| oid.0 == XML_OID) =>
        {
            if domain_depth >= 64 {
                return Err(DriverError::Unsupported(
                    "PostgreSQL array element domain hierarchy exceeds the driver's resolvable depth".into(),
                ));
            }
            Ok(true)
        }
        PgTypeKind::Simple
            if type_info
                .oid()
                .is_some_and(|oid| matches!(oid.0, PG_LSN_OID | MACADDR_OID | MACADDR8_OID | CIDR_OID | INET_OID)) =>
        {
            if domain_depth >= 64 {
                return Err(DriverError::Unsupported(
                    "PostgreSQL array element domain hierarchy exceeds the driver's resolvable depth".into(),
                ));
            }
            Ok(true)
        }
        PgTypeKind::Domain(base) => is_inferred_text_element(base, domain_depth + 1),
        _ => Ok(false),
    }
}

pub(super) fn needs_text_type_inference(params: &[Value]) -> bool {
    params.iter().any(|param| matches!(param, Value::Null | Value::Text(_)))
}

struct PgInferredTextParameter<'a> {
    value: Option<&'a str>,
    type_info: PgTypeInfo,
    text_array: Option<Option<PgArrayText>>,
}

impl<'a> PgInferredTextParameter<'a> {
    fn new(value: Option<&'a str>, type_info: PgTypeInfo) -> Result<Self, DriverError> {
        let text_array = match type_info.kind() {
            PgTypeKind::Array(element) if is_inferred_text_element(element, 0)? => {
                Some(value.map(parse_text_array_text).transpose()?)
            }
            _ => None,
        };
        Ok(Self {
            value,
            type_info,
            text_array,
        })
    }
}

impl Type<Postgres> for PgInferredTextParameter<'_> {
    fn type_info() -> PgTypeInfo {
        <String as Type<Postgres>>::type_info()
    }

    fn compatible(type_info: &PgTypeInfo) -> bool {
        match type_info.kind() {
            PgTypeKind::Enum(_) => true,
            PgTypeKind::Domain(base) => Self::compatible(base),
            PgTypeKind::Array(element) => is_inferred_text_element(element, 0).unwrap_or(false),
            _ => false,
        }
    }
}

impl Encode<'_, Postgres> for PgInferredTextParameter<'_> {
    fn encode_by_ref(&self, buffer: &mut PgArgumentBuffer) -> Result<IsNull, sqlx::error::BoxDynError> {
        if let Some(elements) = &self.text_array {
            let Some(elements) = elements else {
                return Ok(IsNull::Yes);
            };
            let PgTypeKind::Array(element_type) = self.type_info.kind() else {
                return Err("inferred array parameter lost its array type".into());
            };
            let element_oid = element_type
                .oid()
                .ok_or("inferred array element has no PostgreSQL OID")?;
            let dimensions = i32::try_from(elements.dimensions.len()).map_err(|_| "too many array dimensions")?;
            buffer.extend(&dimensions.to_be_bytes());
            buffer.extend(&0_i32.to_be_bytes());
            buffer.extend(&element_oid.0.to_be_bytes());
            for (length, lower_bound) in &elements.dimensions {
                buffer.extend(&length.to_be_bytes());
                buffer.extend(&lower_bound.to_be_bytes());
            }
            encode_inferred_array_elements(buffer, element_type, &elements.elements)?;
            return Ok(IsNull::No);
        }
        match self.value {
            Some(value) => {
                buffer.extend(value.as_bytes());
                Ok(IsNull::No)
            }
            None => Ok(IsNull::Yes),
        }
    }

    fn produces(&self) -> Option<PgTypeInfo> {
        Some(self.type_info.clone())
    }

    fn size_hint(&self) -> usize {
        self.value.map_or(0, str::len)
    }
}

fn encode_inferred_array_elements(
    buffer: &mut PgArgumentBuffer,
    element_type: &PgTypeInfo,
    elements: &[Option<String>],
) -> Result<(), sqlx::error::BoxDynError> {
    for element in elements {
        let Some(value) = element else {
            buffer.extend(&(-1_i32).to_be_bytes());
            continue;
        };
        if has_base_oid(element_type, PG_LSN_OID) {
            let encoded = encode_pg_lsn(value).ok_or("invalid PostgreSQL pg_lsn array element")?;
            buffer.extend(&8_i32.to_be_bytes());
            buffer.extend(&encoded);
        } else if has_base_oid(element_type, MACADDR_OID) {
            let encoded = encode_pg_mac_address::<6>(value).ok_or("invalid PostgreSQL macaddr array element")?;
            buffer.extend(&6_i32.to_be_bytes());
            buffer.extend(&encoded);
        } else if has_base_oid(element_type, MACADDR8_OID) {
            let encoded = encode_pg_mac_address::<8>(value).ok_or("invalid PostgreSQL macaddr8 array element")?;
            buffer.extend(&8_i32.to_be_bytes());
            buffer.extend(&encoded);
        } else if has_base_oid(element_type, INET_OID) || has_base_oid(element_type, CIDR_OID) {
            let encoded = encode_pg_network(value, has_base_oid(element_type, CIDR_OID))
                .ok_or("invalid PostgreSQL network array element")?;
            let length = i32::try_from(encoded.len()).map_err(|_| "array element is too large")?;
            buffer.extend(&length.to_be_bytes());
            buffer.extend(&encoded);
        } else {
            let length = i32::try_from(value.len()).map_err(|_| "array element is too large")?;
            buffer.extend(&length.to_be_bytes());
            buffer.extend(value.as_bytes());
        }
    }
    Ok(())
}

fn has_base_oid(type_info: &PgTypeInfo, expected_oid: u32) -> bool {
    let mut current = type_info;
    loop {
        match current.kind() {
            PgTypeKind::Domain(base) => current = base,
            PgTypeKind::Simple => return current.oid().is_some_and(|oid| oid.0 == expected_oid),
            _ => return false,
        }
    }
}

fn encode_pg_mac_address<const OCTETS: usize>(value: &str) -> Option<[u8; OCTETS]> {
    let mut bytes = [0; OCTETS];
    let mut parts = value.split(':');
    for byte in &mut bytes {
        let part = parts.next()?;
        if part.len() != 2 {
            return None;
        }
        *byte = u8::from_str_radix(part, 16).ok()?;
    }
    parts.next().is_none().then_some(bytes)
}

fn encode_pg_network(value: &str, cidr: bool) -> Option<Vec<u8>> {
    use std::net::IpAddr;

    let (address, prefix) = value
        .split_once('/')
        .map_or((value, None), |(address, prefix)| (address, Some(prefix)));
    if cidr && prefix.is_none() {
        return None;
    }
    let address = address.parse::<IpAddr>().ok()?;
    let (family, bits, octets) = match address {
        IpAddr::V4(address) => {
            let bits = match prefix {
                Some(prefix) => prefix.parse::<u8>().ok()?,
                None => 32,
            };
            if bits > 32 || (cidr && u32::from(address) & u32::MAX.checked_shr(u32::from(bits)).unwrap_or(0) != 0) {
                return None;
            }
            (2, bits, address.octets().to_vec())
        }
        IpAddr::V6(address) => {
            let bits = match prefix {
                Some(prefix) => prefix.parse::<u8>().ok()?,
                None => 128,
            };
            if bits > 128 || (cidr && u128::from(address) & u128::MAX.checked_shr(u32::from(bits)).unwrap_or(0) != 0) {
                return None;
            }
            (3, bits, address.octets().to_vec())
        }
    };
    let mut encoded = Vec::with_capacity(4 + octets.len());
    encoded.extend([family, bits, u8::from(cidr), octets.len() as u8]);
    encoded.extend(octets);
    Some(encoded)
}

fn encode_pg_lsn(value: &str) -> Option<[u8; 8]> {
    let (high, low) = value.split_once('/')?;
    if high.is_empty() || low.is_empty() || value.matches('/').count() != 1 {
        return None;
    }
    let high = u32::from_str_radix(high, 16).ok()?;
    let low = u32::from_str_radix(low, 16).ok()?;
    Some((u64::from(high) << 32 | u64::from(low)).to_be_bytes())
}

struct PgArrayText {
    dimensions: Vec<(i32, i32)>,
    elements: Vec<Option<String>>,
}

enum PgArrayNode {
    Array(Vec<PgArrayNode>),
    Element(Option<String>),
}

fn parse_text_array_text(text: &str) -> Result<PgArrayText, DriverError> {
    if text.len() > MAX_ARRAY_TEXT_BYTES {
        return Err(DriverError::Unsupported(
            "PostgreSQL array parameter exceeds the 16 MiB limit".into(),
        ));
    }
    let mut parser = PgArrayTextParser {
        chars: text.chars().peekable(),
    };
    let declared_dimensions = parser.dimensions()?;
    let node = parser.array()?;
    if parser.chars.next().is_some() {
        return Err(DriverError::Unsupported(
            "invalid PostgreSQL array parameter syntax".into(),
        ));
    }
    let (shape, elements) = flatten_text_array(node)?;
    if shape.len() > 6 {
        return Err(DriverError::Unsupported(
            "PostgreSQL arrays support at most six dimensions".into(),
        ));
    }
    let lengths = shape
        .iter()
        .map(|length| {
            i32::try_from(*length).map_err(|_| DriverError::Unsupported("array dimension is too large".into()))
        })
        .collect::<Result<Vec<_>, _>>()?;
    let dimensions = if lengths == [0] && declared_dimensions.is_empty() {
        Vec::new()
    } else if declared_dimensions.is_empty() {
        lengths.into_iter().map(|length| (length, 1)).collect()
    } else {
        if declared_dimensions
            .iter()
            .map(|(length, _)| *length)
            .collect::<Vec<_>>()
            != lengths
        {
            return Err(DriverError::Unsupported(
                "array bounds do not match the array contents".into(),
            ));
        }
        declared_dimensions
    };
    Ok(PgArrayText { dimensions, elements })
}

struct PgArrayTextParser<'a> {
    chars: std::iter::Peekable<std::str::Chars<'a>>,
}

impl PgArrayTextParser<'_> {
    fn dimensions(&mut self) -> Result<Vec<(i32, i32)>, DriverError> {
        let mut dimensions = Vec::new();
        while self.chars.peek() == Some(&'[') {
            self.chars.next();
            let lower = self.integer()?;
            if self.chars.next() != Some(':') {
                return Err(DriverError::Unsupported("invalid PostgreSQL array bounds".into()));
            }
            let upper = self.integer()?;
            if self.chars.next() != Some(']') {
                return Err(DriverError::Unsupported("invalid PostgreSQL array bounds".into()));
            }
            let length = upper
                .checked_sub(lower)
                .and_then(|length| length.checked_add(1))
                .filter(|length| *length >= 0)
                .ok_or_else(|| DriverError::Unsupported("invalid PostgreSQL array bounds".into()))?;
            dimensions.push((length, lower));
            if dimensions.len() > 6 {
                return Err(DriverError::Unsupported(
                    "PostgreSQL arrays support at most six dimensions".into(),
                ));
            }
        }
        if !dimensions.is_empty() && self.chars.next() != Some('=') {
            return Err(DriverError::Unsupported("invalid PostgreSQL array bounds".into()));
        }
        Ok(dimensions)
    }

    fn integer(&mut self) -> Result<i32, DriverError> {
        let mut text = String::new();
        while self
            .chars
            .peek()
            .is_some_and(|character| character.is_ascii_digit() || *character == '-')
        {
            text.push(self.chars.next().unwrap_or_default());
        }
        text.parse()
            .map_err(|_| DriverError::Unsupported("invalid PostgreSQL array bounds".into()))
    }

    fn array(&mut self) -> Result<PgArrayNode, DriverError> {
        self.array_at_depth(1)
    }

    fn array_at_depth(&mut self, depth: usize) -> Result<PgArrayNode, DriverError> {
        if depth > 6 {
            return Err(DriverError::Unsupported(
                "PostgreSQL arrays support at most six dimensions".into(),
            ));
        }
        if self.chars.next() != Some('{') {
            return Err(DriverError::Unsupported(
                "PostgreSQL array parameters require brace syntax".into(),
            ));
        }
        let mut values = Vec::new();
        if self.chars.peek() == Some(&'}') {
            self.chars.next();
            return Ok(PgArrayNode::Array(values));
        }
        loop {
            values.push(if self.chars.peek() == Some(&'{') {
                self.array_at_depth(depth + 1)?
            } else {
                PgArrayNode::Element(self.element()?)
            });
            match self.chars.next() {
                Some(',') => {}
                Some('}') => return Ok(PgArrayNode::Array(values)),
                _ => {
                    return Err(DriverError::Unsupported(
                        "invalid PostgreSQL array parameter syntax".into(),
                    ));
                }
            }
        }
    }

    fn element(&mut self) -> Result<Option<String>, DriverError> {
        let quoted = self.chars.peek() == Some(&'"');
        let mut value = String::new();
        if quoted {
            self.chars.next();
            loop {
                match self.chars.next() {
                    Some('"') => break,
                    Some('\\') => value.push(
                        self.chars
                            .next()
                            .ok_or_else(|| DriverError::Unsupported("invalid PostgreSQL array escape".into()))?,
                    ),
                    Some(character) => value.push(character),
                    None => {
                        return Err(DriverError::Unsupported(
                            "unterminated quoted PostgreSQL array label".into(),
                        ));
                    }
                }
            }
        } else {
            while let Some(&character) = self.chars.peek() {
                if matches!(character, ',' | '}') {
                    break;
                }
                self.chars.next();
                if character == '\\' {
                    value.push(
                        self.chars
                            .next()
                            .ok_or_else(|| DriverError::Unsupported("invalid PostgreSQL array escape".into()))?,
                    );
                } else if matches!(character, '{' | '"' | '[' | ']') {
                    return Err(DriverError::Unsupported("invalid PostgreSQL array element".into()));
                } else {
                    value.push(character);
                }
            }
            value = value.trim().to_owned();
        }
        Ok((quoted || !value.eq_ignore_ascii_case("NULL")).then_some(value))
    }
}

fn flatten_text_array(node: PgArrayNode) -> Result<(Vec<usize>, Vec<Option<String>>), DriverError> {
    let PgArrayNode::Array(values) = node else {
        return Err(DriverError::Unsupported(
            "PostgreSQL array root must be an array".into(),
        ));
    };
    let Some(first) = values.first() else {
        return Ok((vec![0], Vec::new()));
    };
    if matches!(first, PgArrayNode::Element(_)) {
        if values.iter().any(|value| !matches!(value, PgArrayNode::Element(_))) {
            return Err(DriverError::Unsupported(
                "ragged PostgreSQL arrays are unsupported".into(),
            ));
        }
        let length = values.len();
        let elements = values
            .into_iter()
            .map(|value| match value {
                PgArrayNode::Element(value) => value,
                PgArrayNode::Array(_) => None,
            })
            .collect();
        return Ok((vec![length], elements));
    }
    let outer_length = values.len();
    let mut child_shape = None;
    let mut elements = Vec::new();
    for value in values {
        let (shape, mut child_elements) = flatten_text_array(value)?;
        if child_shape.as_ref().is_some_and(|expected| expected != &shape) {
            return Err(DriverError::Unsupported(
                "ragged PostgreSQL arrays are unsupported".into(),
            ));
        }
        child_shape = Some(shape);
        elements.append(&mut child_elements);
    }
    let mut shape = child_shape.unwrap_or_default();
    shape.insert(0, outer_length);
    Ok((shape, elements))
}

pub(super) fn bind_pg_params<'q>(
    mut query: sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>,
    params: &'q [Value],
    inferred_text_types: &[Option<PgTypeInfo>],
) -> Result<sqlx::query::Query<'q, Postgres, sqlx::postgres::PgArguments>, DriverError> {
    for (index, value) in params.iter().enumerate() {
        let inferred_type = inferred_text_types.get(index).and_then(Option::as_ref);
        query = match (value, inferred_type) {
            (Value::Null, Some(type_info)) => query.bind(PgInferredTextParameter::new(None, type_info.clone())?),
            (Value::Text(value), Some(type_info)) => {
                query.bind(PgInferredTextParameter::new(Some(value), type_info.clone())?)
            }
            (Value::Null, None) => query.bind(Option::<&str>::None),
            (Value::Bool(value), _) => query.bind(*value),
            (Value::Int(value), _) => query.bind(*value),
            (Value::Float(value), _) => query.bind(*value),
            (Value::Text(value), _) => query.bind(value.clone()),
            (Value::Bytes(value), _) => query.bind(value.clone()),
            (Value::Date(value), _) => query.bind(*value),
            (Value::Time(value), _) => query.bind(*value),
            (Value::DateTime(value), _) => query.bind(*value),
            (Value::TimestampTz(value), _) => query.bind(*value),
            (Value::Decimal(value), _) => query.bind(*value),
            (Value::Uuid(value), _) => query.bind(*value),
            (Value::Json(value), _) => query.bind(value.clone()),
            (Value::Undecodable(_), _) => {
                return Err(DriverError::Unsupported(
                    "undecodable cell cannot be bound as a parameter".into(),
                ));
            }
        };
    }
    Ok(query)
}

pub(super) fn pg_parameter_type_infos(params: &[Value]) -> Vec<PgTypeInfo> {
    params
        .iter()
        .map(|param| match param {
            Value::Null => <Option<&str> as Type<Postgres>>::type_info(),
            Value::Bool(_) => <bool as Type<Postgres>>::type_info(),
            Value::Int(_) => <i64 as Type<Postgres>>::type_info(),
            Value::Float(_) => <f64 as Type<Postgres>>::type_info(),
            Value::Text(_) => <String as Type<Postgres>>::type_info(),
            Value::Bytes(_) => <Vec<u8> as Type<Postgres>>::type_info(),
            Value::Date(_) => <chrono::NaiveDate as Type<Postgres>>::type_info(),
            Value::Time(_) => <chrono::NaiveTime as Type<Postgres>>::type_info(),
            Value::DateTime(_) => <chrono::NaiveDateTime as Type<Postgres>>::type_info(),
            Value::TimestampTz(_) => <chrono::DateTime<chrono::Utc> as Type<Postgres>>::type_info(),
            Value::Decimal(_) => <rust_decimal::Decimal as Type<Postgres>>::type_info(),
            Value::Uuid(_) => <uuid::Uuid as Type<Postgres>>::type_info(),
            Value::Json(_) => <sqlx::types::Json<serde_json::Value> as Type<Postgres>>::type_info(),
            Value::Undecodable(_) => PgTypeInfo::with_name("TEXT"),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{encode_pg_lsn, encode_pg_mac_address, encode_pg_network, parse_text_array_text};
    use tablepro_core::DriverError;

    #[test]
    fn inferred_text_array_text_rejects_nesting_beyond_postgres_dimension_limit() {
        assert!(parse_text_array_text("{{{{{{ready}}}}}}").is_ok());

        let deeply_nested = format!("{}ready{}", "{".repeat(10_000), "}".repeat(10_000));

        assert!(matches!(
            parse_text_array_text(&deeply_nested),
            Err(DriverError::Unsupported(message)) if message.contains("at most six dimensions")
        ));
    }

    #[test]
    fn inferred_text_array_text_preserves_quotes_escapes_nulls_and_bounds() {
        let parsed = parse_text_array_text(r#"[0:5]={"NULL",NULL,"","a,b","a\"b","a\\b"}"#).unwrap();
        assert_eq!(parsed.dimensions, vec![(6, 0)]);
        assert_eq!(
            parsed.elements,
            vec![
                Some("NULL".into()),
                None,
                Some(String::new()),
                Some("a,b".into()),
                Some("a\"b".into()),
                Some("a\\b".into()),
            ]
        );

        let parsed = parse_text_array_text(r#"[-1:0][3:4]={{ready,NULL},{"",東京}}"#).unwrap();
        assert_eq!(parsed.dimensions, vec![(2, -1), (2, 3)]);
        assert_eq!(
            parsed.elements,
            vec![Some("ready".into()), None, Some(String::new()), Some("東京".into()),]
        );
    }

    #[test]
    fn inferred_text_array_text_refuses_malformed_shapes_and_trailing_data() {
        for text in [
            "{{ready},{paused,ready}}",
            "[0:2]={ready,paused}",
            "{} trailing",
            r#"{"unterminated\}"#,
            "{ready,paused]",
        ] {
            assert!(
                matches!(parse_text_array_text(text), Err(DriverError::Unsupported(_))),
                "malformed array text should be refused: {text:?}"
            );
        }
    }

    #[test]
    fn value_contract_pg_lsn_array_elements_encode_full_unsigned_words() {
        for (text, expected) in [
            ("0/0", 0_u64),
            ("0/FFFFFFFF", u32::MAX as u64),
            ("1/0", 1_u64 << 32),
            ("FFFFFFFF/FFFFFFFF", u64::MAX),
        ] {
            assert_eq!(encode_pg_lsn(text), Some(expected.to_be_bytes()), "{text}");
        }
        for malformed in ["", "0", "/1", "1/", "1/2/3", "100000000/0", "0/100000000", "x/y"] {
            assert_eq!(encode_pg_lsn(malformed), None, "{malformed}");
        }
    }

    #[test]
    fn value_contract_macaddr_array_elements_encode_six_octets_and_refuse_malformed_text() {
        assert_eq!(
            encode_pg_mac_address::<6>("08:00:2b:01:02:03"),
            Some([0x08, 0x00, 0x2b, 0x01, 0x02, 0x03])
        );
        assert_eq!(
            encode_pg_mac_address::<6>("AA:bb:CC:dd:EE:fF"),
            Some([0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        );
        for malformed in [
            "",
            "08:00:2b:01:02",
            "08:00:2b:01:02:03:04",
            "8:00:2b:01:02:03",
            "gg:00:2b:01:02:03",
        ] {
            assert_eq!(encode_pg_mac_address::<6>(malformed), None, "{malformed}");
        }
    }

    #[test]
    fn value_contract_macaddr8_array_elements_encode_eight_octets_and_refuse_malformed_text() {
        assert_eq!(
            encode_pg_mac_address::<8>("08:00:2b:01:02:03:04:05"),
            Some([0x08, 0x00, 0x2b, 0x01, 0x02, 0x03, 0x04, 0x05])
        );
        for malformed in [
            "08:00:2b:01:02:03",
            "08:00:2b:01:02:03:04:0g",
            "08:00:2b:01:02:03:04:005",
            "08:00:2b:01:02:03:04:05:06",
        ] {
            assert_eq!(encode_pg_mac_address::<8>(malformed), None, "{malformed}");
        }
    }

    #[test]
    fn value_contract_inet_and_cidr_array_elements_encode_network_byte_order_and_refuse_lossy_values() {
        assert_eq!(
            encode_pg_network("192.0.2.1/24", false),
            Some(vec![2, 24, 0, 4, 192, 0, 2, 1])
        );
        assert_eq!(
            encode_pg_network("192.0.2.1", false),
            Some(vec![2, 32, 0, 4, 192, 0, 2, 1])
        );
        assert_eq!(
            encode_pg_network("2001:db8::1/64", false),
            Some(vec![
                3, 64, 0, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
            ])
        );
        assert_eq!(
            encode_pg_network("192.0.2.0/24", true),
            Some(vec![2, 24, 1, 4, 192, 0, 2, 0])
        );
        assert_eq!(
            encode_pg_network("2001:db8::/32", true),
            Some(vec![
                3, 32, 1, 16, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            ])
        );
        for malformed in ["", "192.0.2.1/33", "192.0.2.1/24/2", "not-an-address"] {
            assert_eq!(encode_pg_network(malformed, false), None, "inet: {malformed}");
        }
        for malformed in ["192.0.2.1/24", "192.0.2.0", "2001:db8::1/64", "2001:db8::/129"] {
            assert_eq!(encode_pg_network(malformed, true), None, "cidr: {malformed}");
        }
    }
}
