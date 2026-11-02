//! DuckDB's types: what a result column is, how it is spelled, and what
//! the grid makes of it.

use duckdb::core::{LogicalTypeHandle, LogicalTypeId};
use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, SqlTypeExpr,
    TemporalZone, TextLength, TimeRange,
};
use tablepro_core::sql_syntax::SqlGrammar;
use tablepro_core::sql_syntax::script::{LexicalSettings, ScriptPlan, ScriptTokenKind};

/// The unit a timestamp counts in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Stamp {
    Seconds,
    Millis,
    Micros,
    Nanos,
}

/// A column's DuckDB type, with the children a nested one holds, as
/// far as a value has to be read by it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum DuckType {
    Boolean,
    Integer {
        width: IntegerWidth,
        signed: bool,
    },
    Float,
    Double,
    Decimal {
        width: u8,
        scale: u8,
    },
    Varchar,
    Json,
    Blob,
    Uuid,
    Bit,
    BigNum,
    Enum,
    Date,
    Time,
    TimeNs,
    TimeTz,
    Timestamp(Stamp),
    TimestampTz,
    Interval,
    List(Box<DuckType>),
    Array(Box<DuckType>, u64),
    Struct(Vec<(String, DuckType)>),
    Map(Box<DuckType>, Box<DuckType>),
    Union(Vec<(String, DuckType)>),
    Geometry,
    Variant,
    Null,
    /// A type this driver does not read, by DuckDB's name or id.
    Other(String),
}

impl DuckType {
    /// The type of a result column, as DuckDB reported it.
    pub(crate) fn from_logical(handle: &LogicalTypeHandle) -> Self {
        let id = match handle.try_id() {
            Ok(id) => id,
            Err(raw) => return Self::Other(format!("type {raw}")),
        };
        if handle
            .get_alias()
            .is_some_and(|alias| alias.eq_ignore_ascii_case("JSON"))
        {
            return Self::Json;
        }
        Self::from_id(id, handle).unwrap_or_else(|| Self::Other(format!("{id:?}").to_ascii_uppercase()))
    }

    fn from_id(id: LogicalTypeId, handle: &LogicalTypeHandle) -> Option<Self> {
        let integer = |width, signed| Self::Integer { width, signed };
        Some(match id {
            LogicalTypeId::Boolean => Self::Boolean,
            LogicalTypeId::Tinyint => integer(IntegerWidth::W8, true),
            LogicalTypeId::Smallint => integer(IntegerWidth::W16, true),
            LogicalTypeId::Integer => integer(IntegerWidth::W32, true),
            LogicalTypeId::Bigint => integer(IntegerWidth::W64, true),
            LogicalTypeId::Hugeint => integer(IntegerWidth::W128, true),
            LogicalTypeId::UTinyint => integer(IntegerWidth::W8, false),
            LogicalTypeId::USmallint => integer(IntegerWidth::W16, false),
            LogicalTypeId::UInteger => integer(IntegerWidth::W32, false),
            LogicalTypeId::UBigint => integer(IntegerWidth::W64, false),
            LogicalTypeId::UHugeint => integer(IntegerWidth::W128, false),
            LogicalTypeId::Float => Self::Float,
            LogicalTypeId::Double => Self::Double,
            LogicalTypeId::Decimal => Self::Decimal {
                width: handle.decimal_width(),
                scale: handle.decimal_scale(),
            },
            LogicalTypeId::Varchar => Self::Varchar,
            LogicalTypeId::Blob => Self::Blob,
            LogicalTypeId::Uuid => Self::Uuid,
            LogicalTypeId::Bit => Self::Bit,
            LogicalTypeId::Bignum => Self::BigNum,
            LogicalTypeId::Enum => Self::Enum,
            LogicalTypeId::Date => Self::Date,
            LogicalTypeId::Time => Self::Time,
            LogicalTypeId::TimeNs => Self::TimeNs,
            LogicalTypeId::TimeTZ => Self::TimeTz,
            LogicalTypeId::Timestamp => Self::Timestamp(Stamp::Micros),
            LogicalTypeId::TimestampS => Self::Timestamp(Stamp::Seconds),
            LogicalTypeId::TimestampMs => Self::Timestamp(Stamp::Millis),
            LogicalTypeId::TimestampNs => Self::Timestamp(Stamp::Nanos),
            LogicalTypeId::TimestampTZ => Self::TimestampTz,
            LogicalTypeId::Interval => Self::Interval,
            LogicalTypeId::Geometry => Self::Geometry,
            LogicalTypeId::Variant => Self::Variant,
            LogicalTypeId::SqlNull => Self::Null,
            LogicalTypeId::List => Self::List(Box::new(child(handle, 0)?)),
            LogicalTypeId::Array => Self::Array(Box::new(child(handle, 0)?), 0),
            LogicalTypeId::Map => Self::Map(Box::new(child(handle, 0)?), Box::new(child(handle, 1)?)),
            LogicalTypeId::Struct => Self::Struct(members(handle)?),
            LogicalTypeId::Union => Self::Union(members(handle)?),
            _ => return None,
        })
    }

    pub(crate) fn is_nested(&self) -> bool {
        matches!(
            self,
            Self::List(_) | Self::Array(..) | Self::Struct(_) | Self::Map(..) | Self::Union(_)
        )
    }

    /// DuckDB's own spelling, as its catalogue writes it.
    pub(crate) fn name(&self) -> String {
        match self {
            Self::Boolean => "BOOLEAN".to_owned(),
            Self::Integer { width, signed } => integer_name(*width, *signed).to_owned(),
            Self::Float => "FLOAT".to_owned(),
            Self::Double => "DOUBLE".to_owned(),
            Self::Decimal { width, scale } => format!("DECIMAL({width},{scale})"),
            Self::Varchar => "VARCHAR".to_owned(),
            Self::Json => "JSON".to_owned(),
            Self::Blob => "BLOB".to_owned(),
            Self::Uuid => "UUID".to_owned(),
            Self::Bit => "BIT".to_owned(),
            Self::BigNum => "BIGNUM".to_owned(),
            Self::Enum => "ENUM".to_owned(),
            Self::Date => "DATE".to_owned(),
            Self::Time => "TIME".to_owned(),
            Self::TimeNs => "TIME_NS".to_owned(),
            Self::TimeTz => "TIME WITH TIME ZONE".to_owned(),
            Self::Timestamp(Stamp::Seconds) => "TIMESTAMP_S".to_owned(),
            Self::Timestamp(Stamp::Millis) => "TIMESTAMP_MS".to_owned(),
            Self::Timestamp(Stamp::Micros) => "TIMESTAMP".to_owned(),
            Self::Timestamp(Stamp::Nanos) => "TIMESTAMP_NS".to_owned(),
            Self::TimestampTz => "TIMESTAMP WITH TIME ZONE".to_owned(),
            Self::Interval => "INTERVAL".to_owned(),
            Self::List(element) => format!("{}[]", element.name()),
            Self::Array(element, 0) => format!("{}[]", element.name()),
            Self::Array(element, size) => format!("{}[{size}]", element.name()),
            Self::Struct(fields) => format!("STRUCT({})", member_list(fields)),
            Self::Map(key, value) => format!("MAP({}, {})", key.name(), value.name()),
            Self::Union(members) => format!("UNION({})", member_list(members)),
            Self::Geometry => "GEOMETRY".to_owned(),
            Self::Variant => "VARIANT".to_owned(),
            Self::Null => "NULL".to_owned(),
            Self::Other(name) => name.clone(),
        }
    }

    /// The type of a result column, as the grid reads it.
    pub(crate) fn column_type(&self) -> ColumnType {
        let name = self.name();
        let catalog =
            (!self.is_nested() && !matches!(self, Self::Enum | Self::Null | Self::Other(_))).then(|| CatalogType {
                declaration: SqlTypeExpr::from_catalog_text(name.clone()),
                cast_target: SqlTypeExpr::from_catalog_text(name.clone()),
            });
        ColumnType {
            kind: self.kind(Vec::new()),
            read_form: self.read_form(),
            name,
            catalog,
            dynamic_storage: false,
        }
    }

    fn kind(&self, labels: Vec<String>) -> ColumnKind {
        match self {
            Self::Boolean => ColumnKind::Bool(BoolStorage::Native),
            Self::Integer { width, signed } => ColumnKind::Integer(IntegerKind {
                width: *width,
                signed: *signed,
            }),
            Self::Float => ColumnKind::Float(FloatWidth::F32),
            Self::Double => ColumnKind::Float(FloatWidth::F64),
            Self::Decimal { width, scale } => ColumnKind::Decimal {
                precision: Some(u32::from(*width)),
                scale: Some(u32::from(*scale)),
            },
            Self::Varchar => ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            Self::Json => ColumnKind::Json { binary: false },
            Self::Blob => ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
            Self::Uuid => ColumnKind::Uuid,
            Self::Bit => ColumnKind::BitString {
                length: None,
                varying: true,
            },
            Self::Enum => ColumnKind::Enum {
                labels,
                multiple: false,
            },
            Self::Date => ColumnKind::Date,
            Self::Time | Self::TimeNs => time_kind(false),
            Self::TimeTz => time_kind(true),
            Self::Timestamp(_) => ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Naive,
            },
            Self::TimestampTz => ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset,
            },
            Self::Interval => ColumnKind::Interval,
            Self::List(element) | Self::Array(element, _) => ColumnKind::Array {
                element: Box::new(element.kind(Vec::new())),
            },
            Self::Struct(_) | Self::Map(..) | Self::Union(_) => ColumnKind::Composite,
            Self::Geometry => ColumnKind::Spatial,
            Self::Variant => ColumnKind::Variant,
            Self::BigNum | Self::Null | Self::Other(_) => ColumnKind::Other,
        }
    }

    /// How a page reads a column of this type: natively, or as DuckDB's
    /// own text where the value cannot be read whole off a result.
    fn read_form(&self) -> ReadForm {
        match self {
            Self::TimeTz
            | Self::BigNum
            | Self::Geometry
            | Self::Variant
            | Self::Other(_)
            | Self::List(_)
            | Self::Array(..)
            | Self::Struct(_)
            | Self::Map(..)
            | Self::Union(_) => ReadForm::ServerText,
            _ => ReadForm::Native,
        }
    }
}

fn child(handle: &LogicalTypeHandle, index: usize) -> Option<DuckType> {
    (index < handle.num_children()).then(|| DuckType::from_logical(&handle.child(index)))
}

fn members(handle: &LogicalTypeHandle) -> Option<Vec<(String, DuckType)>> {
    (0..handle.num_children())
        .map(|index| {
            let name = handle.try_child_name(index).ok()?;
            Some((name, DuckType::from_logical(&handle.child(index))))
        })
        .collect()
}

fn member_list(members: &[(String, DuckType)]) -> String {
    members
        .iter()
        .map(|(name, member)| format!("{} {}", quote_member(name), member.name()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A member name as DuckDB's catalogue writes it: bare when it is a
/// plain lower-case word, quoted otherwise.
fn quote_member(name: &str) -> String {
    let plain = name
        .chars()
        .next()
        .is_some_and(|first| first.is_ascii_lowercase() || first == '_')
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
    match plain {
        true => name.to_owned(),
        false => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

fn integer_name(width: IntegerWidth, signed: bool) -> &'static str {
    match (width, signed) {
        (IntegerWidth::W8, true) => "TINYINT",
        (IntegerWidth::W16, true) => "SMALLINT",
        (IntegerWidth::W24 | IntegerWidth::W32, true) => "INTEGER",
        (IntegerWidth::W64, true) => "BIGINT",
        (IntegerWidth::W128 | IntegerWidth::W256, true) => "HUGEINT",
        (IntegerWidth::W8, false) => "UTINYINT",
        (IntegerWidth::W16, false) => "USMALLINT",
        (IntegerWidth::W24 | IntegerWidth::W32, false) => "UINTEGER",
        (IntegerWidth::W64, false) => "UBIGINT",
        (IntegerWidth::W128 | IntegerWidth::W256, false) => "UHUGEINT",
    }
}

fn time_kind(with_offset: bool) -> ColumnKind {
    ColumnKind::Time {
        fractional_digits: None,
        with_offset,
        range: TimeRange::TimeOfDay,
    }
}

/// A column's type from DuckDB's spelling of it, as `duckdb_columns()`
/// writes it or a user types it in the structure tab. Nested types are
/// told apart by their shape only, since the grid reads them as text.
pub(crate) fn column_type_from_text(text: &str) -> ColumnType {
    let declared = text.trim();
    let duck = duck_type_from_text(declared);
    let labels = match &duck {
        DuckType::Enum => enum_labels(declared).unwrap_or_default(),
        _ => Vec::new(),
    };
    let known = !matches!(duck, DuckType::Other(_));
    // DuckDB's text for a UNION names no member and reads back as the
    // first member it fits, so a table tab reads one as a value of its
    // type, which a SQL export has no literal for, rather than as text.
    let read_form = match holds_union(declared) {
        true => ReadForm::Native,
        false => duck.read_form(),
    };
    ColumnType {
        name: declared.to_owned(),
        kind: duck.kind(labels),
        catalog: Some(CatalogType {
            declaration: SqlTypeExpr::from_catalog_text(declared),
            cast_target: SqlTypeExpr::from_catalog_text(declared),
        }),
        dynamic_storage: !known,
        read_form,
    }
}

/// Whether a spelled type holds a UNION, at any depth. A field may be
/// named `"union("`, so only the word itself before a parenthesis counts.
pub(crate) fn holds_union(text: &str) -> bool {
    let grammar = SqlGrammar::DuckDb;
    let plan = ScriptPlan::build(text, grammar, LexicalSettings::default_for(grammar));
    let tokens: Vec<_> = plan
        .tokens(0..text.len())
        .filter(|token| !token.kind.is_trivia())
        .collect();
    tokens.windows(2).any(|pair| {
        pair[0].kind == ScriptTokenKind::Word
            && text
                .get(pair[0].range.clone())
                .is_some_and(|word| word.eq_ignore_ascii_case("UNION"))
            && pair[1].kind == ScriptTokenKind::OpenParen
    })
}

/// The shape of a spelled type: enough to choose how it is read.
pub(crate) fn duck_type_from_text(text: &str) -> DuckType {
    let upper = text.trim().to_ascii_uppercase();
    if let Some(element) = array_element(&upper) {
        return DuckType::List(Box::new(duck_type_from_text(element)));
    }
    let (head, arguments) = match upper.split_once('(') {
        Some((head, rest)) => (head.trim_end(), rest.strip_suffix(')')),
        None => (upper.as_str(), None),
    };
    match head {
        "STRUCT" | "ROW" => return DuckType::Struct(Vec::new()),
        "MAP" => return DuckType::Map(Box::new(DuckType::Varchar), Box::new(DuckType::Varchar)),
        "UNION" => return DuckType::Union(Vec::new()),
        "ENUM" => return DuckType::Enum,
        "DECIMAL" | "NUMERIC" | "DEC" => return decimal(arguments),
        _ => {}
    }
    scalar(head).unwrap_or_else(|| DuckType::Other(text.trim().to_owned()))
}

/// `INTEGER[]` and `INTEGER[3]` hold `INTEGER`.
fn array_element(upper: &str) -> Option<&str> {
    let body = upper.strip_suffix(']')?;
    let open = body.rfind('[')?;
    let size = &body[open + 1..];
    size.bytes().all(|b| b.is_ascii_digit()).then(|| &body[..open])
}

/// DuckDB's default for a bare DECIMAL is (18,3).
fn decimal(arguments: Option<&str>) -> DuckType {
    let mut numbers = arguments
        .unwrap_or_default()
        .split(',')
        .map(|part| part.trim().parse::<u8>().ok());
    match (numbers.next().flatten(), numbers.next().flatten()) {
        (Some(width), Some(scale)) => DuckType::Decimal { width, scale },
        (Some(width), None) => DuckType::Decimal { width, scale: 0 },
        _ => DuckType::Decimal { width: 18, scale: 3 },
    }
}

fn scalar(head: &str) -> Option<DuckType> {
    let integer = |width, signed| DuckType::Integer { width, signed };
    let collapsed = head.split_ascii_whitespace().collect::<Vec<_>>().join(" ");
    Some(match collapsed.as_str() {
        "BOOLEAN" | "BOOL" | "LOGICAL" => DuckType::Boolean,
        "TINYINT" | "INT1" => integer(IntegerWidth::W8, true),
        "SMALLINT" | "INT2" | "SHORT" | "INT16" => integer(IntegerWidth::W16, true),
        "INTEGER" | "INT" | "INT4" | "SIGNED" | "INT32" => integer(IntegerWidth::W32, true),
        "BIGINT" | "INT8" | "LONG" | "INT64" => integer(IntegerWidth::W64, true),
        "HUGEINT" | "INT128" => integer(IntegerWidth::W128, true),
        "UTINYINT" | "UINT8" => integer(IntegerWidth::W8, false),
        "USMALLINT" | "UINT16" => integer(IntegerWidth::W16, false),
        "UINTEGER" | "UINT32" => integer(IntegerWidth::W32, false),
        "UBIGINT" | "UINT64" => integer(IntegerWidth::W64, false),
        "UHUGEINT" | "UINT128" => integer(IntegerWidth::W128, false),
        "FLOAT" | "FLOAT4" | "REAL" => DuckType::Float,
        "DOUBLE" | "FLOAT8" | "DOUBLE PRECISION" => DuckType::Double,
        "VARCHAR" | "TEXT" | "STRING" | "CHAR" | "BPCHAR" | "NVARCHAR" | "CHARACTER VARYING" | "CHARACTER" => {
            DuckType::Varchar
        }
        "JSON" => DuckType::Json,
        "BLOB" | "BYTEA" | "BINARY" | "VARBINARY" => DuckType::Blob,
        "UUID" | "GUID" => DuckType::Uuid,
        "BIT" | "BITSTRING" => DuckType::Bit,
        "BIGNUM" | "VARINT" => DuckType::BigNum,
        "DATE" => DuckType::Date,
        "TIME" | "TIME WITHOUT TIME ZONE" => DuckType::Time,
        "TIME_NS" => DuckType::TimeNs,
        "TIMETZ" | "TIME WITH TIME ZONE" => DuckType::TimeTz,
        "TIMESTAMP" | "DATETIME" | "TIMESTAMP WITHOUT TIME ZONE" | "TIMESTAMP_US" => DuckType::Timestamp(Stamp::Micros),
        "TIMESTAMP_S" => DuckType::Timestamp(Stamp::Seconds),
        "TIMESTAMP_MS" => DuckType::Timestamp(Stamp::Millis),
        "TIMESTAMP_NS" => DuckType::Timestamp(Stamp::Nanos),
        "TIMESTAMPTZ" | "TIMESTAMP WITH TIME ZONE" => DuckType::TimestampTz,
        "INTERVAL" => DuckType::Interval,
        "GEOMETRY" => DuckType::Geometry,
        "VARIANT" => DuckType::Variant,
        "NULL" => DuckType::Null,
        _ => return None,
    })
}

/// The labels of `ENUM('a', 'it''s')`.
fn enum_labels(text: &str) -> Option<Vec<String>> {
    let open = text.find('(')?;
    let body = text.get(open + 1..)?.trim_end().strip_suffix(')')?;
    let mut labels = Vec::new();
    let mut chars = body.chars().peekable();
    loop {
        while chars.peek().is_some_and(|c| c.is_whitespace() || *c == ',') {
            chars.next();
        }
        match chars.next() {
            None => return Some(labels),
            Some('\'') => {}
            Some(_) => return None,
        }
        let mut label = String::new();
        loop {
            match chars.next()? {
                '\'' if chars.peek() == Some(&'\'') => {
                    chars.next();
                    label.push('\'');
                }
                '\'' => break,
                other => label.push(other),
            }
        }
        labels.push(label);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_union_is_found_at_any_depth_and_never_in_a_name() {
        for text in [
            "UNION(n INTEGER, s VARCHAR)",
            "union(n INTEGER)[]",
            "STRUCT(a UNION(n INTEGER, s VARCHAR))",
            "MAP(VARCHAR, UNION (n INTEGER))",
        ] {
            assert!(holds_union(text), "{text}");
        }
        for text in ["STRUCT(\"union(\" INTEGER)", "VARCHAR", "STRUCT(\"a\" VARCHAR)"] {
            assert!(!holds_union(text), "{text}");
        }
    }

    #[test]
    fn the_catalogue_spelling_reads_as_its_kind() {
        let kind = |text: &str| column_type_from_text(text).kind;

        assert_eq!(
            kind("DECIMAL(18,3)"),
            ColumnKind::Decimal {
                precision: Some(18),
                scale: Some(3)
            }
        );
        assert_eq!(
            kind("UHUGEINT"),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W128,
                signed: false
            })
        );
        assert_eq!(
            kind("INTEGER[]"),
            ColumnKind::Array {
                element: Box::new(ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W32,
                    signed: true
                }))
            }
        );
        assert_eq!(kind("STRUCT(a INTEGER, \"b c\" VARCHAR)"), ColumnKind::Composite);
        assert_eq!(kind("MAP(VARCHAR, INTEGER)"), ColumnKind::Composite);
        assert_eq!(kind("JSON"), ColumnKind::Json { binary: false });
        assert_eq!(
            kind("TIMESTAMP WITH TIME ZONE"),
            ColumnKind::Timestamp {
                fractional_digits: None,
                zone: TemporalZone::Offset
            }
        );
        assert_eq!(kind("geography"), ColumnKind::Other);
    }

    #[test]
    fn a_type_read_as_text_says_so() {
        for text in [
            "TIME WITH TIME ZONE",
            "BIGNUM",
            "INTEGER[3]",
            "MAP(VARCHAR, INTEGER)",
            "GEOMETRY",
            "custom",
        ] {
            assert_eq!(column_type_from_text(text).read_form, ReadForm::ServerText, "{text}");
        }
        for text in ["INTEGER", "UUID", "BIT", "INTERVAL", "TIME_NS", "ENUM('a')"] {
            assert_eq!(column_type_from_text(text).read_form, ReadForm::Native, "{text}");
        }
    }

    #[test]
    fn enum_labels_keep_their_quotes_and_order() {
        assert_eq!(
            column_type_from_text("ENUM('happy', 'it''s', '')").kind,
            ColumnKind::Enum {
                labels: vec!["happy".to_owned(), "it's".to_owned(), String::new()],
                multiple: false
            }
        );
    }

    #[test]
    fn aliases_a_user_types_read_as_the_type() {
        assert_eq!(duck_type_from_text("int8"), duck_type_from_text("BIGINT"));
        assert_eq!(duck_type_from_text("double precision"), DuckType::Double);
        assert_eq!(duck_type_from_text("text"), DuckType::Varchar);
        assert_eq!(
            duck_type_from_text("numeric"),
            DuckType::Decimal { width: 18, scale: 3 }
        );
        assert_eq!(duck_type_from_text("varchar(20)"), DuckType::Varchar);
        assert_eq!(duck_type_from_text("timestamptz"), DuckType::TimestampTz);
    }

    #[test]
    fn a_nested_name_is_spelled_as_the_catalogue_does() {
        let member = DuckType::Struct(vec![
            (
                "a".to_owned(),
                DuckType::Integer {
                    width: IntegerWidth::W32,
                    signed: true,
                },
            ),
            ("b c".to_owned(), DuckType::List(Box::new(DuckType::Varchar))),
        ]);

        assert_eq!(member.name(), "STRUCT(a INTEGER, \"b c\" VARCHAR[])");
        assert_eq!(member.column_type().kind, ColumnKind::Composite);
        assert_eq!(member.column_type().catalog, None);
    }
}
