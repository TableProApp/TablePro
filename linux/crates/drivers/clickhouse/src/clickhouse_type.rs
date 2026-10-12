use std::collections::HashMap;

use clickhouse_types::data_types::{DataTypeNode, DateTimePrecision};
use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, ReadForm,
    SqlTypeExpr, TemporalZone, TextLength, TimeRange, classify_type_name, has_dynamic_storage,
};

use crate::cell_seed::CellPlan;

/// What one ClickHouse type name means: how the grid treats it, how a
/// cell of it is read off the wire, and whether it holds NULL.
///
/// The name comes from the server (`system.columns.type` or a result
/// header), so it is also the declaration a value binds against.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct ClickHouseType {
    pub(crate) column_type: ColumnType,
    pub(crate) plan: CellPlan,
    pub(crate) nullable: bool,
}

impl ClickHouseType {
    pub(crate) fn parse(text: &str) -> Self {
        let text = text.trim();
        match parse_node(text) {
            Some(node) => Self::from_node(text, &node),
            None => Self::unparsed(text),
        }
    }

    fn from_node(text: &str, node: &DataTypeNode) -> Self {
        let kind = kind_of(node);
        let plan = CellPlan::of(node);
        let read_form = if plan.reads_server_text() {
            ReadForm::ServerText
        } else {
            ReadForm::Native
        };
        Self {
            column_type: ColumnType {
                name: text.to_owned(),
                dynamic_storage: has_dynamic_storage(&kind),
                kind,
                catalog: Some(CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text(text),
                    cast_target: SqlTypeExpr::from_catalog_text(value_type(node).to_string()),
                }),
                read_form,
            },
            plan,
            nullable: is_nullable(node),
        }
    }

    /// A name clickhouse-types does not parse, such as an
    /// AggregateFunction or a named Tuple. The shared spellings still
    /// place most of them, and the value is read as the server's text.
    fn unparsed(text: &str) -> Self {
        let kind = classify_type_name(text);
        Self {
            column_type: ColumnType {
                name: text.to_owned(),
                dynamic_storage: true,
                kind,
                catalog: Some(CatalogType {
                    declaration: SqlTypeExpr::from_catalog_text(text),
                    cast_target: SqlTypeExpr::from_catalog_text(text),
                }),
                read_form: ReadForm::ServerText,
            },
            plan: CellPlan::Raw {
                type_name: text.to_owned(),
            },
            nullable: text.starts_with("Nullable(") || text.starts_with("LowCardinality(Nullable("),
        }
    }
}

/// clickhouse-types slices a name at fixed byte offsets and at its last
/// byte, which land on character boundaries only when the name is ASCII
/// or ends in the closing parenthesis the server always prints.
fn parse_node(text: &str) -> Option<DataTypeNode> {
    if !text.is_ascii() && !text.ends_with(')') {
        return None;
    }
    DataTypeNode::new(text).ok()
}

/// The type a value of this column is bound as: the wrappers change how
/// it is stored, not what text the server parses for it, and a NULL is
/// written as the literal rather than bound.
fn value_type(node: &DataTypeNode) -> &DataTypeNode {
    match node {
        DataTypeNode::Nullable(inner) | DataTypeNode::LowCardinality(inner) => value_type(inner),
        other => other,
    }
}

fn is_nullable(node: &DataTypeNode) -> bool {
    match node {
        DataTypeNode::Nullable(_) => true,
        DataTypeNode::LowCardinality(inner) => is_nullable(inner),
        _ => false,
    }
}

fn kind_of(node: &DataTypeNode) -> ColumnKind {
    match node {
        DataTypeNode::Bool => ColumnKind::Bool(BoolStorage::Native),
        DataTypeNode::UInt8 => integer(IntegerWidth::W8, false),
        DataTypeNode::UInt16 => integer(IntegerWidth::W16, false),
        DataTypeNode::UInt32 => integer(IntegerWidth::W32, false),
        DataTypeNode::UInt64 => integer(IntegerWidth::W64, false),
        DataTypeNode::UInt128 => integer(IntegerWidth::W128, false),
        DataTypeNode::UInt256 => integer(IntegerWidth::W256, false),
        DataTypeNode::Int8 => integer(IntegerWidth::W8, true),
        DataTypeNode::Int16 => integer(IntegerWidth::W16, true),
        DataTypeNode::Int32 => integer(IntegerWidth::W32, true),
        DataTypeNode::Int64 => integer(IntegerWidth::W64, true),
        DataTypeNode::Int128 => integer(IntegerWidth::W128, true),
        DataTypeNode::Int256 => integer(IntegerWidth::W256, true),
        DataTypeNode::Float32 | DataTypeNode::BFloat16 => ColumnKind::Float(FloatWidth::F32),
        DataTypeNode::Float64 => ColumnKind::Float(FloatWidth::F64),
        DataTypeNode::Decimal(precision, scale, _) => ColumnKind::Decimal {
            precision: Some(u32::from(*precision)),
            scale: Some(u32::from(*scale)),
        },
        DataTypeNode::String => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        DataTypeNode::FixedString(length) => ColumnKind::Text {
            length: TextLength::Fixed(u32::try_from(*length).unwrap_or(u32::MAX)),
        },
        DataTypeNode::UUID => ColumnKind::Uuid,
        DataTypeNode::Date | DataTypeNode::Date32 => ColumnKind::Date,
        DataTypeNode::DateTime(zone) => ColumnKind::Timestamp {
            fractional_digits: Some(0),
            zone: named_zone(zone.as_deref()),
        },
        DataTypeNode::DateTime64(precision, zone) => ColumnKind::Timestamp {
            fractional_digits: Some(digits(precision)),
            zone: named_zone(zone.as_deref()),
        },
        // ClickHouse Time runs past a day in both directions.
        DataTypeNode::Time => ColumnKind::Time {
            fractional_digits: Some(0),
            with_offset: false,
            range: TimeRange::Duration,
        },
        DataTypeNode::Time64(precision) => ColumnKind::Time {
            fractional_digits: Some(digits(precision)),
            with_offset: false,
            range: TimeRange::Duration,
        },
        DataTypeNode::IPv4 => ColumnKind::Network(NetworkFamily::Ipv4),
        DataTypeNode::IPv6 => ColumnKind::Network(NetworkFamily::Ipv6),
        DataTypeNode::Nullable(inner)
        | DataTypeNode::LowCardinality(inner)
        | DataTypeNode::SimpleAggregateFunction(_, inner) => kind_of(inner),
        DataTypeNode::Array(element) => ColumnKind::Array {
            element: Box::new(kind_of(element)),
        },
        DataTypeNode::Enum(_, labels) => enumeration(labels),
        DataTypeNode::Variant(_) => ColumnKind::Variant,
        DataTypeNode::Tuple(_)
        | DataTypeNode::Map(_)
        | DataTypeNode::AggregateFunction(..)
        | DataTypeNode::Dynamic
        | DataTypeNode::JSON
        | DataTypeNode::JsonWithHint(_) => ColumnKind::Composite,
        DataTypeNode::Point
        | DataTypeNode::Ring
        | DataTypeNode::LineString
        | DataTypeNode::MultiLineString
        | DataTypeNode::Polygon
        | DataTypeNode::MultiPolygon => ColumnKind::Spatial,
        // An Interval is a count of units, which no column stores, and a
        // type added to clickhouse-types later is not guessed at.
        _ => ColumnKind::Other,
    }
}

fn integer(width: IntegerWidth, signed: bool) -> ColumnKind {
    ColumnKind::Integer(IntegerKind { width, signed })
}

fn named_zone(zone: Option<&str>) -> TemporalZone {
    zone.map_or(TemporalZone::Naive, |zone| TemporalZone::Named(zone.to_owned()))
}

fn digits(precision: &DateTimePrecision) -> u8 {
    precision.to_string().parse().unwrap_or(0)
}

/// The labels in the order of their values, which is the order the
/// server sorts and compares them in.
fn enumeration(labels: &HashMap<i16, String>) -> ColumnKind {
    let mut ordered: Vec<(&i16, &String)> = labels.iter().collect();
    ordered.sort_by_key(|(value, _)| **value);
    ColumnKind::Enum {
        labels: ordered.into_iter().map(|(_, label)| label.clone()).collect(),
        multiple: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(text: &str) -> ClickHouseType {
        ClickHouseType::parse(text)
    }

    #[test]
    fn clickhouse_lowcardinality_nullable_string_datetime64_decimal76_map() {
        let low = parsed("LowCardinality(Nullable(String))");
        assert_eq!(
            low.column_type.kind,
            ColumnKind::Text {
                length: TextLength::Unbounded
            }
        );
        assert!(low.nullable);
        assert_eq!(
            low.column_type
                .catalog
                .as_ref()
                .map(|catalog| catalog.cast_target.as_sql()),
            Some("String")
        );
        assert_eq!(
            low.column_type
                .catalog
                .as_ref()
                .map(|catalog| catalog.declaration.as_sql()),
            Some("LowCardinality(Nullable(String))")
        );

        let stamp = parsed("DateTime64(3, 'UTC')");
        assert_eq!(
            stamp.column_type.kind,
            ColumnKind::Timestamp {
                fractional_digits: Some(3),
                zone: TemporalZone::Named("UTC".to_owned()),
            }
        );
        assert!(!stamp.nullable);

        let decimal = parsed("Decimal(76, 20)");
        assert_eq!(
            decimal.column_type.kind,
            ColumnKind::Decimal {
                precision: Some(76),
                scale: Some(20)
            }
        );

        let map = parsed("Map(String, UInt64)");
        assert_eq!(map.column_type.kind, ColumnKind::Composite);
        assert_eq!(map.column_type.read_form, ReadForm::ServerText);
    }

    #[test]
    fn wide_and_unsigned_integers_keep_width_and_sign() {
        assert_eq!(parsed("UInt64").column_type.kind, integer(IntegerWidth::W64, false));
        assert_eq!(parsed("Int128").column_type.kind, integer(IntegerWidth::W128, true));
        assert_eq!(parsed("UInt256").column_type.kind, integer(IntegerWidth::W256, false));
        assert_eq!(
            parsed("Nullable(Int8)").column_type.kind,
            integer(IntegerWidth::W8, true)
        );
    }

    #[test]
    fn composites_variants_and_unparsed_names() {
        for text in [
            "Tuple(UInt8, String)",
            "Dynamic",
            "JSON",
            "AggregateFunction(uniq, UInt64)",
            "Tuple(a String, b UInt8)",
            "Nested(a String)",
        ] {
            assert_eq!(parsed(text).column_type.kind, ColumnKind::Composite, "{text}");
            assert!(parsed(text).plan.reads_server_text(), "{text}");
        }
        assert_eq!(parsed("Variant(String, UInt64)").column_type.kind, ColumnKind::Variant);
        assert_eq!(parsed("Point").column_type.kind, ColumnKind::Spatial);
        assert_eq!(parsed("NoSuchType").column_type.kind, ColumnKind::Other);
    }

    #[test]
    fn enum_labels_follow_their_values() {
        let kind = parsed("Enum8('b' = 2, 'a' = 1)").column_type.kind;

        assert_eq!(
            kind,
            ColumnKind::Enum {
                labels: vec!["a".to_owned(), "b".to_owned()],
                multiple: false
            }
        );
    }

    #[test]
    fn an_array_of_nullable_keeps_the_element_kind() {
        let array = parsed("Array(Nullable(UInt8))");

        assert_eq!(
            array.column_type.kind,
            ColumnKind::Array {
                element: Box::new(integer(IntegerWidth::W8, false))
            }
        );
        assert!(!array.nullable, "the element's NULL was read as the column's");
    }
}
