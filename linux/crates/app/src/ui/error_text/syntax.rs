use tablepro_core::dialect::LiteralError;
use tablepro_core::sql_syntax::mongo::ShellSyntaxError;
use tablepro_core::sql_syntax::{ExpressionSyntaxError, TypeSyntaxError};

use crate::i18n::{gettext, gettext_f, ngettext_f};

/// Why the Type field's text is refused, beside the field.
pub fn type_syntax_message(error: &TypeSyntaxError) -> String {
    match error {
        TypeSyntaxError::Empty => gettext("Enter a type."),
        TypeSyntaxError::TooLong { max } => too_long(*max),
        TypeSyntaxError::Comment => gettext("Remove the comment. It would hide the rest of the statement."),
        TypeSyntaxError::Invalid => gettext("This database does not read this as one type."),
        TypeSyntaxError::SessionDependentBackslash => backslash(),
    }
}

/// Why a default or an SQL filter is refused.
pub fn expression_syntax_message(error: &ExpressionSyntaxError) -> String {
    match error {
        ExpressionSyntaxError::Empty => gettext("Enter an expression."),
        ExpressionSyntaxError::TooLong { max } => too_long(*max),
        ExpressionSyntaxError::Comment => gettext("Remove the comment. It would hide the rest of the statement."),
        ExpressionSyntaxError::Invalid => gettext("This database does not read this as one expression."),
        ExpressionSyntaxError::SessionDependentBackslash => backslash(),
    }
}

/// Why MongoDB shell text is refused before anything is sent.
pub fn shell_syntax_message(error: &ShellSyntaxError) -> String {
    match error {
        ShellSyntaxError::Empty => gettext("Enter a document, such as { qty: { $gt: 1 } }."),
        ShellSyntaxError::Incomplete => {
            gettext("The text ends before it is complete. Check for a missing bracket or quote.")
        }
        ShellSyntaxError::Unexpected { found, .. } => {
            gettext_f("“{found}” is not expected there.", &[("found", found)])
        }
        ShellSyntaxError::UnknownRoot { .. } => gettext("Start with db, rs, show or use."),
        ShellSyntaxError::UnknownShow { .. } => gettext("Show dbs, collections, users or roles."),
        ShellSyntaxError::MissingDatabase { .. } => gettext("Name the database to use."),
        ShellSyntaxError::NoMethod { .. } => gettext("Call a method, such as find()."),
        ShellSyntaxError::UnknownHelper { name, .. } => {
            gettext_f("{name}() is not a value MongoDB stores.", &[("name", name)])
        }
        ShellSyntaxError::HelperArguments { helper, .. } => {
            gettext_f("{helper}() is given values it does not take.", &[("helper", helper)])
        }
        ShellSyntaxError::UnknownName { name, .. } => {
            gettext_f("“{name}” is not a value. Put text in quotes.", &[("name", name)])
        }
        ShellSyntaxError::RegexFlag { .. } => gettext("MongoDB takes only the i, m, s, u and x flags."),
        ShellSyntaxError::BadEscape { .. } => gettext("A backslash escape in a string does not read."),
        ShellSyntaxError::TemplateSubstitution { .. } => gettext("A template string cannot hold ${ }."),
        ShellSyntaxError::TooDeep { .. } => gettext("The values nest too deeply."),
        ShellSyntaxError::Parameter { .. } => gettext("$ and a number is not a value. Put text in quotes."),
    }
}

/// Why a value has no SQL spelling, for an engine without parameters.
pub fn literal_message(error: &LiteralError) -> String {
    match error {
        LiteralError::Unrepresentable { .. } => gettext("This database has no way to write this value in SQL."),
        LiteralError::Undecodable { .. } => {
            gettext("The value could not be read from the server, so it cannot be written back.")
        }
    }
}

fn too_long(max: usize) -> String {
    ngettext_f(
        "Use at most {max} character.",
        "Use at most {max} characters.",
        u32::try_from(max).unwrap_or(u32::MAX),
        &[("max", &max.to_string())],
    )
}

fn backslash() -> String {
    gettext("Remove the backslash. This database reads it differently from one session to another.")
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn each_type_refusal_says_its_own_thing_in_the_apps_words() {
        let errors = [
            TypeSyntaxError::Empty,
            TypeSyntaxError::TooLong { max: 512 },
            TypeSyntaxError::Comment,
            TypeSyntaxError::Invalid,
            TypeSyntaxError::SessionDependentBackslash,
        ];

        let messages: Vec<String> = errors.iter().map(type_syntax_message).collect();

        for (error, message) in errors.iter().zip(&messages) {
            assert_ne!(message, &error.to_string(), "{error:?} shows its log text");
        }
        assert_eq!(
            messages.iter().collect::<HashSet<_>>().len(),
            errors.len(),
            "{messages:?}"
        );
        assert_eq!(messages[1], "Use at most 512 characters.");
    }

    #[test]
    fn each_expression_refusal_says_its_own_thing_in_the_apps_words() {
        let errors = [
            ExpressionSyntaxError::Empty,
            ExpressionSyntaxError::TooLong { max: 4096 },
            ExpressionSyntaxError::Comment,
            ExpressionSyntaxError::Invalid,
            ExpressionSyntaxError::SessionDependentBackslash,
        ];

        let messages: Vec<String> = errors.iter().map(expression_syntax_message).collect();

        for (error, message) in errors.iter().zip(&messages) {
            assert_ne!(message, &error.to_string(), "{error:?} shows its log text");
        }
        assert_eq!(
            messages.iter().collect::<HashSet<_>>().len(),
            errors.len(),
            "{messages:?}"
        );
    }

    #[test]
    fn a_literal_refusal_leaves_out_the_value_type_and_the_reason() {
        let unrepresentable = literal_message(&LiteralError::Unrepresentable { found: "Bytes" });
        let undecodable = literal_message(&LiteralError::Undecodable {
            reason: "InvalidEncoding is not decodable here".to_owned(),
        });

        assert!(!unrepresentable.contains("Bytes"), "{unrepresentable}");
        assert!(!undecodable.contains("InvalidEncoding"), "{undecodable}");
        assert_ne!(unrepresentable, undecodable);
    }
}
