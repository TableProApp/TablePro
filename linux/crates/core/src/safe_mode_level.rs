use serde::{Deserialize, Serialize};

use crate::sql_syntax::StatementAccess;

/// What stands between a statement and the server on one connection.
///
/// It is persisted with the connection, so a variant is never renamed:
/// the stored spelling is the serde name.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SafeModeLevel {
    #[default]
    Off,
    ConfirmWrites,
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
    pub const ALL: [SafeModeLevel; 3] = [Self::Off, Self::ConfirmWrites, Self::ReadOnly];

    /// Whether the connection opens read-only, so the server refuses a
    /// write the app did not recognize.
    pub fn blocks_writes(self) -> bool {
        self == Self::ReadOnly
    }

    pub fn gate(self, access: StatementAccess) -> WriteGate {
        match (self, access) {
            (_, StatementAccess::Read) => WriteGate::Run,
            (Self::ReadOnly, _) => WriteGate::Refuse,
            (Self::Off, StatementAccess::Write) => WriteGate::Run,
            (Self::Off | Self::ConfirmWrites, _) => WriteGate::Confirm,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stored_spelling_is_snake_case() {
        assert_eq!(
            serde_json::to_string(&SafeModeLevel::ConfirmWrites).ok().as_deref(),
            Some("\"confirm_writes\"")
        );
        assert_eq!(
            serde_json::from_str::<SafeModeLevel>("\"read_only\"").ok(),
            Some(SafeModeLevel::ReadOnly)
        );
        assert_eq!(
            serde_json::from_str::<SafeModeLevel>("\"off\"").ok(),
            Some(SafeModeLevel::Off)
        );
    }

    #[test]
    fn each_level_gates_each_kind_of_statement() {
        use StatementAccess::{Destructive, Read, Write};
        use WriteGate::{Confirm, Refuse, Run};

        let table = [
            (SafeModeLevel::Off, [Run, Run, Confirm]),
            (SafeModeLevel::ConfirmWrites, [Run, Confirm, Confirm]),
            (SafeModeLevel::ReadOnly, [Run, Refuse, Refuse]),
        ];
        for (level, expected) in table {
            let gates = [Read, Write, Destructive].map(|access| level.gate(access));
            assert_eq!(gates, expected, "{level:?}");
        }
    }

    #[test]
    fn only_read_only_opens_the_connection_read_only() {
        assert!(SafeModeLevel::ReadOnly.blocks_writes());
        assert!(!SafeModeLevel::ConfirmWrites.blocks_writes());
        assert!(!SafeModeLevel::Off.blocks_writes());
    }
}
