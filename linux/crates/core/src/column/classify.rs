use super::{
    BoolStorage, ColumnKind, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, TemporalZone, TextLength, TimeRange,
};

/// Deeper than any type a catalogue reports, and shallow enough that a
/// hostile name cannot exhaust the stack.
const MAX_NESTING: usize = 32;

/// What a type name means, for a driver that has nothing better.
///
/// Each engine knows its own catalogue and should say so directly. This
/// is the shared fallback for the spellings every SQL engine agrees on,
/// so a driver only carries the branches where it actually differs. An
/// unrecognised name is `Other`, which round-trips as the server's own
/// text rather than guessing.
pub fn classify_type_name(name: &str) -> ColumnKind {
    classify_nested(name.trim(), 0)
}

/// Whether the server decides the stored width per row, so a declared
/// length is a cap rather than a promise.
pub fn has_dynamic_storage(kind: &ColumnKind) -> bool {
    !matches!(
        kind,
        ColumnKind::Bool(_)
            | ColumnKind::Integer(_)
            | ColumnKind::Float(_)
            | ColumnKind::Money { .. }
            | ColumnKind::Date
            | ColumnKind::Time { .. }
            | ColumnKind::Timestamp { .. }
            | ColumnKind::Uuid
    )
}

fn classify_nested(text: &str, depth: usize) -> ColumnKind {
    if depth > MAX_NESTING {
        return ColumnKind::Other;
    }
    if let Some(element) = text.strip_suffix("[]") {
        return array_of(classify_nested(element.trim_end(), depth + 1));
    }
    let spelling = TypeSpelling::split(text);
    let inner = || {
        spelling
            .arguments
            .map_or(ColumnKind::Other, |inner| classify_nested(inner.trim(), depth + 1))
    };
    match spelling.base() {
        // PostgreSQL's information_schema says only `ARRAY`.
        "array" => array_of(inner()),
        // ClickHouse wrappers that change nullability or storage, not
        // what the column holds.
        "nullable" | "lowcardinality" => inner(),
        base => classify_base(base, &spelling),
    }
}

fn array_of(element: ColumnKind) -> ColumnKind {
    ColumnKind::Array {
        element: Box::new(element),
    }
}

fn classify_base(base: &str, spelling: &TypeSpelling<'_>) -> ColumnKind {
    if let Some(kind) = integer_kind(base, spelling.is_unsigned()) {
        return ColumnKind::Integer(kind);
    }
    let length = spelling.number(0);
    match base {
        "bool" | "boolean" => ColumnKind::Bool(BoolStorage::Native),
        "decimal" | "numeric" | "dec" | "fixed" => ColumnKind::Decimal {
            precision: length,
            // `numeric(10)` is `numeric(10,0)`.
            scale: spelling.number(1).or(length.map(|_| 0)),
        },
        "decimal32" => clickhouse_decimal(9, length),
        "decimal64" => clickhouse_decimal(18, length),
        "decimal128" => clickhouse_decimal(38, length),
        "decimal256" => clickhouse_decimal(76, length),
        "money" | "smallmoney" => ColumnKind::Money { scale: None },
        "real" | "float4" | "float32" => ColumnKind::Float(FloatWidth::F32),
        "double" | "float" | "float8" | "float64" => ColumnKind::Float(FloatWidth::F64),
        "char" | "character" | "nchar" | "national" | "bpchar" | "fixedstring" => character(base, spelling),
        "varchar" | "nvarchar" | "varchar2" | "nvarchar2" | "string" | "name" => ColumnKind::Text {
            length: varying(length),
        },
        "text" | "ntext" | "longtext" | "mediumtext" | "tinytext" | "clob" => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        "bytea" | "blob" | "longblob" | "mediumblob" | "tinyblob" | "image" => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        "binary" => ColumnKind::Bytes {
            length: TextLength::Fixed(length.unwrap_or(1)),
        },
        "varbinary" => ColumnKind::Bytes {
            length: varying(length),
        },
        "date" | "date32" => ColumnKind::Date,
        "time" | "timetz" => ColumnKind::Time {
            fractional_digits: spelling.fractional_digits(),
            with_offset: base == "timetz" || spelling.has_time_zone(),
            range: TimeRange::TimeOfDay,
        },
        "timestamp" | "timestamptz" | "datetimeoffset" => ColumnKind::Timestamp {
            fractional_digits: spelling.fractional_digits(),
            zone: if base != "timestamp" || spelling.has_time_zone() {
                TemporalZone::Offset
            } else {
                TemporalZone::Naive
            },
        },
        "datetime" | "datetime2" | "datetime64" | "smalldatetime" => ColumnKind::Timestamp {
            fractional_digits: spelling.fractional_digits(),
            zone: spelling
                .quoted_arguments()
                .into_iter()
                .next()
                .map_or(TemporalZone::Naive, TemporalZone::Named),
        },
        "interval" => ColumnKind::Interval,
        "uuid" | "uniqueidentifier" => ColumnKind::Uuid,
        "json" => ColumnKind::Json { binary: false },
        "jsonb" => ColumnKind::Json { binary: true },
        "enum" | "enum8" | "enum16" | "set" => ColumnKind::Enum {
            labels: spelling.quoted_arguments(),
            multiple: base == "set",
        },
        "bit" | "varbit" => ColumnKind::BitString {
            length,
            varying: base == "varbit" || spelling.has_word("varying"),
        },
        "inet" => ColumnKind::Network(NetworkFamily::Inet),
        "cidr" => ColumnKind::Network(NetworkFamily::Cidr),
        "macaddr" => ColumnKind::Network(NetworkFamily::MacAddr),
        "macaddr8" => ColumnKind::Network(NetworkFamily::MacAddr8),
        "ipv4" => ColumnKind::Network(NetworkFamily::Ipv4),
        "ipv6" => ColumnKind::Network(NetworkFamily::Ipv6),
        "xml" => ColumnKind::Xml,
        "geometry" | "geography" | "point" | "linestring" | "polygon" | "multipoint" | "multilinestring"
        | "multipolygon" | "geometrycollection" => ColumnKind::Spatial,
        "map" | "tuple" | "nested" | "dynamic" | "aggregatefunction" => ColumnKind::Composite,
        "variant" | "sql_variant" => ColumnKind::Variant,
        _ => ColumnKind::Other,
    }
}

fn integer_kind(base: &str, unsigned: bool) -> Option<IntegerKind> {
    let (width, signed) = match base {
        "tinyint" | "int1" => (IntegerWidth::W8, !unsigned),
        "smallint" | "int2" | "smallserial" | "int16" => (IntegerWidth::W16, !unsigned),
        "mediumint" => (IntegerWidth::W24, !unsigned),
        "int" | "integer" | "int4" | "serial" | "int32" => (IntegerWidth::W32, !unsigned),
        "bigint" | "int8" | "bigserial" | "int64" => (IntegerWidth::W64, !unsigned),
        "int128" => (IntegerWidth::W128, !unsigned),
        "int256" => (IntegerWidth::W256, !unsigned),
        "uint8" => (IntegerWidth::W8, false),
        "uint16" => (IntegerWidth::W16, false),
        "uint32" => (IntegerWidth::W32, false),
        "uint64" => (IntegerWidth::W64, false),
        "uint128" => (IntegerWidth::W128, false),
        "uint256" => (IntegerWidth::W256, false),
        _ => return None,
    };
    Some(IntegerKind { width, signed })
}

fn clickhouse_decimal(precision: u32, scale: Option<u32>) -> ColumnKind {
    ColumnKind::Decimal {
        precision: Some(precision),
        scale,
    }
}

fn character(base: &str, spelling: &TypeSpelling<'_>) -> ColumnKind {
    let length = spelling.number(0);
    let length = match (spelling.has_word("varying"), length) {
        (true, length) => varying(length),
        (false, Some(length)) => TextLength::Fixed(length),
        // PostgreSQL `bpchar` with no length takes any length.
        (false, None) if base == "bpchar" => TextLength::Unbounded,
        // SQL gives `char` with no length a length of one.
        (false, None) => TextLength::Fixed(1),
    };
    ColumnKind::Text { length }
}

fn varying(length: Option<u32>) -> TextLength {
    length.map_or(TextLength::Unbounded, TextLength::Varying)
}

/// A type name cut at its first parentheses: `timestamp(6) with time
/// zone` is the words `timestamp with time zone` and the argument `6`.
struct TypeSpelling<'a> {
    /// Lowercased, from before and after the parentheses.
    words: Vec<String>,
    /// Inside the parentheses, in the original case, because an enum
    /// label or a zone name is case-sensitive.
    arguments: Option<&'a str>,
}

impl<'a> TypeSpelling<'a> {
    fn split(text: &'a str) -> Self {
        let (head, arguments, tail) = match text.find('(') {
            None => (text, None, ""),
            Some(open) => match matching_paren(text, open) {
                Some(close) => (&text[..open], Some(&text[open + 1..close]), &text[close + 1..]),
                None => (&text[..open], None, ""),
            },
        };
        let words = head
            .split_whitespace()
            .chain(tail.split_whitespace())
            .map(str::to_ascii_lowercase)
            .collect();
        Self { words, arguments }
    }

    fn base(&self) -> &str {
        self.words.first().map_or("", String::as_str)
    }

    fn has_word(&self, word: &str) -> bool {
        self.words.iter().skip(1).any(|candidate| candidate == word)
    }

    fn has_time_zone(&self) -> bool {
        self.words
            .windows(3)
            .any(|window| window[0] == "with" && window[1] == "time" && window[2] == "zone")
    }

    /// MySQL spells the unsigned integers as a suffix, and ZEROFILL
    /// implies UNSIGNED: `bigint(20) unsigned zerofill`.
    fn is_unsigned(&self) -> bool {
        self.has_word("unsigned") || self.has_word("zerofill")
    }

    /// The argument at `index` as a number, or `None` where it is
    /// missing or not one, as in `varchar(max)`.
    fn number(&self, index: usize) -> Option<u32> {
        self.arguments?.split(',').nth(index)?.trim().parse().ok()
    }

    fn fractional_digits(&self) -> Option<u8> {
        self.number(0).and_then(|digits| u8::try_from(digits).ok())
    }

    /// Every quoted string among the arguments, unescaped: the labels
    /// of `enum('a','it''s')`, the zone of `DateTime64(3, 'UTC')`.
    fn quoted_arguments(&self) -> Vec<String> {
        self.arguments.map(quoted_strings).unwrap_or_default()
    }
}

/// The byte index of the `)` that closes the `(` at `open`. Quoted text
/// is skipped, so an enum label holding a parenthesis does not end the
/// list early.
fn matching_paren(text: &str, open: usize) -> Option<usize> {
    let mut depth = 0usize;
    let mut quoted = false;
    for (index, byte) in text.bytes().enumerate().skip(open) {
        match byte {
            b'\'' => quoted = !quoted,
            b'(' if !quoted => depth += 1,
            b')' if !quoted => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return Some(index);
                }
            }
            _ => {}
        }
    }
    None
}

fn quoted_strings(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut chars = text.chars().peekable();
    while let Some(next) = chars.next() {
        if next != '\'' {
            continue;
        }
        let mut value = String::new();
        loop {
            match chars.next() {
                Some('\'') if chars.peek() == Some(&'\'') => {
                    chars.next();
                    value.push('\'');
                }
                Some('\'') | None => break,
                Some(other) => value.push(other),
            }
        }
        found.push(value);
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    fn int(width: IntegerWidth, signed: bool) -> ColumnKind {
        ColumnKind::Integer(IntegerKind { width, signed })
    }

    fn text(length: TextLength) -> ColumnKind {
        ColumnKind::Text { length }
    }

    fn stamp(fractional_digits: Option<u8>, zone: TemporalZone) -> ColumnKind {
        ColumnKind::Timestamp {
            fractional_digits,
            zone,
        }
    }

    fn labels(labels: &[&str], multiple: bool) -> ColumnKind {
        ColumnKind::Enum {
            labels: labels.iter().map(|label| (*label).to_owned()).collect(),
            multiple,
        }
    }

    #[test]
    fn classify_type_name_table() {
        let cases = [
            ("bigint", int(IntegerWidth::W64, true)),
            ("int8", int(IntegerWidth::W64, true)),
            ("BIGSERIAL", int(IntegerWidth::W64, true)),
            ("int", int(IntegerWidth::W32, true)),
            ("int unsigned", int(IntegerWidth::W32, false)),
            ("bigint(20) unsigned zerofill", int(IntegerWidth::W64, false)),
            ("mediumint unsigned", int(IntegerWidth::W24, false)),
            ("UInt256", int(IntegerWidth::W256, false)),
            ("boolean", ColumnKind::Bool(BoolStorage::Native)),
            ("real", ColumnKind::Float(FloatWidth::F32)),
            ("double precision", ColumnKind::Float(FloatWidth::F64)),
            (
                "numeric(10,2)",
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(2),
                },
            ),
            (
                "DECIMAL(38, 10)",
                ColumnKind::Decimal {
                    precision: Some(38),
                    scale: Some(10),
                },
            ),
            (
                "numeric(10)",
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(0),
                },
            ),
            (
                "numeric",
                ColumnKind::Decimal {
                    precision: None,
                    scale: None,
                },
            ),
            (
                "Decimal64(4)",
                ColumnKind::Decimal {
                    precision: Some(18),
                    scale: Some(4),
                },
            ),
            ("money", ColumnKind::Money { scale: None }),
            ("varchar(255)", text(TextLength::Varying(255))),
            ("character varying(255)", text(TextLength::Varying(255))),
            ("nvarchar(max)", text(TextLength::Unbounded)),
            ("char(10)", text(TextLength::Fixed(10))),
            ("character", text(TextLength::Fixed(1))),
            ("bpchar", text(TextLength::Unbounded)),
            ("text", text(TextLength::Unbounded)),
            ("LowCardinality(String)", text(TextLength::Unbounded)),
            (
                "bytea",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
            (
                "varbinary(max)",
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
            ),
            (
                "binary(16)",
                ColumnKind::Bytes {
                    length: TextLength::Fixed(16),
                },
            ),
            ("date", ColumnKind::Date),
            (
                "time(3)",
                ColumnKind::Time {
                    fractional_digits: Some(3),
                    with_offset: false,
                    range: TimeRange::TimeOfDay,
                },
            ),
            (
                "time with time zone",
                ColumnKind::Time {
                    fractional_digits: None,
                    with_offset: true,
                    range: TimeRange::TimeOfDay,
                },
            ),
            ("timestamp", stamp(None, TemporalZone::Naive)),
            ("timestamp(6) with time zone", stamp(Some(6), TemporalZone::Offset)),
            ("timestamp without time zone", stamp(None, TemporalZone::Naive)),
            ("timestamptz", stamp(None, TemporalZone::Offset)),
            ("datetime(6)", stamp(Some(6), TemporalZone::Naive)),
            ("datetimeoffset(7)", stamp(Some(7), TemporalZone::Offset)),
            ("DateTime64(3)", stamp(Some(3), TemporalZone::Naive)),
            (
                "DateTime64(3, 'Europe/Paris')",
                stamp(Some(3), TemporalZone::Named("Europe/Paris".to_owned())),
            ),
            ("DateTime('UTC')", stamp(None, TemporalZone::Named("UTC".to_owned()))),
            ("interval", ColumnKind::Interval),
            ("uniqueidentifier", ColumnKind::Uuid),
            ("json", ColumnKind::Json { binary: false }),
            ("jsonb", ColumnKind::Json { binary: true }),
            ("enum('Draft','It''s')", labels(&["Draft", "It's"], false)),
            ("Enum8('a' = 1, 'b(2)' = 2)", labels(&["a", "b(2)"], false)),
            ("set('x','y')", labels(&["x", "y"], true)),
            (
                "bit",
                ColumnKind::BitString {
                    length: None,
                    varying: false,
                },
            ),
            (
                "bit varying(5)",
                ColumnKind::BitString {
                    length: Some(5),
                    varying: true,
                },
            ),
            ("cidr", ColumnKind::Network(NetworkFamily::Cidr)),
            ("macaddr8", ColumnKind::Network(NetworkFamily::MacAddr8)),
            ("IPv6", ColumnKind::Network(NetworkFamily::Ipv6)),
            ("xml", ColumnKind::Xml),
            ("geography", ColumnKind::Spatial),
            ("Map(String, UInt64)", ColumnKind::Composite),
            ("sql_variant", ColumnKind::Variant),
            ("Nullable(Int64)", int(IntegerWidth::W64, true)),
            ("integer[]", array_of(int(IntegerWidth::W32, true))),
            ("text[][]", array_of(array_of(text(TextLength::Unbounded)))),
            ("Array(Nullable(UInt8))", array_of(int(IntegerWidth::W8, false))),
            ("ARRAY", array_of(ColumnKind::Other)),
            ("hstore", ColumnKind::Other),
            ("tsvector", ColumnKind::Other),
            ("", ColumnKind::Other),
        ];

        for (name, expected) in cases {
            assert_eq!(classify_type_name(name), expected, "{name:?}");
        }
    }

    #[test]
    fn a_bit_column_is_bits_not_a_boolean() {
        assert!(matches!(classify_type_name("bit(8)"), ColumnKind::BitString { .. }));
        assert!(matches!(classify_type_name("boolean"), ColumnKind::Bool(_)));
    }

    #[test]
    fn deep_nesting_stops_at_other_rather_than_exhausting_the_stack() {
        let mut kind = classify_type_name(&format!("int{}", "[]".repeat(10_000)));

        let mut depth = 0;
        while let ColumnKind::Array { element } = kind {
            kind = *element;
            depth += 1;
        }
        assert_eq!(kind, ColumnKind::Other);
        assert_eq!(depth, MAX_NESTING + 1);
    }

    #[test]
    fn a_fixed_width_type_has_no_dynamic_storage() {
        assert!(!has_dynamic_storage(&int(IntegerWidth::W32, true)));
        assert!(!has_dynamic_storage(&stamp(None, TemporalZone::Naive)));
        assert!(has_dynamic_storage(&text(TextLength::Varying(10))));
        assert!(has_dynamic_storage(&ColumnKind::Other));
    }
}
