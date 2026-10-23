use serde::{Deserialize, Serialize};

use crate::safe_mode_level::SafeModeLevel;
use crate::sql_syntax::StatementAccess;

/// What an MCP client may do on one connection.
///
/// It is persisted with the connection, so a variant is never renamed:
/// the stored spelling is the serde name. A connection saved before the
/// level existed reads as `ReadOnly`, the level a new one starts at.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExternalAccess {
    /// Not listed, and every call that names it is refused.
    Blocked,
    #[default]
    ReadOnly,
    /// Writes too, each one confirmed in the app.
    ReadWrite,
}

/// What happens to a statement an MCP client sends.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExternalGate {
    Run,
    /// The user answers in the app first, whatever the Safe Mode level:
    /// a client asking is not the user asking.
    Confirm {
        destructive: bool,
    },
    Refuse(ExternalRefusal),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ExternalRefusal {
    Blocked,
    /// The connection lets clients read only.
    ReadOnlyAccess,
    /// Safe Mode is Read-Only, which no client can get past.
    SafeModeReadOnly,
}

impl ExternalAccess {
    pub const ALL: [ExternalAccess; 3] = [Self::Blocked, Self::ReadOnly, Self::ReadWrite];

    pub fn is_blocked(self) -> bool {
        self == Self::Blocked
    }

    pub fn gate(self, safe_mode: SafeModeLevel, access: StatementAccess) -> ExternalGate {
        match (self, access) {
            (Self::Blocked, _) => ExternalGate::Refuse(ExternalRefusal::Blocked),
            (_, StatementAccess::Read) => ExternalGate::Run,
            (Self::ReadOnly, _) => ExternalGate::Refuse(ExternalRefusal::ReadOnlyAccess),
            (Self::ReadWrite, _) if safe_mode.blocks_writes() => {
                ExternalGate::Refuse(ExternalRefusal::SafeModeReadOnly)
            }
            (Self::ReadWrite, access) => ExternalGate::Confirm {
                destructive: access == StatementAccess::Destructive,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stored_spelling_is_snake_case() {
        let spelled: Vec<String> = ExternalAccess::ALL
            .into_iter()
            .filter_map(|access| serde_json::to_string(&access).ok())
            .collect();

        assert_eq!(spelled, ["\"blocked\"", "\"read_only\"", "\"read_write\""]);
        assert_eq!(ExternalAccess::default(), ExternalAccess::ReadOnly);
    }

    #[test]
    fn each_level_gates_each_kind_of_statement_under_each_safe_mode() {
        use ExternalGate::{Confirm, Refuse, Run};
        use ExternalRefusal::{Blocked, ReadOnlyAccess, SafeModeReadOnly};
        use StatementAccess::{Destructive, Read, Write};

        let write = Confirm { destructive: false };
        let drop = Confirm { destructive: true };
        let table = [
            (ExternalAccess::Blocked, SafeModeLevel::Off, [Refuse(Blocked); 3]),
            (
                ExternalAccess::ReadOnly,
                SafeModeLevel::Off,
                [Run, Refuse(ReadOnlyAccess), Refuse(ReadOnlyAccess)],
            ),
            (ExternalAccess::ReadWrite, SafeModeLevel::Off, [Run, write, drop]),
            (
                ExternalAccess::ReadWrite,
                SafeModeLevel::ConfirmWrites,
                [Run, write, drop],
            ),
            (
                ExternalAccess::ReadWrite,
                SafeModeLevel::ReadOnly,
                [Run, Refuse(SafeModeReadOnly), Refuse(SafeModeReadOnly)],
            ),
        ];
        for (access, level, expected) in table {
            let gates = [Read, Write, Destructive].map(|statement| access.gate(level, statement));
            assert_eq!(gates, expected, "{access:?} under {level:?}");
        }
    }
}
