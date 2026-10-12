use crate::error::DriverError;
use crate::foreign_key_check::ForeignKeyCheck;

/// Whether foreign keys stay on while a batch runs.
///
/// The batch carries this rather than leaving the driver to infer it,
/// because which tables to check is plan knowledge: a rebuild knows the
/// table it replaced, the children that point at it and the names on
/// both sides of a rename, and none of that can be recovered from the
/// statements alone.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum ForeignKeyMode {
    #[default]
    Enforced,
    /// Off for the batch, then checked: the batch rolls back if it
    /// leaves a violation in these tables that was not there before.
    /// Only SQLite can suspend foreign keys, because a table rebuild
    /// there needs them off for the copy.
    SuspendedThenVerified { checks: Vec<ForeignKeyCheck> },
}

impl ForeignKeyMode {
    pub fn is_enforced(&self) -> bool {
        matches!(self, Self::Enforced)
    }

    /// Refuse a suspended batch before anything is sent, for an engine
    /// that has no way to suspend foreign keys.
    pub fn require_enforced(&self) -> Result<(), DriverError> {
        match self {
            Self::Enforced => Ok(()),
            Self::SuspendedThenVerified { .. } => Err(DriverError::Unsupported {
                feature: "foreign key suspension",
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::meta::TableRef;

    #[test]
    fn an_engine_without_suspension_refuses_a_suspended_batch() {
        let suspended = ForeignKeyMode::SuspendedThenVerified {
            checks: vec![ForeignKeyCheck::same_table(TableRef::unqualified("orders"))],
        };

        let refusal = suspended.require_enforced();

        assert!(
            matches!(
                refusal,
                Err(DriverError::Unsupported {
                    feature: "foreign key suspension"
                })
            ),
            "got {refusal:?}"
        );
        assert!(ForeignKeyMode::Enforced.require_enforced().is_ok());
        assert!(ForeignKeyMode::default().is_enforced());
    }
}
