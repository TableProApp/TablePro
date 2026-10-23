//! Redis commands as the editor takes them. Redis has no SQL: a script is
//! one command per line, each read as redis-cli reads a line, and what a
//! command can do comes from its name and options, not from a parse.

mod command_class;
mod command_lexer;
mod command_plan;
mod credentials;

pub use command_class::{EditorUse, command_access, editor_use};
pub use command_lexer::{ArgumentForm, CommandSyntaxError, LexedArgument, LexedCommand, split_command, split_commands};
pub(crate) use command_plan::plan;
pub use credentials::history_recording;

use crate::sql_syntax::StatementAccess;

/// Whether running `text` can add, remove or rename a key, and so
/// change what a listing of the keys holds: a command that writes, and
/// `EXEC`, which runs what a `MULTI` queued and reads as nothing itself.
pub fn may_change_keys(text: &str) -> bool {
    split_commands(text).iter().any(|command| match &command.values {
        Ok(arguments) => {
            command_access(arguments) >= StatementAccess::Write
                || arguments.first().is_some_and(|name| name.eq_ignore_ascii_case(b"EXEC"))
        }
        Err(_) => true,
    })
}

/// The strictest access of the commands in `text`. A command whose quotes
/// do not balance is a write, since what it would send is a guess.
pub fn script_access(text: &str) -> StatementAccess {
    split_commands(text)
        .iter()
        .map(|command| match &command.values {
            Ok(arguments) => command_access(arguments),
            Err(_) => StatementAccess::Write,
        })
        .max()
        .unwrap_or(StatementAccess::Read)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_write_or_an_exec_may_change_the_keys() {
        for text in ["SET k 1", "GET a\nDEL k", "exec", "MULTI\nEXEC", "SET k \"open"] {
            assert!(may_change_keys(text), "{text}");
        }
        for text in ["GET k", "MULTI", "SCAN 0 MATCH user:*", ""] {
            assert!(!may_change_keys(text), "{text}");
        }
    }

    #[test]
    fn a_script_is_as_strict_as_its_strictest_command() {
        assert_eq!(script_access("GET a\nSET b 1"), StatementAccess::Write);
        assert_eq!(script_access("GET a\nFLUSHDB"), StatementAccess::Destructive);
        assert_eq!(script_access("GET a"), StatementAccess::Read);
        assert_eq!(script_access("GET \"open"), StatementAccess::Write);
    }
}
