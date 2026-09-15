use crate::value::Value;

/// What the user put in a cell.
///
/// Leaving a cell empty in a draft row is not the same as typing NULL:
/// the first asks the server for its default, the second stores a null.
/// Keeping them apart is what lets an insert omit the column.
#[derive(Debug, Clone, PartialEq)]
pub enum CellInput {
    /// Omit the column so the server applies its default.
    Default,
    Value(Value),
}

impl CellInput {
    pub fn value(&self) -> Option<&Value> {
        match self {
            Self::Value(value) => Some(value),
            Self::Default => None,
        }
    }

    pub fn is_default(&self) -> bool {
        matches!(self, Self::Default)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_default_is_not_a_null() {
        assert!(CellInput::Default.is_default());
        assert_eq!(CellInput::Default.value(), None);

        let null = CellInput::Value(Value::Null);
        assert!(!null.is_default());
        assert_eq!(null.value(), Some(&Value::Null));
    }
}
