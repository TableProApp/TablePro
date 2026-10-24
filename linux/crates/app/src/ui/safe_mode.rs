use tablepro_core::{DataModel, DriverCapabilities, ReadOnlyEnforcement, SafeModeLevel};

pub(crate) fn label(level: SafeModeLevel) -> String {
    match level {
        SafeModeLevel::Off => crate::i18n::gettext("Off"),
        SafeModeLevel::ConfirmWrites => crate::i18n::gettext("Confirm Writes"),
        SafeModeLevel::ReadOnly => crate::i18n::gettext("Read-Only"),
    }
}

/// What the level does on this engine. Read-Only's guarantee differs by
/// engine, so the row says which one the user is getting, naming an
/// engine that cannot hold a connection to reads, an engine of keys is
/// told about in commands rather than statements, and one of documents
/// in its own words for what drops or empties a collection.
pub(crate) fn subtitle(level: SafeModeLevel, capabilities: &DriverCapabilities, engine: &str) -> String {
    let keys = capabilities.data_model == DataModel::KeyValue;
    let documents = capabilities.data_model == DataModel::Document;
    match (level, capabilities.read_only) {
        (SafeModeLevel::Off, _) if keys => {
            crate::i18n::gettext("Asks only before commands that empty a database or stop the server, such as FLUSHDB.")
        }
        (SafeModeLevel::Off, _) if documents => crate::i18n::gettext(
            "Asks only before dropping a collection or database, and before deleting or updating every document.",
        ),
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::ClientGuard) if documents => crate::i18n::gettext(
            "TablePro refuses every statement that writes before it is sent; the server has no read-only mode. Use a user with only read roles for a guarantee.",
        ),
        (SafeModeLevel::Off, _) => {
            crate::i18n::gettext("Asks only before DROP, TRUNCATE, and DELETE or UPDATE without WHERE.")
        }
        (SafeModeLevel::ConfirmWrites, _) if keys => {
            crate::i18n::gettext("Asks before every command that changes the database.")
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
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::LoginPrivileges) => crate::i18n::gettext_f(
            "TablePro refuses statements that write, but {engine} cannot enforce this. Use a login granted only SELECT.",
            &[("engine", engine)],
        ),
        (SafeModeLevel::ReadOnly, ReadOnlyEnforcement::ClientGuard) => crate::i18n::gettext(
            "TablePro refuses every command that writes before it is sent; the server has no read-only mode. Use an ACL user that may only read for a guarantee.",
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

    fn capabilities(data_model: DataModel, read_only: ReadOnlyEnforcement) -> DriverCapabilities {
        DriverCapabilities {
            data_model,
            read_only,
            ..tablepro_test_support::FakeDriver::NETWORK_CAPABILITIES
        }
    }

    #[test]
    fn read_only_says_what_each_engine_guarantees() {
        let enforcements = [
            ReadOnlyEnforcement::EngineEnforced,
            ReadOnlyEnforcement::SessionDefault,
            ReadOnlyEnforcement::LoginPrivileges,
            ReadOnlyEnforcement::ClientGuard,
        ];
        let texts: HashSet<String> = enforcements
            .into_iter()
            .map(|enforcement| {
                subtitle(
                    SafeModeLevel::ReadOnly,
                    &capabilities(DataModel::Relational, enforcement),
                    "SQL Server",
                )
            })
            .collect();

        assert_eq!(texts.len(), enforcements.len());
        assert_eq!(
            subtitle(
                SafeModeLevel::ConfirmWrites,
                &capabilities(DataModel::Relational, ReadOnlyEnforcement::EngineEnforced),
                "SQLite"
            ),
            subtitle(
                SafeModeLevel::ConfirmWrites,
                &capabilities(DataModel::Relational, ReadOnlyEnforcement::LoginPrivileges),
                "SQL Server"
            ),
        );
    }

    #[test]
    fn a_login_the_engine_cannot_hold_to_reads_names_that_engine() {
        let cassandra = subtitle(
            SafeModeLevel::ReadOnly,
            &capabilities(DataModel::Relational, ReadOnlyEnforcement::LoginPrivileges),
            "Cassandra / ScyllaDB",
        );

        assert!(
            cassandra.contains("Cassandra / ScyllaDB cannot enforce this"),
            "{cassandra}"
        );
        assert!(!cassandra.contains("SQL Server"), "{cassandra}");
    }

    #[test]
    fn an_engine_of_documents_is_told_about_in_its_own_words() {
        let documents = capabilities(DataModel::Document, ReadOnlyEnforcement::ClientGuard);
        let keys = capabilities(DataModel::KeyValue, ReadOnlyEnforcement::ClientGuard);

        assert!(subtitle(SafeModeLevel::Off, &documents, "MongoDB").contains("collection"));
        assert!(!subtitle(SafeModeLevel::Off, &documents, "MongoDB").contains("WHERE"));
        let read_only = subtitle(SafeModeLevel::ReadOnly, &documents, "MongoDB");
        assert_ne!(read_only, subtitle(SafeModeLevel::ReadOnly, &keys, "Redis"));
        assert!(
            read_only.contains("before it is sent") && !read_only.contains("ACL"),
            "{read_only}"
        );
    }

    #[test]
    fn an_engine_of_keys_is_told_about_in_commands() {
        let keys = capabilities(DataModel::KeyValue, ReadOnlyEnforcement::ClientGuard);
        let tables = capabilities(DataModel::Relational, ReadOnlyEnforcement::ClientGuard);

        for level in [SafeModeLevel::Off, SafeModeLevel::ConfirmWrites] {
            assert_ne!(
                subtitle(level, &keys, "Redis"),
                subtitle(level, &tables, "Redis"),
                "{level:?}"
            );
            assert!(!subtitle(level, &keys, "Redis").contains("statement"), "{level:?}");
        }
        assert!(subtitle(SafeModeLevel::ReadOnly, &keys, "Redis").contains("before it is sent"));
    }
}
