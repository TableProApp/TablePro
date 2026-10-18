use super::RefusalReason;

/// Whether one change to one column can be made.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Permission {
    Allowed,
    Refused(RefusalReason),
}

impl Permission {
    pub fn is_allowed(&self) -> bool {
        matches!(self, Self::Allowed)
    }

    pub fn refusal(&self) -> Option<&RefusalReason> {
        match self {
            Self::Allowed => None,
            Self::Refused(reason) => Some(reason),
        }
    }

    /// `Allowed` when `allowed` holds, otherwise refused for `reason`.
    pub fn unless(allowed: bool, reason: RefusalReason) -> Self {
        match allowed {
            true => Self::Allowed,
            false => Self::Refused(reason),
        }
    }

    /// The first refusal of the two. A change needs every check to pass,
    /// and the user is told the first one that did not.
    pub fn and(self, then: impl FnOnce() -> Permission) -> Self {
        match self {
            Self::Allowed => then(),
            refused => refused,
        }
    }
}
