use crate::dialect::SqlDialect;
use crate::sql_syntax::{ExpressionSyntaxError, MAX_EXPRESSION_LEN, parse_expression};

/// Check that SQL the user typed as a filter is exactly one expression.
///
/// The text is spliced into the page query, so `1=1); DELETE FROM t;
/// SELECT (1` would close the WHERE and run a second statement, and a
/// comment would swallow the clauses after it. The engine's own grammar
/// has to read the whole text as one expression with nothing left over.
/// The filter strip checks before saving a fragment, and every builder
/// checks again, so a fragment saved before this check is refused when
/// it is replayed.
pub fn validate_raw_predicate(dialect: &dyn SqlDialect, text: &str) -> Result<(), ExpressionSyntaxError> {
    parse_expression(dialect.grammar(), text, MAX_EXPRESSION_LEN).map(|_| ())
}

#[cfg(test)]
mod tests {
    use crate::dialect::TestDialect;

    use super::*;

    fn validate(text: &str) -> Result<(), ExpressionSyntaxError> {
        validate_raw_predicate(&TestDialect::exact(), text)
    }

    #[test]
    fn a_predicate_that_closes_the_where_is_refused() {
        assert!(matches!(
            validate("1=1); DELETE FROM t; SELECT (1"),
            Err(ExpressionSyntaxError::Invalid(_))
        ));
    }

    #[test]
    fn a_trailing_semicolon_is_refused() {
        assert!(matches!(validate("a = 1;"), Err(ExpressionSyntaxError::Invalid(_))));
    }

    #[test]
    fn a_batch_separator_is_refused() {
        assert!(matches!(validate("1=1 GO"), Err(ExpressionSyntaxError::Invalid(_))));
    }

    #[test]
    fn a_comment_that_would_swallow_the_rest_is_refused() {
        assert_eq!(validate("a = 1 --"), Err(ExpressionSyntaxError::Comment));
    }

    #[test]
    fn a_plain_expression_passes() {
        assert_eq!(validate("a OR b"), Ok(()));
        assert_eq!(validate("length(name) > 3"), Ok(()));
    }
}
