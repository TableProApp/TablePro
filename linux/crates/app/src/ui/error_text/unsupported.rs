use tablepro_core::UnsupportedFeature;

use crate::i18n::{gettext, gettext_f};

/// What the engine cannot do. Every feature has its own branch, so a
/// new one fails to compile here rather than reaching the user in
/// English.
pub(super) fn unsupported_message(feature: UnsupportedFeature) -> String {
    match feature {
        UnsupportedFeature::DatabaseFile => {
            gettext("This database is reached over the network. It cannot open a database file.")
        }
        UnsupportedFeature::NetworkConnection => {
            gettext("This database opens a file. It cannot connect to a server over the network.")
        }
        UnsupportedFeature::ForeignKeySuspension => {
            gettext("This database cannot turn foreign key checks off for a save.")
        }
        UnsupportedFeature::MinimumVersion { required } => {
            gettext_f("This needs {version} or later.", &[("version", required)])
        }
        UnsupportedFeature::CopyFromStdinInEditor => gettext("COPY FROM STDIN cannot run in the editor."),
        UnsupportedFeature::CopyToStdoutInEditor => gettext("COPY TO STDOUT cannot run in the editor."),
        UnsupportedFeature::TimestampInRepeatedHour => gettext(
            "This time falls in the hour the session's time zone repeats, so the database cannot store it as one instant.",
        ),
        UnsupportedFeature::TimeOutsideOneDay => gettext("This database has no times outside one day."),
        UnsupportedFeature::TimeWithOffset => gettext("This database has no times with an offset."),
        UnsupportedFeature::Interval => gettext("This database has no intervals."),
        UnsupportedFeature::BitString => gettext("This database has no bit strings."),
        UnsupportedFeature::NumberWiderThan { digits } => gettext_f(
            "This database has no numbers wider than {digits} digits.",
            &[("digits", &digits.to_string())],
        ),
        UnsupportedFeature::DecimalOutOfRange { digits } => gettext_f(
            "This database has no NaN, no infinity and no decimals wider than {digits} digits.",
            &[("digits", &digits.to_string())],
        ),
        UnsupportedFeature::DateOutsideYears { first, last } => gettext_f(
            "This database has no dates outside the years {first} to {last}.",
            &[("first", &first.to_string()), ("last", &last.to_string())],
        ),
        UnsupportedFeature::HiddenAttach => {
            gettext("The editor cannot attach a HIDDEN database, which no other window could see is open.")
        }
        UnsupportedFeature::ServerPaging => gettext("This database does not page tables on the server."),
        UnsupportedFeature::Tables => gettext("This database holds keys, not tables."),
        UnsupportedFeature::Keys => gettext("This database holds tables, not keys."),
        UnsupportedFeature::CharacterSets => gettext("This database has no character sets to pick from."),
        UnsupportedFeature::DatabaseSwitching => gettext("This connection cannot switch to another database."),
        UnsupportedFeature::ObjectDefinitions => gettext("This database cannot show the object's definition."),
        UnsupportedFeature::EditorCommand { command } => gettext_f(
            "{command} cannot run in the editor: it turns the connection into a stream the editor cannot show.",
            &[("command", command)],
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn every_feature_has_its_own_sentence() {
        let features = [
            UnsupportedFeature::DatabaseFile,
            UnsupportedFeature::NetworkConnection,
            UnsupportedFeature::ForeignKeySuspension,
            UnsupportedFeature::MinimumVersion {
                required: "SQLite 3.37.0",
            },
            UnsupportedFeature::CopyFromStdinInEditor,
            UnsupportedFeature::CopyToStdoutInEditor,
            UnsupportedFeature::TimestampInRepeatedHour,
            UnsupportedFeature::TimeOutsideOneDay,
            UnsupportedFeature::TimeWithOffset,
            UnsupportedFeature::Interval,
            UnsupportedFeature::BitString,
            UnsupportedFeature::NumberWiderThan { digits: 38 },
            UnsupportedFeature::DecimalOutOfRange { digits: 38 },
            UnsupportedFeature::DateOutsideYears { first: 1, last: 9999 },
            UnsupportedFeature::HiddenAttach,
            UnsupportedFeature::ServerPaging,
            UnsupportedFeature::Tables,
            UnsupportedFeature::Keys,
            UnsupportedFeature::CharacterSets,
            UnsupportedFeature::DatabaseSwitching,
            UnsupportedFeature::ObjectDefinitions,
            UnsupportedFeature::EditorCommand { command: "MONITOR" },
        ];

        let messages: Vec<String> = features.iter().map(|feature| unsupported_message(*feature)).collect();

        assert_eq!(
            messages.iter().collect::<HashSet<_>>().len(),
            features.len(),
            "{messages:?}"
        );
        assert_eq!(messages[3], "This needs SQLite 3.37.0 or later.");
        assert_eq!(messages[13], "This database has no dates outside the years 1 to 9999.");
    }
}
