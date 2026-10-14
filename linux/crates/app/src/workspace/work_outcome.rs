use gtk4::glib;

use super::SaveOutcome;

/// How a tab's run, save or export ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, glib::Enum)]
#[enum_type(name = "TableProWorkOutcome")]
pub enum WorkOutcome {
    Succeeded,
    Failed,
    /// The user stopped it.
    Cancelled,
}

/// A save whose outcome nobody knows did not save what the user asked
/// it to, as far as the user can tell.
impl From<&SaveOutcome> for WorkOutcome {
    fn from(outcome: &SaveOutcome) -> Self {
        match outcome {
            SaveOutcome::Committed { .. } => Self::Succeeded,
            SaveOutcome::RolledBack(_) | SaveOutcome::Unknown(_) => Self::Failed,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::DriverError;

    use super::*;
    use crate::workspace::{RollbackCause, UnknownCause};

    #[test]
    fn only_a_commit_is_a_saved_change() {
        assert_eq!(
            WorkOutcome::from(&SaveOutcome::Committed { rows: Some(1) }),
            WorkOutcome::Succeeded
        );
        assert_eq!(
            WorkOutcome::from(&SaveOutcome::RolledBack(RollbackCause::Driver(DriverError::server(
                "duplicate key"
            )))),
            WorkOutcome::Failed
        );
        assert_eq!(
            WorkOutcome::from(&SaveOutcome::Unknown(UnknownCause::Interrupted)),
            WorkOutcome::Failed
        );
    }
}
