use tablepro_core::{ReadOnlyEnforcement, SafeModeLevel};

pub(crate) fn label(level: SafeModeLevel) -> String {
    match level {
        SafeModeLevel::Off => crate::i18n::gettext("Off"),
        SafeModeLevel::ConfirmWrites => crate::i18n::gettext("Confirm Writes"),
        SafeModeLevel::ReadOnly => crate::i18n::gettext("Read-Only"),
    }
}

/// What the level does on this engine. Read-Only's guarantee differs by
/// engine, so the row says which one the user is getting.
pub(crate) fn subtitle(level: SafeModeLevel, enforcement: ReadOnlyEnforcement) -> String {
    match (level, enforcement) {
        (SafeModeLevel::Off, _) => {
            crate::i18n::gettext("Asks only before DROP, TRUNCATE, and DELETE or UPDATE without WHERE.")
        }
        (SafeModeLevel::ConfirmWrites, _) => {
            crate::i18n::gettext("Asks before every statement that changes the database.")
        }
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::EngineEnforced) => {
            crate::i18n::gettext("The database refuses changes on this connection.")
        }
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::SessionDefault) => crate::i18n::gettext(
            "TablePro refuses statements that write, and the server opens each transaction read-only. Use a read-only login for a guarantee.",
        ),
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::LoginPrivileges) => crate::i18n::gettext(
            "TablePro refuses statements that write, but SQL Server cannot enforce this. Use a login granted only SELECT.",
        ),
    }
}

/// The level's name in the `win.safe-mode` action's state.
pub(crate) fn action_target(level: SafeModeLevel) -> &'static str {
    match level {
        SafeModeLevel::Off => "off",
        SafeModeLevel::ConfirmWrites => "confirm-writes",
        SafeModeLevel::ReadOnly => "read-only",
    }
}

pub(crate) fn from_action_target(target: &str) -> Option<SafeModeLevel> {
    SafeModeLevel::ALL
        .into_iter()
        .find(|level| action_target(*level) == target)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn every_level_has_its_own_target_and_reads_back() {
        let targets: HashSet<&str> = SafeModeLevel::ALL.into_iter().map(action_target).collect();

        assert_eq!(targets.len(), SafeModeLevel::ALL.len());
        for level in SafeModeLevel::ALL {
            assert_eq!(from_action_target(action_target(level)), Some(level));
        }
        assert_eq!(from_action_target("readonly"), None);
    }

    #[test]
    fn read_only_says_what_each_engine_guarantees() {
        let enforcements = [
            ReadOnlyEnforcement::EngineEnforced,
            ReadOnlyEnforcement::SessionDefault,
            ReadOnlyEnforcement::LoginPrivileges,
        ];
        let texts: HashSet<String> = enforcements
            .into_iter()
            .map(|enforcement| subtitle(SafeModeLevel::ReadOnly, enforcement))
            .collect();

        assert_eq!(texts.len(), enforcements.len());
        assert_eq!(
            subtitle(SafeModeLevel::ConfirmWrites, ReadOnlyEnforcement::EngineEnforced),
            subtitle(SafeModeLevel::ConfirmWrites, ReadOnlyEnforcement::LoginPrivileges),
        );
    }
}
