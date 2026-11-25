use serde::{Deserialize, Serialize};

use crate::sql_syntax::StatementAccess;

/// What stands between a statement and the server on one connection: the macOS levels.
///
/// It is persisted with the connection, so a variant is never renamed: the stored spelling is the
/// serde name. The three levels every app had first keep the names a build before the six levels
/// wrote and reads.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SafeModeLevel {
    #[default]
    #[serde(rename = "off", alias = "silent")]
    Silent,
    #[serde(rename = "confirm_writes", alias = "alert")]
    Alert,
    // Every statement asks, reads included.
    #[serde(rename = "alert_full")]
    AlertFull,
    // A write asks, and the person proves who they are.
    #[serde(rename = "safe_mode")]
    SafeMode,
    #[serde(rename = "safe_mode_full")]
    SafeModeFull,
    #[serde(rename = "read_only")]
    ReadOnly,
}

/// What happens to a statement before it is sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WriteGate {
    Run,
    Confirm,
    Refuse,
}

impl SafeModeLevel {
    // Weakest first, as the macOS app orders them by what each one stops.
    pub const ALL: [SafeModeLevel; 6] = [
        Self::Silent,
        Self::Alert,
        Self::AlertFull,
        Self::SafeMode,
        Self::SafeModeFull,
        Self::ReadOnly,
    ];

    // What a session here runs: no app on the core asks before a read or for the person's proof yet.
    pub const ENFORCED: [SafeModeLevel; 3] = [Self::Silent, Self::Alert, Self::ReadOnly];

    pub fn strictness(self) -> usize {
        Self::ALL
            .iter()
            .position(|level| *level == self)
            .unwrap_or(Self::ALL.len())
    }

    /// The level a session runs, rounded up to one in [`Self::ENFORCED`] and never down.
    pub fn enforced(self) -> Self {
        self.at_least_in(&Self::ENFORCED)
    }

    /// The weakest of `offered` that stops at least what this level stops; Read-Only when none does.
    pub fn at_least_in(self, offered: &[Self]) -> Self {
        offered
            .iter()
            .copied()
            .filter(|level| level.strictness() >= self.strictness())
            .min_by_key(|level| level.strictness())
            .unwrap_or(Self::ReadOnly)
    }

    // A form that offers only the enforced levels shows a stored one as the level it runs, and sending that back keeps it.
    pub fn edited(stored: Self, picked: Self) -> Self {
        if picked == stored.enforced() { stored } else { picked }
    }

    pub fn confirms_reads(self) -> bool {
        matches!(self, Self::AlertFull | Self::SafeModeFull)
    }

    pub fn asks_for_proof(self) -> bool {
        matches!(self, Self::SafeMode | Self::SafeModeFull)
    }

    /// Whether the connection opens read-only, so the server refuses a
    /// write the app did not recognize.
    pub fn blocks_writes(self) -> bool {
        self == Self::ReadOnly
    }

    // Asking for proof is the app's, on top of the confirmation.
    pub fn gate(self, access: StatementAccess) -> WriteGate {
        match (self, access) {
            (Self::AlertFull | Self::SafeModeFull, _) => WriteGate::Confirm,
            (_, StatementAccess::Read) => WriteGate::Run,
            (Self::ReadOnly, _) => WriteGate::Refuse,
            (Self::Silent, StatementAccess::Write) => WriteGate::Run,
            (Self::Silent | Self::Alert | Self::SafeMode, _) => WriteGate::Confirm,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_three_keep_their_stored_spelling() {
        let spelled: Vec<String> = SafeModeLevel::ALL
            .into_iter()
            .filter_map(|level| serde_json::to_string(&level).ok())
            .collect();

        assert_eq!(
            spelled,
            [
                "\"off\"",
                "\"confirm_writes\"",
                "\"alert_full\"",
                "\"safe_mode\"",
                "\"safe_mode_full\"",
                "\"read_only\""
            ]
        );
        for (spelling, level) in [
            ("\"silent\"", SafeModeLevel::Silent),
            ("\"alert\"", SafeModeLevel::Alert),
            ("\"off\"", SafeModeLevel::Silent),
        ] {
            assert_eq!(serde_json::from_str::<SafeModeLevel>(spelling).ok(), Some(level));
        }
    }

    #[test]
    fn each_level_gates_each_kind_of_statement() {
        use StatementAccess::{Destructive, Read, Write};
        use WriteGate::{Confirm, Refuse, Run};

        let table = [
            (SafeModeLevel::Silent, [Run, Run, Confirm]),
            (SafeModeLevel::Alert, [Run, Confirm, Confirm]),
            (SafeModeLevel::AlertFull, [Confirm, Confirm, Confirm]),
            (SafeModeLevel::SafeMode, [Run, Confirm, Confirm]),
            (SafeModeLevel::SafeModeFull, [Confirm, Confirm, Confirm]),
            (SafeModeLevel::ReadOnly, [Run, Refuse, Refuse]),
        ];
        for (level, expected) in table {
            let gates = [Read, Write, Destructive].map(|access| level.gate(access));
            assert_eq!(gates, expected, "{level:?}");
        }
    }

    #[test]
    fn a_level_rounds_up_to_one_a_session_enforces_and_never_down() {
        let enforced = SafeModeLevel::ALL.map(SafeModeLevel::enforced);

        assert_eq!(
            enforced,
            [
                SafeModeLevel::Silent,
                SafeModeLevel::Alert,
                SafeModeLevel::ReadOnly,
                SafeModeLevel::ReadOnly,
                SafeModeLevel::ReadOnly,
                SafeModeLevel::ReadOnly,
            ]
        );
        for level in SafeModeLevel::ALL {
            assert!(level.enforced().strictness() >= level.strictness(), "{level:?}");
        }
        assert_eq!(
            SafeModeLevel::SafeMode.at_least_in(&[SafeModeLevel::Silent]),
            SafeModeLevel::ReadOnly
        );
    }

    #[test]
    fn a_form_that_shows_the_enforced_level_keeps_the_stored_one() {
        assert_eq!(
            SafeModeLevel::edited(SafeModeLevel::AlertFull, SafeModeLevel::ReadOnly),
            SafeModeLevel::AlertFull
        );
        assert_eq!(
            SafeModeLevel::edited(SafeModeLevel::AlertFull, SafeModeLevel::Alert),
            SafeModeLevel::Alert
        );
        assert_eq!(
            SafeModeLevel::edited(SafeModeLevel::Silent, SafeModeLevel::ReadOnly),
            SafeModeLevel::ReadOnly
        );
    }

    #[test]
    fn only_read_only_opens_the_connection_read_only() {
        for level in SafeModeLevel::ALL {
            assert_eq!(level.blocks_writes(), level == SafeModeLevel::ReadOnly, "{level:?}");
        }
        assert!(SafeModeLevel::SafeModeFull.confirms_reads() && SafeModeLevel::SafeModeFull.asks_for_proof());
        assert!(!SafeModeLevel::Alert.confirms_reads() && !SafeModeLevel::Alert.asks_for_proof());
    }
}
