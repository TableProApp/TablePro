use super::{ColumnKind, FloatKind, IntegerKind, TextKind};

/// What a type name means, for a driver that has nothing better.
///
/// Each engine knows its own catalogue and should say so directly. This
/// is the shared fallback for the spellings every SQL engine agrees on,
/// so a driver only carries the branches where it actually differs. An
/// unrecognised name is `Other`, which round-trips as the server's own
/// text rather than guessing.
pub fn classify_type_name(name: &str) -> ColumnKind {
    let lower = name.trim().to_ascii_lowercase();
    if lower.ends_with("[]") || lower.starts_with("array") {
        return ColumnKind::Array;
    }
    // MySQL spells the unsigned integers as a suffix, which can come
    // after the display width: `bigint(20) unsigned zerofill`.
    let unsigned = lower.contains("unsigned");
    // A declared length or precision does not change what the column
    // holds, so `varchar(255)` classifies as `varchar`.
    let base = lower.split('(').next().unwrap_or(&lower).trim();
    let base = base.split_whitespace().next().unwrap_or(base);

    if let Some(kind) = integer_kind(base, unsigned) {
        return ColumnKind::Integer(kind);
    }
    match base {
        "bool" | "boolean" => ColumnKind::Boolean,
        "decimal" | "numeric" | "money" | "smallmoney" | "dec" | "fixed" => ColumnKind::Decimal,
        "real" | "float4" | "float32" => ColumnKind::Float(FloatKind::F32),
        "double" | "float" | "float8" | "float64" => ColumnKind::Float(FloatKind::F64),
        "char" | "character" | "nchar" | "bpchar" | "fixedstring" => ColumnKind::Text(TextKind::Fixed),
        "text" | "ntext" | "longtext" | "mediumtext" | "tinytext" | "clob" => ColumnKind::Text(TextKind::Large),
        "varchar" | "nvarchar" | "varchar2" | "string" | "name" => ColumnKind::Text(TextKind::Variable),
        "bytea" | "blob" | "binary" | "varbinary" | "longblob" | "mediumblob" | "tinyblob" | "image" => {
            ColumnKind::Binary
        }
        "date" => ColumnKind::Date,
        "time" | "timetz" => ColumnKind::Time,
        "timestamp" | "timestamptz" | "datetime" | "datetime2" | "datetime64" | "smalldatetime" => {
            ColumnKind::Timestamp
        }
        "interval" => ColumnKind::Interval,
        "uuid" | "uniqueidentifier" => ColumnKind::Uuid,
        "json" | "jsonb" => ColumnKind::Json,
        "enum" => ColumnKind::Enumeration,
        "set" => ColumnKind::Set,
        "bit" | "varbit" => ColumnKind::BitString,
        "inet" | "cidr" | "macaddr" | "macaddr8" | "ipv4" | "ipv6" => ColumnKind::Network,
        "geometry" | "geography" | "point" | "polygon" | "linestring" => ColumnKind::Geometry,
        _ => ColumnKind::Other,
    }
}

fn integer_kind(base: &str, unsigned: bool) -> Option<IntegerKind> {
    let signed = match base {
        "tinyint" | "int1" => IntegerKind::I8,
        "smallint" | "int2" | "smallserial" => IntegerKind::I16,
        "mediumint" | "int" | "integer" | "int4" | "serial" => IntegerKind::I32,
        "bigint" | "int8" | "bigserial" => IntegerKind::I64,
        "int128" => IntegerKind::I128,
        "uint8" => return Some(IntegerKind::U8),
        "uint16" => return Some(IntegerKind::U16),
        "uint32" => return Some(IntegerKind::U32),
        "uint64" => return Some(IntegerKind::U64),
        "uint128" => return Some(IntegerKind::U128),
        _ => return None,
    };
    Some(match (signed, unsigned) {
        (IntegerKind::I8, true) => IntegerKind::U8,
        (IntegerKind::I16, true) => IntegerKind::U16,
        (IntegerKind::I32, true) => IntegerKind::U32,
        (IntegerKind::I64, true) => IntegerKind::U64,
        (IntegerKind::I128, true) => IntegerKind::U128,
        (kind, _) => kind,
    })
}

/// Whether the server decides the stored width per row, so a declared
/// length is a cap rather than a promise.
pub fn has_dynamic_storage(kind: ColumnKind) -> bool {
    !matches!(
        kind,
        ColumnKind::Boolean
            | ColumnKind::Integer(_)
            | ColumnKind::Float(_)
            | ColumnKind::Date
            | ColumnKind::Time
            | ColumnKind::Timestamp
            | ColumnKind::Uuid
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_declared_length_does_not_change_the_kind() {
        assert_eq!(classify_type_name("varchar(255)"), ColumnKind::Text(TextKind::Variable));
        assert_eq!(classify_type_name("numeric(10,2)"), ColumnKind::Decimal);
        assert_eq!(classify_type_name("DECIMAL(38, 10)"), ColumnKind::Decimal);
    }

    #[test]
    fn each_engines_spelling_of_the_same_thing_agrees() {
        for name in ["bigint", "int8", "BIGSERIAL"] {
            assert_eq!(
                classify_type_name(name),
                ColumnKind::Integer(IntegerKind::I64),
                "{name}"
            );
        }
        for name in ["timestamp", "datetime", "DateTime64(3)", "timestamptz"] {
            assert_eq!(classify_type_name(name), ColumnKind::Timestamp, "{name}");
        }
        for name in ["bytea", "blob", "varbinary(max)"] {
            assert_eq!(classify_type_name(name), ColumnKind::Binary, "{name}");
        }
    }

    #[test]
    fn an_unknown_type_is_other_rather_than_a_guess() {
        assert_eq!(classify_type_name("hstore"), ColumnKind::Other);
        assert_eq!(classify_type_name("tsvector"), ColumnKind::Other);
    }

    #[test]
    fn an_array_is_an_array_whatever_its_element() {
        assert_eq!(classify_type_name("integer[]"), ColumnKind::Array);
        assert_eq!(classify_type_name("text[]"), ColumnKind::Array);
        assert_eq!(classify_type_name("Array(Int64)"), ColumnKind::Array);
    }

    #[test]
    fn an_unsigned_suffix_changes_the_range() {
        assert_eq!(
            classify_type_name("int unsigned"),
            ColumnKind::Integer(IntegerKind::U32),
            "an unsigned column was read as signed, so half its range would be out of bounds"
        );
        assert_eq!(
            classify_type_name("bigint(20) unsigned zerofill"),
            ColumnKind::Integer(IntegerKind::U64)
        );
        assert_eq!(classify_type_name("int"), ColumnKind::Integer(IntegerKind::I32));
    }

    #[test]
    fn a_bit_column_is_bits_not_a_boolean() {
        assert_eq!(classify_type_name("bit"), ColumnKind::BitString);
        assert_eq!(classify_type_name("bit(8)"), ColumnKind::BitString);
        assert_eq!(classify_type_name("boolean"), ColumnKind::Boolean);
    }

    #[test]
    fn a_fixed_width_type_has_no_dynamic_storage() {
        assert!(!has_dynamic_storage(ColumnKind::Integer(IntegerKind::I32)));
        assert!(!has_dynamic_storage(ColumnKind::Timestamp));
        assert!(has_dynamic_storage(ColumnKind::Text(TextKind::Variable)));
        assert!(has_dynamic_storage(ColumnKind::Other));
    }
}
