/// What a column holds, independent of the engine's spelling for it.
///
/// The UI picks an editor, a default alignment and an empty-string rule
/// from this rather than from the type name, so a new engine spelling
/// never needs a new branch in the grid.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ColumnKind {
    Boolean,
    Integer(IntegerKind),
    Decimal,
    Float(FloatKind),
    Text(TextKind),
    Binary,
    Date,
    Time,
    Timestamp,
    Interval,
    Uuid,
    Json,
    Enumeration,
    Set,
    BitString,
    Network,
    Geometry,
    Array,
    /// The driver could not place the type. The value round-trips as the
    /// server's own text.
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum IntegerKind {
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    I128,
    U128,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FloatKind {
    F32,
    F64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum TextKind {
    /// Padded to a fixed length by the server, so a trailing-space diff
    /// is the server's doing and not the user's.
    Fixed,
    Variable,
    /// A large object the grid shows truncated.
    Large,
}

impl ColumnKind {
    pub fn is_textual(self) -> bool {
        matches!(self, Self::Text(_) | Self::Json | Self::Enumeration | Self::Set)
    }

    pub fn is_numeric(self) -> bool {
        matches!(self, Self::Integer(_) | Self::Decimal | Self::Float(_))
    }

    /// Whether an empty cell means the empty string rather than NULL. A
    /// numeric or temporal column has no empty value, so clearing the
    /// cell there can only mean NULL.
    pub fn accepts_empty_string(self) -> bool {
        self.is_textual() || matches!(self, Self::Binary | Self::BitString)
    }

    /// Whether a line break belongs in the value. The grid keeps a
    /// single-line editor for everything else, so Enter commits.
    pub fn accepts_line_breaks(self) -> bool {
        matches!(
            self,
            Self::Text(TextKind::Large) | Self::Text(TextKind::Variable) | Self::Json
        )
    }
}

impl IntegerKind {
    pub const ALL: [IntegerKind; 10] = [
        IntegerKind::I8,
        IntegerKind::U8,
        IntegerKind::I16,
        IntegerKind::U16,
        IntegerKind::I32,
        IntegerKind::U32,
        IntegerKind::I64,
        IntegerKind::U64,
        IntegerKind::I128,
        IntegerKind::U128,
    ];

    pub fn is_signed(self) -> bool {
        matches!(self, Self::I8 | Self::I16 | Self::I32 | Self::I64 | Self::I128)
    }

    /// Inclusive range the kind can hold, as i128 where it fits.
    pub fn signed_bounds(self) -> Option<(i128, i128)> {
        match self {
            Self::I8 => Some((i128::from(i8::MIN), i128::from(i8::MAX))),
            Self::U8 => Some((0, i128::from(u8::MAX))),
            Self::I16 => Some((i128::from(i16::MIN), i128::from(i16::MAX))),
            Self::U16 => Some((0, i128::from(u16::MAX))),
            Self::I32 => Some((i128::from(i32::MIN), i128::from(i32::MAX))),
            Self::U32 => Some((0, i128::from(u32::MAX))),
            Self::I64 => Some((i128::from(i64::MIN), i128::from(i64::MAX))),
            Self::U64 => Some((0, i128::from(u64::MAX))),
            Self::I128 => Some((i128::MIN, i128::MAX)),
            // u128::MAX does not fit in i128.
            Self::U128 => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn column_kind_helpers_table() {
        let cases = [
            (ColumnKind::Text(TextKind::Variable), true, false, true, true),
            (ColumnKind::Text(TextKind::Fixed), true, false, true, false),
            (ColumnKind::Text(TextKind::Large), true, false, true, true),
            (ColumnKind::Json, true, false, true, true),
            (ColumnKind::Enumeration, true, false, true, false),
            (ColumnKind::Integer(IntegerKind::I32), false, true, false, false),
            (ColumnKind::Decimal, false, true, false, false),
            (ColumnKind::Float(FloatKind::F64), false, true, false, false),
            (ColumnKind::Boolean, false, false, false, false),
            (ColumnKind::Binary, false, false, true, false),
            (ColumnKind::BitString, false, false, true, false),
            (ColumnKind::Timestamp, false, false, false, false),
            (ColumnKind::Uuid, false, false, false, false),
        ];

        for (kind, textual, numeric, empty, breaks) in cases {
            assert_eq!(kind.is_textual(), textual, "is_textual {kind:?}");
            assert_eq!(kind.is_numeric(), numeric, "is_numeric {kind:?}");
            assert_eq!(kind.accepts_empty_string(), empty, "accepts_empty_string {kind:?}");
            assert_eq!(kind.accepts_line_breaks(), breaks, "accepts_line_breaks {kind:?}");
        }
    }

    #[test]
    fn integer_kind_signedness_matches_its_bounds() {
        for kind in IntegerKind::ALL {
            match kind.signed_bounds() {
                Some((low, _)) => assert_eq!(low < 0, kind.is_signed(), "{kind:?}"),
                None => assert!(!kind.is_signed(), "{kind:?} has no i128 bounds"),
            }
        }
    }
}
