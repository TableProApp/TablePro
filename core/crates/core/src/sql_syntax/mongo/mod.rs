//! MongoDB's shell language as the editor takes it, and as the app
//! writes the statements it generates for a collection's grid: the
//! JavaScript subset mongosh users type, `db.orders.find({qty: {$gt: 1}})`,
//! without running JavaScript. A statement is parsed into a call chain
//! whose values are JSON's plus the shell's helpers, such as `ObjectId()`
//! and `ISODate()`; the driver turns that into a server command.

mod credentials;
mod shell_access;
mod shell_helpers;
mod shell_lexer;
mod shell_parser;
mod shell_plan;
mod shell_print;
mod shell_statement;
mod shell_value;

pub use credentials::history_recording;
pub use shell_access::{access_of, may_change_catalog, script_access};
pub use shell_lexer::{ShellToken, ShellTokenKind, lex_shell};
pub(crate) use shell_lexer::{is_name_part, is_name_start};
pub use shell_parser::{ShellSyntaxError, parse_bound_statement, parse_statement, parse_value};
pub(crate) use shell_plan::plan;
pub use shell_plan::statement_ranges;
pub use shell_statement::{CallRoot, ShellCall, ShellMethod, ShellStatement, ShowTarget};
pub use shell_value::{ShellConstructor, ShellNumber, ShellValue};

/// Whether a field name can be written as a key of a filter, a sort or an
/// update: a name with a dot is a path to a nested field there, and one
/// that starts with `$` is an operator.
pub fn is_addressable_field(name: &str) -> bool {
    !name.is_empty() && !name.contains('.') && !name.starts_with('$')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_dotted_or_dollar_name_is_not_a_plain_key() {
        assert!(is_addressable_field("name"));
        assert!(is_addressable_field("_id"));
        assert!(!is_addressable_field("a.b"));
        assert!(!is_addressable_field("$price"));
        assert!(!is_addressable_field(""));
    }
}
