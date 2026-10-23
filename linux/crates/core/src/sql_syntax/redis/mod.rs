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
