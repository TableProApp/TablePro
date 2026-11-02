/// What one statement of a write did, where the engine could not say
/// whether it ran.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StatementOutcome {
    /// The server refused it. It did not apply.
    Failed,
    /// It was in flight when the connection went away, so whether it
    /// applied is not known.
    Unknown,
}

/// What a write did, statement by statement.
///
/// `None` where the engine does not report a count for that statement,
/// which is not the same as zero rows.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct WriteReport {
    pub rows_affected: Vec<Option<u64>>,
}

impl WriteReport {
    pub fn new(rows_affected: Vec<Option<u64>>) -> Self {
        Self { rows_affected }
    }

    /// The rows every statement touched, or `None` when any statement
    /// did not report a count.
    pub fn total_rows(&self) -> Option<u64> {
        self.rows_affected.iter().copied().sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_report_adds_up_only_when_every_statement_counted() {
        assert_eq!(WriteReport::new(vec![Some(2), Some(3)]).total_rows(), Some(5));
        assert_eq!(WriteReport::new(vec![Some(2), None]).total_rows(), None);
    }
}
