use super::{BoolStorage, FloatWidth, IntegerKind, NetworkFamily, TemporalZone, TextLength, TimeRange};

/// What a column holds, independent of the engine's spelling for it.
///
/// The UI picks an editor, a default alignment and an empty-string rule
/// from this rather than from the type name, so a new engine spelling
/// never needs a new branch in the grid.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ColumnKind {
    Bool(BoolStorage),
    Integer(IntegerKind),
    Float(FloatWidth),
    Decimal {
        precision: Option<u32>,
        scale: Option<u32>,
    },
    Money {
        scale: Option<u8>,
    },
    Text {
        length: TextLength,
    },
    Enum {
        labels: Vec<String>,
        /// MySQL SET: the value is any combination of the labels.
        multiple: bool,
    },
    Bytes {
        length: TextLength,
    },
    Uuid,
    Json {
        binary: bool,
    },
    Date,
    Time {
        fractional_digits: Option<u8>,
        with_offset: bool,
        range: TimeRange,
    },
    Timestamp {
        fractional_digits: Option<u8>,
        zone: TemporalZone,
    },
    Interval,
    BitString {
        length: Option<u32>,
        varying: bool,
    },
    Network(NetworkFamily),
    Xml,
    Spatial,
    Array {
        element: Box<ColumnKind>,
    },
    /// A value whose type is chosen per row: ClickHouse Variant, SQL
    /// Server sql_variant.
    Variant,
    /// ClickHouse Map, Tuple, Nested, Dynamic, JSON and
    /// AggregateFunction, and PostgreSQL composite types.
    Composite,
    /// The driver could not place the type. The value round-trips as the
    /// server's own text.
    Other,
}

impl ColumnKind {
    pub fn is_textual(&self) -> bool {
        matches!(self, Self::Text { .. } | Self::Enum { .. } | Self::Xml | Self::Other)
    }

    pub fn is_numeric(&self) -> bool {
        matches!(
            self,
            Self::Integer(_) | Self::Float(_) | Self::Decimal { .. } | Self::Money { .. }
        )
    }

    /// Whether an empty cell means the empty string rather than NULL.
    /// Anywhere else the empty string is not a value the column can
    /// hold, so clearing the cell can only mean NULL.
    pub fn accepts_empty_string(&self) -> bool {
        match self {
            Self::Text { .. } | Self::Other => true,
            Self::Enum { labels, .. } => labels.iter().any(String::is_empty),
            _ => false,
        }
    }

    /// Whether a line break belongs in the value. The grid keeps a
    /// single-line editor for everything else, so Enter commits.
    pub fn accepts_line_breaks(&self) -> bool {
        matches!(self, Self::Text { .. } | Self::Json { .. } | Self::Xml | Self::Other)
    }

    /// The fractional-second digits a time or timestamp column declares,
    /// as in `timestamp(6)`.
    ///
    /// `None` where the type names none, which is not the same as zero:
    /// a value's own fraction is then all anyone knows about it.
    pub fn fractional_digits(&self) -> Option<u8> {
        match self {
            Self::Time { fractional_digits, .. } | Self::Timestamp { fractional_digits, .. } => *fractional_digits,
            _ => None,
        }
    }

    /// The digits after the decimal point a decimal or money column
    /// declares, as in `numeric(38,10)`.
    pub fn decimal_scale(&self) -> Option<u32> {
        match self {
            Self::Decimal { scale, .. } => *scale,
            Self::Money { scale } => scale.map(u32::from),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::IntegerWidth;
    use super::*;

    fn enumeration(labels: &[&str]) -> ColumnKind {
        ColumnKind::Enum {
            labels: labels.iter().map(|label| (*label).to_owned()).collect(),
            multiple: false,
        }
    }

    #[test]
    fn column_kind_helpers_table() {
        let int = ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        });
        let time = ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range: TimeRange::TimeOfDay,
        };
        let stamp = ColumnKind::Timestamp {
            fractional_digits: Some(6),
            zone: TemporalZone::Offset,
        };
        // (kind, is_textual, is_numeric, accepts_empty_string, accepts_line_breaks)
        let cases = [
            (ColumnKind::Bool(BoolStorage::Native), false, false, false, false),
            (ColumnKind::Bool(BoolStorage::Integer), false, false, false, false),
            (int, false, true, false, false),
            (ColumnKind::Float(FloatWidth::F64), false, true, false, false),
            (
                ColumnKind::Decimal {
                    precision: Some(10),
                    scale: Some(2),
                },
                false,
                true,
                false,
                false,
            ),
            (ColumnKind::Money { scale: Some(4) }, false, true, false, false),
            (
                ColumnKind::Text {
                    length: TextLength::Unbounded,
                },
                true,
                false,
                true,
                true,
            ),
            (
                ColumnKind::Text {
                    length: TextLength::Fixed(4),
                },
                true,
                false,
                true,
                true,
            ),
            (enumeration(&["a", "b"]), true, false, false, false),
            (enumeration(&["a", ""]), true, false, true, false),
            (
                ColumnKind::Bytes {
                    length: TextLength::Unbounded,
                },
                false,
                false,
                false,
                false,
            ),
            (ColumnKind::Uuid, false, false, false, false),
            (ColumnKind::Json { binary: true }, false, false, false, true),
            (ColumnKind::Date, false, false, false, false),
            (time, false, false, false, false),
            (stamp, false, false, false, false),
            (ColumnKind::Interval, false, false, false, false),
            (
                ColumnKind::BitString {
                    length: Some(8),
                    varying: false,
                },
                false,
                false,
                false,
                false,
            ),
            (ColumnKind::Network(NetworkFamily::Inet), false, false, false, false),
            (ColumnKind::Xml, true, false, false, true),
            (ColumnKind::Spatial, false, false, false, false),
            (
                ColumnKind::Array {
                    element: Box::new(ColumnKind::Uuid),
                },
                false,
                false,
                false,
                false,
            ),
            (ColumnKind::Variant, false, false, false, false),
            (ColumnKind::Composite, false, false, false, false),
            (ColumnKind::Other, true, false, true, true),
        ];

        for (kind, textual, numeric, empty, breaks) in cases {
            assert_eq!(kind.is_textual(), textual, "is_textual {kind:?}");
            assert_eq!(kind.is_numeric(), numeric, "is_numeric {kind:?}");
            assert_eq!(kind.accepts_empty_string(), empty, "accepts_empty_string {kind:?}");
            assert_eq!(kind.accepts_line_breaks(), breaks, "accepts_line_breaks {kind:?}");
        }
    }

    #[test]
    fn declared_precision_comes_from_the_kind() {
        let stamp = ColumnKind::Timestamp {
            fractional_digits: Some(6),
            zone: TemporalZone::Offset,
        };
        let undeclared = ColumnKind::Time {
            fractional_digits: None,
            with_offset: false,
            range: TimeRange::TimeOfDay,
        };
        let decimal = ColumnKind::Decimal {
            precision: Some(38),
            scale: Some(10),
        };

        assert_eq!(stamp.fractional_digits(), Some(6));
        assert_eq!(stamp.decimal_scale(), None, "a timestamp has no decimal scale");
        assert_eq!(undeclared.fractional_digits(), None);
        assert_eq!(decimal.decimal_scale(), Some(10));
        assert_eq!(ColumnKind::Money { scale: Some(4) }.decimal_scale(), Some(4));
        assert_eq!(
            ColumnKind::Text {
                length: TextLength::Varying(255)
            }
            .fractional_digits(),
            None,
            "a length was read as a precision"
        );
    }
}
