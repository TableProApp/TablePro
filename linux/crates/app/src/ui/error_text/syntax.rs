use tablepro_core::dialect::LiteralError;
use tablepro_core::sql_syntax::{ExpressionSyntaxError, TypeSyntaxError};

use crate::i18n::{gettext, ngettext_f};

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
