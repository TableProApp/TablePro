/// Why a save did not start. Nothing was sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveRejection {
    /// The last save's outcome is unknown, and saving again could apply
    /// the same changes twice.
    OutcomeUnknown,
    AlreadySaving,
    ReadOnly,
    /// The changes cannot be written as they stand.
    Invalid(String),
    NoConnection,
}

impl SaveRejection {
    /// What to tell the user.
    pub fn message(&self) -> String {
        match self {
            Self::OutcomeUnknown => crate::i18n::gettext(
                "The last save may already be in the database. Discard these changes to see what the table holds now.",
            ),
            Self::AlreadySaving => crate::i18n::gettext("These changes are already being saved."),
            Self::ReadOnly => crate::i18n::gettext("This connection is read-only."),
            Self::Invalid(reason) => reason.clone(),
            Self::NoConnection => crate::i18n::gettext("No active connection."),
        }
    }
}
