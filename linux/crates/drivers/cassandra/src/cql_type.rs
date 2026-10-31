//! CQL types, read from the server's catalogue text or from a result's
//! metadata, and what the app makes of each.

use std::fmt;

use scylla::frame::response::result::{CollectionType, ColumnType as WireType, NativeType};
use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, ReadForm,
    SqlTypeExpr, TemporalZone, TextLength, TimeRange,
};
use tablepro_core::sql_syntax::SqlGrammar;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum Native {
    Ascii,
    BigInt,
    Blob,
    Boolean,
    Counter,
    Date,
    Decimal,
    Double,
    Duration,
    Float,
    Inet,
    Int,
    SmallInt,
    Text,
    Time,
    Timestamp,
    Timeuuid,
    TinyInt,
    Uuid,
    Varint,
}

impl Native {
    const ALL: [Native; 20] = [
        Native::Ascii,
        Native::BigInt,
        Native::Blob,
        Native::Boolean,
        Native::Counter,
        Native::Date,
        Native::Decimal,
        Native::Double,
        Native::Duration,
        Native::Float,
        Native::Inet,
        Native::Int,
        Native::SmallInt,
        Native::Text,
        Native::Time,
        Native::Timestamp,
        Native::Timeuuid,
        Native::TinyInt,
        Native::Uuid,
        Native::Varint,
    ];

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Ascii => "ascii",
            Self::BigInt => "bigint",
            Self::Blob => "blob",
            Self::Boolean => "boolean",
            Self::Counter => "counter",
            Self::Date => "date",
            Self::Decimal => "decimal",
            Self::Double => "double",
            Self::Duration => "duration",
            Self::Float => "float",
            Self::Inet => "inet",
            Self::Int => "int",
            Self::SmallInt => "smallint",
            Self::Text => "text",
            Self::Time => "time",
            Self::Timestamp => "timestamp",
            Self::Timeuuid => "timeuuid",
            Self::TinyInt => "tinyint",
            Self::Uuid => "uuid",
            Self::Varint => "varint",
        }
    }

    /// `varchar` is a name for `text`.
    fn named(name: &str) -> Option<Self> {
        if name.eq_ignore_ascii_case("varchar") {
            return Some(Self::Text);
        }
        Self::ALL
            .into_iter()
            .find(|native| native.name().eq_ignore_ascii_case(name))
    }

    fn kind(self) -> ColumnKind {
        let integer = |width| ColumnKind::Integer(IntegerKind { width, signed: true });
        match self {
            Self::Ascii | Self::Text => ColumnKind::Text {
                length: TextLength::Unbounded,
            },
            Self::BigInt | Self::Counter => integer(IntegerWidth::W64),
            Self::Int => integer(IntegerWidth::W32),
            Self::SmallInt => integer(IntegerWidth::W16),
            Self::TinyInt => integer(IntegerWidth::W8),
            // Arbitrary precision with no fraction, which a decimal of
            // scale 0 holds whatever its length.
            Self::Varint => ColumnKind::Decimal {
                precision: None,
                scale: Some(0),
            },
            Self::Decimal => ColumnKind::Decimal {
                precision: None,
                scale: None,
            },
            Self::Float => ColumnKind::Float(FloatWidth::F32),
            Self::Double => ColumnKind::Float(FloatWidth::F64),
            Self::Boolean => ColumnKind::Bool(BoolStorage::Native),
            Self::Blob => ColumnKind::Bytes {
                length: TextLength::Unbounded,
            },
            Self::Uuid | Self::Timeuuid => ColumnKind::Uuid,
            Self::Timestamp => ColumnKind::Timestamp {
                fractional_digits: Some(3),
                zone: TemporalZone::Offset,
            },
            Self::Date => ColumnKind::Date,
            Self::Time => ColumnKind::Time {
                fractional_digits: Some(9),
                with_offset: false,
                range: TimeRange::TimeOfDay,
            },
            Self::Duration => ColumnKind::Interval,
            Self::Inet => ColumnKind::Network(NetworkFamily::Inet),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum CqlType {
    Native(Native),
    List(Box<CqlType>),
    Set(Box<CqlType>),
    Map(Box<CqlType>, Box<CqlType>),
    Tuple(Vec<CqlType>),
    Vector(Box<CqlType>, u16),
    /// A user-defined type, by its name, and by its keyspace where the
    /// declaration names one, which can only be the column's own.
    Udt {
        keyspace: Option<String>,
        name: String,
    },
    /// `frozen<...>`, which the server writes as a whole.
    Frozen(Box<CqlType>),
    /// A Java class name the server stores for a custom type.
    Custom(String),
}

impl CqlType {
    pub(crate) fn kind(&self) -> ColumnKind {
        match self {
            Self::Native(native) => native.kind(),
            Self::List(element) | Self::Set(element) | Self::Vector(element, _) => ColumnKind::Array {
                element: Box::new(element.kind()),
            },
            Self::Map(..) | Self::Tuple(_) | Self::Udt { .. } => ColumnKind::Composite,
            Self::Frozen(inner) => inner.kind(),
            Self::Custom(_) => ColumnKind::Other,
        }
    }

    /// The type with any `frozen` taken off, which is what a value of it
    /// looks like.
    pub(crate) fn unfrozen(&self) -> &CqlType {
        match self {
            Self::Frozen(inner) => inner.unfrozen(),
            other => other,
        }
    }

    pub(crate) fn native(&self) -> Option<Native> {
        match self.unfrozen() {
            Self::Native(native) => Some(*native),
            _ => None,
        }
    }

    pub(crate) fn is_counter(&self) -> bool {
        self.native() == Some(Native::Counter)
    }

    /// A map or a user-defined type: no value of one can go back into a
    /// key predicate, since the app holds its value only as text.
    pub(crate) fn is_opaque_composite(&self) -> bool {
        matches!(self.unfrozen(), Self::Map(..) | Self::Udt { .. } | Self::Custom(_))
    }

    /// The app's view of a column of this type, `catalog` being the
    /// server's own spelling of it where one was read.
    pub(crate) fn column_type(&self, catalog: Option<&str>) -> ColumnType {
        let spelling = catalog.map_or_else(|| self.to_string(), str::to_owned);
        ColumnType {
            name: spelling.clone(),
            kind: self.kind(),
            catalog: Some(CatalogType {
                declaration: SqlTypeExpr::from_catalog_text(spelling.clone()),
                cast_target: SqlTypeExpr::from_catalog_text(spelling),
            }),
            dynamic_storage: false,
            read_form: ReadForm::Native,
        }
    }

    /// The type a result's metadata gives a column.
    pub(crate) fn from_wire(wire: &WireType<'_>) -> Self {
        Self::from_wire_at(wire, 0)
    }

    fn from_wire_at(wire: &WireType<'_>, depth: usize) -> Self {
        if depth > MAX_NESTING {
            return Self::Custom("a type nested too deep".to_owned());
        }
        let inner = |wire: &WireType<'_>| Box::new(Self::from_wire_at(wire, depth + 1));
        match wire {
            WireType::Native(native) => Self::Native(native_of(native)),
            WireType::Collection { frozen, typ } => {
                let collection = match typ {
                    CollectionType::List(element) => Self::List(inner(element)),
                    CollectionType::Set(element) => Self::Set(inner(element)),
                    CollectionType::Map(key, value) => Self::Map(inner(key), inner(value)),
                    _ => Self::Custom(format!("{typ:?}")),
                };
                frozen_if(*frozen, collection)
            }
            WireType::Vector { typ, dimensions } => Self::Vector(inner(typ), *dimensions),
            WireType::UserDefinedType { frozen, definition } => {
                let udt = Self::Udt {
                    keyspace: None,
                    name: definition.name.to_string(),
                };
                frozen_if(*frozen, udt)
            }
            WireType::Tuple(elements) => Self::Frozen(Box::new(Self::Tuple(
                elements
                    .iter()
                    .map(|element| Self::from_wire_at(element, depth + 1))
                    .collect(),
            ))),
            other => Self::Custom(format!("{other:?}")),
        }
    }

    /// The type `system_schema.columns` writes, such as
    /// `frozen<map<text, int>>`. `None` for text no type grammar reads.
    pub(crate) fn parse(text: &str) -> Option<Self> {
        let mut parser = Parser { text, at: 0, depth: 0 };
        let parsed = parser.cql_type()?;
        parser.skip_space();
        (parser.at == text.len()).then_some(parsed)
    }
}

fn frozen_if(frozen: bool, cql_type: CqlType) -> CqlType {
    match frozen {
        true => CqlType::Frozen(Box::new(cql_type)),
        false => cql_type,
    }
}

fn native_of(native: &NativeType) -> Native {
    match native {
        NativeType::Ascii => Native::Ascii,
        NativeType::Boolean => Native::Boolean,
        NativeType::Blob => Native::Blob,
        NativeType::Counter => Native::Counter,
        NativeType::Date => Native::Date,
        NativeType::Decimal => Native::Decimal,
        NativeType::Double => Native::Double,
        NativeType::Duration => Native::Duration,
        NativeType::Float => Native::Float,
        NativeType::Int => Native::Int,
        NativeType::BigInt => Native::BigInt,
        NativeType::Timestamp => Native::Timestamp,
        NativeType::Inet => Native::Inet,
        NativeType::SmallInt => Native::SmallInt,
        NativeType::TinyInt => Native::TinyInt,
        NativeType::Time => Native::Time,
        NativeType::Timeuuid => Native::Timeuuid,
        NativeType::Uuid => Native::Uuid,
        NativeType::Varint => Native::Varint,
        _ => Native::Text,
    }
}

impl fmt::Display for CqlType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Native(native) => f.write_str(native.name()),
            Self::List(element) => write!(f, "list<{element}>"),
            Self::Set(element) => write!(f, "set<{element}>"),
            Self::Map(key, value) => write!(f, "map<{key}, {value}>"),
            Self::Tuple(elements) => {
                f.write_str("tuple<")?;
                for (index, element) in elements.iter().enumerate() {
                    if index > 0 {
                        f.write_str(", ")?;
                    }
                    write!(f, "{element}")?;
                }
                f.write_str(">")
            }
            Self::Vector(element, dimensions) => write!(f, "vector<{element}, {dimensions}>"),
            Self::Udt { keyspace, name } => {
                if let Some(keyspace) = keyspace {
                    write!(f, "{}.", quote_type_name(keyspace))?;
                }
                f.write_str(&quote_type_name(name))
            }
            Self::Frozen(inner) => match inner.as_ref() {
                // A tuple is always frozen and the server writes it bare.
                Self::Tuple(_) => write!(f, "{inner}"),
                _ => write!(f, "frozen<{inner}>"),
            },
            Self::Custom(class) => write!(f, "'{}'", class.replace('\'', "''")),
        }
    }
}

/// A user type's name as a column definition takes it.
fn quote_type_name(name: &str) -> String {
    match SqlGrammar::Cql.is_bare_identifier(name) && Native::named(name).is_none() {
        true => name.to_owned(),
        false => format!("\"{}\"", name.replace('"', "\"\"")),
    }
}

/// Deeper than any type a schema declares, and shallow enough that the
/// walkers over a type, its drop included, stay well inside a worker's
/// stack whatever the server sends.
const MAX_NESTING: usize = 32;

struct Parser<'a> {
    text: &'a str,
    at: usize,
    depth: usize,
}

impl Parser<'_> {
    fn skip_space(&mut self) {
        while self.text[self.at..].starts_with(|c: char| c.is_ascii_whitespace()) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: char) -> bool {
        self.skip_space();
        if self.text[self.at..].starts_with(byte) {
            self.at += 1;
            return true;
        }
        false
    }

    fn word(&mut self) -> Option<String> {
        self.skip_space();
        let rest = &self.text[self.at..];
        if let Some(quoted) = rest.strip_prefix('"') {
            let mut name = String::new();
            let mut chars = quoted.char_indices();
            while let Some((index, c)) = chars.next() {
                if c == '"' {
                    if quoted[index + 1..].starts_with('"') {
                        name.push('"');
                        chars.next();
                        continue;
                    }
                    self.at += index + 2;
                    return Some(name);
                }
                name.push(c);
            }
            return None;
        }
        let length = rest
            .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
            .unwrap_or(rest.len());
        if length == 0 {
            return None;
        }
        self.at += length;
        Some(rest[..length].to_owned())
    }

    fn cql_type(&mut self) -> Option<CqlType> {
        if self.depth >= MAX_NESTING {
            return None;
        }
        self.depth += 1;
        let parsed = self.nested_type();
        self.depth -= 1;
        parsed
    }

    fn nested_type(&mut self) -> Option<CqlType> {
        self.skip_space();
        if self.text[self.at..].starts_with('\'') {
            let rest = &self.text[self.at + 1..];
            let end = rest.find('\'')?;
            self.at += end + 2;
            return Some(CqlType::Custom(rest[..end].to_owned()));
        }
        let quoted = self.text[self.at..].starts_with('"');
        let word = self.word()?;
        // An unquoted name reads in lower case, as the server folds it.
        let lower = word.to_ascii_lowercase();
        let name = if quoted { word } else { lower.clone() };
        if self.eat('.') {
            let quoted = self.text[self.at..].trim_start().starts_with('"');
            let type_name = self.word()?;
            return Some(CqlType::Udt {
                keyspace: Some(name),
                name: if quoted {
                    type_name
                } else {
                    type_name.to_ascii_lowercase()
                },
            });
        }
        if quoted {
            return Some(CqlType::Udt { keyspace: None, name });
        }
        let parsed = match lower.as_str() {
            "frozen" => CqlType::Frozen(Box::new(self.single()?)),
            "list" => CqlType::List(Box::new(self.single()?)),
            "set" => CqlType::Set(Box::new(self.single()?)),
            "map" => {
                self.eat('<').then_some(())?;
                let key = self.cql_type()?;
                self.eat(',').then_some(())?;
                let value = self.cql_type()?;
                self.eat('>').then_some(())?;
                CqlType::Map(Box::new(key), Box::new(value))
            }
            "tuple" => {
                self.eat('<').then_some(())?;
                let mut elements = vec![self.cql_type()?];
                while self.eat(',') {
                    elements.push(self.cql_type()?);
                }
                self.eat('>').then_some(())?;
                CqlType::Frozen(Box::new(CqlType::Tuple(elements)))
            }
            "vector" => {
                self.eat('<').then_some(())?;
                let element = self.cql_type()?;
                self.eat(',').then_some(())?;
                let dimensions = self.word()?.parse().ok()?;
                self.eat('>').then_some(())?;
                CqlType::Vector(Box::new(element), dimensions)
            }
            _ => match Native::named(&lower) {
                Some(native) => CqlType::Native(native),
                None => CqlType::Udt { keyspace: None, name },
            },
        };
        Some(parsed)
    }

    fn single(&mut self) -> Option<CqlType> {
        self.eat('<').then_some(())?;
        let inner = self.cql_type()?;
        self.eat('>').then_some(inner)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(text: &str) -> CqlType {
        CqlType::parse(text).unwrap_or_else(|| panic!("{text} did not parse"))
    }

    #[test]
    fn a_user_type_is_quoted_where_a_bare_name_would_read_otherwise() {
        let printed = |name: &str| {
            CqlType::Udt {
                keyspace: None,
                name: name.to_owned(),
            }
            .to_string()
        };

        assert_eq!(printed("address"), "address");
        assert_eq!(printed("Address"), "\"Address\"");
        assert_eq!(printed("from"), "\"from\"");
        assert_eq!(printed("text"), "\"text\"");
    }

    #[test]
    fn catalogue_spellings_parse_and_print_back() {
        for text in [
            "text",
            "bigint",
            "list<int>",
            "set<frozen<list<text>>>",
            "frozen<map<text, int>>",
            "tuple<int, text>",
            "vector<float, 3>",
            "frozen<address>",
            "\"Address\"",
            "map<text, frozen<tuple<int, \"Odd\"\"Name\">>>",
            "frozen<shop.address>",
            "frozen<shop.\"Address\">",
            "\"Shop\".\"Address\"",
        ] {
            assert_eq!(parsed(text).to_string(), text, "{text}");
        }
    }

    #[test]
    fn an_unquoted_user_type_reads_in_lower_case() {
        assert_eq!(parsed("Address").to_string(), "address");
        assert_eq!(parsed("frozen<Shop . Address>").to_string(), "frozen<shop.address>");
        assert_eq!(
            parsed("shop.\"Address\""),
            CqlType::Udt {
                keyspace: Some("shop".to_owned()),
                name: "Address".to_owned()
            }
        );
    }

    #[test]
    fn varchar_is_text_and_case_does_not_matter() {
        assert_eq!(parsed("varchar"), CqlType::Native(Native::Text));
        assert_eq!(parsed("BIGINT"), CqlType::Native(Native::BigInt));
        assert_eq!(parsed(" list < int > "), parsed("list<int>"));
    }

    #[test]
    fn text_that_is_not_a_type_is_refused() {
        for text in ["", "list<int", "map<int>", "int; DROP TABLE t", "vector<float, x>"] {
            assert_eq!(CqlType::parse(text), None, "{text}");
        }
    }

    #[test]
    fn kinds_follow_the_value_shape() {
        assert_eq!(
            parsed("frozen<list<int>>").kind(),
            ColumnKind::Array {
                element: Box::new(ColumnKind::Integer(IntegerKind {
                    width: IntegerWidth::W32,
                    signed: true
                }))
            }
        );
        assert_eq!(parsed("map<text, int>").kind(), ColumnKind::Composite);
        assert_eq!(parsed("tuple<int, text>").kind(), ColumnKind::Composite);
        assert_eq!(
            parsed("varint").kind(),
            ColumnKind::Decimal {
                precision: None,
                scale: Some(0)
            }
        );
        assert!(parsed("counter").is_counter());
        assert!(parsed("frozen<map<int, int>>").is_opaque_composite());
        assert!(!parsed("frozen<tuple<int, int>>").is_opaque_composite());
    }

    #[test]
    fn a_type_nested_past_the_limit_is_not_read() {
        let deep = format!("{}int{}", "list<".repeat(100_000), ">".repeat(100_000));
        assert_eq!(CqlType::parse(&deep), None);

        let worker = std::thread::Builder::new().stack_size(2 << 20);
        let handle = worker
            .spawn(|| {
                // The element is a level too.
                let levels = MAX_NESTING - 1;
                let limit = format!("{}int{}", "list<".repeat(levels), ">".repeat(levels));
                let parsed = CqlType::parse(&limit);
                assert!(parsed.is_some());
                assert_eq!(parsed.map(|parsed| parsed.to_string()), Some(limit));
            })
            .unwrap();
        handle.join().unwrap();
    }
}
