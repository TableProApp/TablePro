/// Which way a keyset page reads from its anchor row.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeysetDirection {
    After,
    /// The SQL reverses the sort and the fetcher reverses the rows
    /// back, so the user sees them in the order they expect.
    Before,
}

impl KeysetDirection {
    /// The comparison the row-value predicate uses.
    pub fn comparison(self) -> &'static str {
        match self {
            Self::After => ">",
            Self::Before => "<",
        }
    }

    /// Whether the ORDER BY has to be flipped to read this way.
    pub fn reverses_order(self) -> bool {
        matches!(self, Self::Before)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reading_backward_flips_the_comparison_and_the_order() {
        assert_eq!(KeysetDirection::After.comparison(), ">");
        assert!(!KeysetDirection::After.reverses_order());
        assert_eq!(KeysetDirection::Before.comparison(), "<");
        assert!(KeysetDirection::Before.reverses_order());
    }
}
