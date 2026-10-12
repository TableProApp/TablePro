use std::fmt;

/// An integer column's storage width and sign.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IntegerKind {
    pub width: IntegerWidth,
    pub signed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegerWidth {
    W8,
    W16,
    /// MySQL MEDIUMINT.
    W24,
    W32,
    W64,
    W128,
    /// ClickHouse Int256 and UInt256.
    W256,
}

impl IntegerWidth {
    pub const ALL: [IntegerWidth; 7] = [
        IntegerWidth::W8,
        IntegerWidth::W16,
        IntegerWidth::W24,
        IntegerWidth::W32,
        IntegerWidth::W64,
        IntegerWidth::W128,
        IntegerWidth::W256,
    ];

    pub fn bits(self) -> u32 {
        match self {
            Self::W8 => 8,
            Self::W16 => 16,
            Self::W24 => 24,
            Self::W32 => 32,
            Self::W64 => 64,
            Self::W128 => 128,
            Self::W256 => 256,
        }
    }
}

impl fmt::Display for IntegerKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let sign = if self.signed { "signed" } else { "unsigned" };
        write!(f, "{sign} {}-bit", self.width.bits())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_integer_kind_names_its_sign_and_width() {
        let kind = IntegerKind {
            width: IntegerWidth::W24,
            signed: false,
        };

        assert_eq!(kind.to_string(), "unsigned 24-bit");
    }
}
