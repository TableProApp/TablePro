use postgres_types::{Kind, Type};
use tablepro_core::column::{
    BoolStorage, ColumnKind, FloatWidth, IntegerKind, IntegerWidth, NetworkFamily, ReadForm, TemporalZone, TextLength,
    TimeRange,
};

use super::pg_typmod::{bit_length, character_length, fractional_digits, numeric_precision_scale};
use crate::codec::{decodes_natively, oid};

/// What the catalogue says about a column's type once domains are seen
/// through: the base type, its modifier and, for an array, its element.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TypeFacts {
    pub(crate) oid: u32,
    pub(crate) typmod: i32,
    pub(crate) shape: TypeShape,
    pub(crate) name: String,
    pub(crate) element: Option<Box<TypeFacts>>,
    pub(crate) enum_labels: Vec<String>,
}

/// `pg_type.typtype`, the one fact that decides the kind of a type that
/// is not built in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TypeShape {
    Base,
    Composite,
    Enum,
    Range,
    Pseudo,
}

impl TypeShape {
    pub(crate) fn from_typtype(typtype: &str) -> Self {
        match typtype {
            "c" => Self::Composite,
            "e" => Self::Enum,
            "r" | "m" => Self::Range,
            "p" => Self::Pseudo,
            _ => Self::Base,
        }
    }
}

impl TypeFacts {
    /// The facts tokio-postgres already holds about a result column.
    pub(crate) fn of_type(ty: &Type, typmod: i32) -> Self {
        let mut facts = Self {
            oid: ty.oid(),
            typmod,
            shape: TypeShape::Base,
            name: ty.name().to_owned(),
            element: None,
            enum_labels: Vec::new(),
        };
        match ty.kind() {
            Kind::Array(element) => facts.element = Some(Box::new(Self::of_type(element, -1))),
            Kind::Domain(base) => return Self::of_type(base, typmod),
            Kind::Enum(labels) => {
                facts.shape = TypeShape::Enum;
                facts.enum_labels = labels.clone();
            }
            Kind::Composite(_) => facts.shape = TypeShape::Composite,
            Kind::Range(_) | Kind::Multirange(_) => facts.shape = TypeShape::Range,
            Kind::Pseudo => facts.shape = TypeShape::Pseudo,
            _ => {}
        }
        facts
    }

    pub(crate) fn kind(&self) -> ColumnKind {
        if let Some(element) = &self.element {
            return ColumnKind::Array {
                element: Box::new(element.kind()),
            };
        }
        match self.shape {
            TypeShape::Enum => {
                return ColumnKind::Enum {
                    labels: self.enum_labels.clone(),
                    multiple: false,
                };
            }
            TypeShape::Composite => return ColumnKind::Composite,
            TypeShape::Range | TypeShape::Pseudo => return ColumnKind::Other,
            TypeShape::Base => {}
        }
        if let Some(kind) = builtin_kind(self.oid, self.typmod) {
            return kind;
        }
        match self.name.as_str() {
            // PostGIS types are extension types with no fixed OID.
            "geometry" | "geography" => ColumnKind::Spatial,
            _ => ColumnKind::Other,
        }
    }

    /// How a page reads the column. Anything without an exact binary
    /// decoder is projected as text, which also keeps every result OID a
    /// built-in one, so tokio-postgres never has to look a type up.
    pub(crate) fn read_form(&self) -> ReadForm {
        if self.oid == oid::MONEY {
            return ReadForm::ServerNumeric;
        }
        match Type::from_oid(self.oid) {
            Some(ty) if decodes_natively(&ty) => ReadForm::Native,
            _ => ReadForm::ServerText,
        }
    }
}

fn builtin_kind(type_oid: u32, typmod: i32) -> Option<ColumnKind> {
    let int = |width| ColumnKind::Integer(IntegerKind { width, signed: true });
    Some(match type_oid {
        oid::BOOL => ColumnKind::Bool(BoolStorage::Native),
        oid::INT2 => int(IntegerWidth::W16),
        oid::INT4 => int(IntegerWidth::W32),
        oid::INT8 => int(IntegerWidth::W64),
        oid::OID => ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: false,
        }),
        oid::FLOAT4 => ColumnKind::Float(FloatWidth::F32),
        oid::FLOAT8 => ColumnKind::Float(FloatWidth::F64),
        oid::NUMERIC => {
            let (precision, scale) = numeric_precision_scale(typmod);
            ColumnKind::Decimal { precision, scale }
        }
        oid::MONEY => ColumnKind::Money { scale: None },
        oid::TEXT | oid::UNKNOWN => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        oid::VARCHAR => ColumnKind::Text {
            length: character_length(typmod).map_or(TextLength::Unbounded, TextLength::Varying),
        },
        oid::BPCHAR => ColumnKind::Text {
            length: character_length(typmod).map_or(TextLength::Unbounded, TextLength::Fixed),
        },
        oid::NAME => ColumnKind::Text {
            length: TextLength::Varying(63),
        },
        oid::CHAR => ColumnKind::Text {
            length: TextLength::Fixed(1),
        },
        oid::BYTEA => ColumnKind::Bytes {
            length: TextLength::Unbounded,
        },
        oid::UUID => ColumnKind::Uuid,
        oid::JSON => ColumnKind::Json { binary: false },
        oid::JSONB => ColumnKind::Json { binary: true },
        oid::DATE => ColumnKind::Date,
        oid::TIME | oid::TIMETZ => ColumnKind::Time {
            fractional_digits: fractional_digits(typmod),
            with_offset: type_oid == oid::TIMETZ,
            range: TimeRange::TimeOfDay,
        },
        oid::TIMESTAMP => ColumnKind::Timestamp {
            fractional_digits: fractional_digits(typmod),
            zone: TemporalZone::Naive,
        },
        oid::TIMESTAMPTZ => ColumnKind::Timestamp {
            fractional_digits: fractional_digits(typmod),
            zone: TemporalZone::Offset,
        },
        oid::INTERVAL => ColumnKind::Interval,
        oid::BIT | oid::VARBIT => ColumnKind::BitString {
            length: bit_length(typmod),
            varying: type_oid == oid::VARBIT,
        },
        oid::INET => ColumnKind::Network(NetworkFamily::Inet),
        oid::CIDR => ColumnKind::Network(NetworkFamily::Cidr),
        oid::MACADDR => ColumnKind::Network(NetworkFamily::MacAddr),
        oid::MACADDR8 => ColumnKind::Network(NetworkFamily::MacAddr8),
        oid::XML => ColumnKind::Xml,
        oid::POINT | oid::LSEG | oid::PATH | oid::BOX | oid::POLYGON | oid::LINE | oid::CIRCLE => ColumnKind::Spatial,
        // Full-text values have no editor of their own; the server's text
        // is what the grid shows and writes back.
        oid::TSVECTOR | oid::TSQUERY => ColumnKind::Other,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base(type_oid: u32, typmod: i32, name: &str) -> TypeFacts {
        TypeFacts {
            oid: type_oid,
            typmod,
            shape: TypeShape::Base,
            name: name.to_owned(),
            element: None,
            enum_labels: Vec::new(),
        }
    }

    #[test]
    fn pg_enum_classifies_with_labels_in_sort_order() {
        let mood = TypeFacts {
            shape: TypeShape::Enum,
            enum_labels: vec!["sad".to_owned(), "ok".to_owned(), "happy".to_owned()],
            ..base(70_000, -1, "mood")
        };

        assert_eq!(
            mood.kind(),
            ColumnKind::Enum {
                labels: vec!["sad".to_owned(), "ok".to_owned(), "happy".to_owned()],
                multiple: false
            }
        );
        assert_eq!(mood.read_form(), ReadForm::ServerText);
    }

    #[test]
    fn pg_domain_over_int4_is_integer_native() {
        let domain = Type::new(
            "positive".to_owned(),
            70_001,
            Kind::Domain(Type::INT4),
            "public".to_owned(),
        );

        let facts = TypeFacts::of_type(&domain, -1);

        assert_eq!(
            facts.kind(),
            ColumnKind::Integer(IntegerKind {
                width: IntegerWidth::W32,
                signed: true
            })
        );
        assert_eq!(facts.read_form(), ReadForm::Native);
    }

    #[test]
    fn pg_int4range_is_other_server_text() {
        let range = TypeFacts {
            shape: TypeShape::Range,
            ..base(Type::INT4_RANGE.oid(), -1, "int4range")
        };

        assert_eq!(range.kind(), ColumnKind::Other);
        assert_eq!(range.read_form(), ReadForm::ServerText);
    }

    #[test]
    fn pg_tsvector_builtin_without_codec_is_server_text() {
        let tsvector = base(oid::TSVECTOR, -1, "tsvector");

        assert_eq!(tsvector.kind(), ColumnKind::Other);
        assert_eq!(tsvector.read_form(), ReadForm::ServerText);
    }

    #[test]
    fn money_reads_as_numeric_text_and_arrays_follow_their_element() {
        assert_eq!(base(oid::MONEY, -1, "money").read_form(), ReadForm::ServerNumeric);

        let int_array = TypeFacts::of_type(&Type::INT4_ARRAY, -1);
        assert!(matches!(int_array.kind(), ColumnKind::Array { .. }));
        assert_eq!(int_array.read_form(), ReadForm::Native);

        let varchar = base(oid::VARCHAR, 14, "varchar");
        assert_eq!(
            varchar.kind(),
            ColumnKind::Text {
                length: TextLength::Varying(10)
            }
        );
        let geometry = base(80_000, -1, "geometry");
        assert_eq!(geometry.kind(), ColumnKind::Spatial);
        assert_eq!(geometry.read_form(), ReadForm::ServerText);
        assert_eq!(base(oid::TSQUERY, -1, "tsquery").read_form(), ReadForm::ServerText);
    }
}
