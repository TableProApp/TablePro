use gtk4 as gtk;

/// Why the session should not end under the window.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InhibitReason {
    UnsavedChanges,
    /// A write is running. Suspending would cut it off mid-commit.
    SavingChanges,
}

impl InhibitReason {
    /// What the window holds now, or `None` when a logout loses
    /// nothing.
    pub fn for_state(dirty: bool, saving: bool) -> Option<Self> {
        match (dirty, saving) {
            (_, true) => Some(Self::SavingChanges),
            (true, false) => Some(Self::UnsavedChanges),
            (false, false) => None,
        }
    }

    pub fn flags(self) -> gtk::ApplicationInhibitFlags {
        match self {
            Self::UnsavedChanges => gtk::ApplicationInhibitFlags::LOGOUT,
            Self::SavingChanges => gtk::ApplicationInhibitFlags::LOGOUT | gtk::ApplicationInhibitFlags::SUSPEND,
        }
    }

    /// Shown by the session when it asks the user to wait.
    pub fn text(self) -> String {
        match self {
            Self::UnsavedChanges => crate::i18n::gettext("There are unsaved changes"),
            Self::SavingChanges => crate::i18n::gettext("Saving changes"),
        }
    }
}
