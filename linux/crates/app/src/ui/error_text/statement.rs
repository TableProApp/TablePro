//! Why a row change, a filter or a page could not be written as SQL.
//! The variants carry the dialect's own names for types and values,
//! which are for the log, so none of them reaches the sentence.

use tablepro_core::BuildFilterError;
use tablepro_core::browse::BrowseSqlError;
use tablepro_core::dialect::BindError;
use tablepro_core::dml::BuildSqlError;

use super::edit::edit_parse_message;
use super::syntax::expression_syntax_message;
use crate::i18n::{gettext, gettext_f};

/// Why a value could not be sent, as the part after "cannot be saved:"
/// or "cannot be applied:".
pub(super) fn bind_reason(error: &BindError) -> String {
    match error {
        BindError::ValueTypeMismatch { .. } => gettext("a value does not match its column's type"),
        BindError::MissingCatalogType { column } => gettext_f(
            "the database did not report the type of column {column}",
            &[("column", column)],
        ),
        BindError::Undecodable { .. } => {
            gettext("a value could not be read from the server, so it cannot be written back")
        }
        BindError::Unrepresentable { .. } => gettext("this database cannot take one of the values"),
    }
}

/// Why the tab's filter cannot be written, as a whole sentence.
pub(super) fn filter_message(error: &BuildFilterError) -> String {
    let refused = |reason: String| gettext_f("This filter cannot be applied: {reason}", &[("reason", &reason)]);
    match error {
        BuildFilterError::UnknownColumn(column) => refused(gettext_f(
            "it names column {column}, which the table does not have",
            &[("column", column)],
        )),
        BuildFilterError::MissingValue(_) => refused(gettext("a rule has no value")),
        BuildFilterError::BetweenMissingBound => refused(gettext("a between rule needs both of its values")),
        BuildFilterError::EmptyInList => refused(gettext("a one-of rule needs at least one value")),
        BuildFilterError::WrongValueShape { .. } => refused(gettext("a rule's value does not fit its operator")),
        BuildFilterError::Parse { column, source } => gettext_f(
            "This filter cannot be applied. Value for {column}: {reason}",
            &[("column", column), ("reason", &edit_parse_message(source))],
        ),
        BuildFilterError::Bind(bind) => refused(bind_reason(bind)),
        BuildFilterError::OperatorNotAllowed { column, .. } => refused(gettext_f(
            "column {column} does not allow one of its operators",
            &[("column", column)],
        )),
        BuildFilterError::CombinatorNotAllowed(_) => {
            refused(gettext("this database can only require every rule to match"))
        }
        BuildFilterError::RawPredicate(syntax) => gettext_f(
            "This SQL filter cannot be applied. {reason}",
            &[("reason", &expression_syntax_message(syntax))],
        ),
    }
}

/// Why a page of the table could not be read, as the part after
/// "cannot be read:".
pub(super) fn browse_reason(error: &BrowseSqlError) -> String {
    match error {
        BrowseSqlError::NoColumns => gettext("the table has no columns to select"),
        BrowseSqlError::UnknownSortColumn(_) => gettext("the sort names a column the table does not have"),
        BrowseSqlError::UnsupportedPosition { .. } => gettext("this position cannot be reached by this way of paging"),
        BrowseSqlError::SortUnsupported => gettext("this database reads a table only in its own order"),
        BrowseSqlError::StalePagingState => {
            gettext("the way to this page belongs to another query; go back to the first page")
        }
        BrowseSqlError::NullAnchor => gettext("the row to page from has an empty key"),
        BrowseSqlError::UnreadableAnchor => gettext("the row to page from has no address that can be read"),
        BrowseSqlError::ShapeMismatch { .. } => gettext("the page came back with other columns than were asked for"),
        BrowseSqlError::Bind(bind) => bind_reason(bind),
        BrowseSqlError::Filter(_) | BrowseSqlError::Build(_) => gettext("the query could not be built"),
    }
}

/// Why a row change could not be written, as the part after "cannot be
/// saved:".
pub(super) fn build_reason(error: &BuildSqlError) -> String {
    match error {
        BuildSqlError::UnknownKeyColumn { name } => gettext_f(
            "the row key names column {column}, which the table does not have",
            &[("column", name)],
        ),
        BuildSqlError::LengthMismatch { .. } => gettext("the row key does not have one value for each key column"),
        BuildSqlError::Bind(bind) => bind_reason(bind),
        BuildSqlError::NoRowIdentity
        | BuildSqlError::ReadOnlyRows
        | BuildSqlError::NothingToUpdate
        | BuildSqlError::NoInsertValues
        | BuildSqlError::UndecodableKey => gettext("the change could not be written as SQL"),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::FilterOp;
    use tablepro_core::edit::EditParseError;
    use tablepro_core::sql_syntax::ExpressionSyntaxError;

    use super::*;

    #[test]
    fn a_bind_refusal_leaves_out_the_dialects_type_names() {
        let mismatch = bind_reason(&BindError::ValueTypeMismatch {
            expected: "Uuid",
            found: "Text",
        });
        let unrepresentable = bind_reason(&BindError::Unrepresentable {
            expected: "a SQLite rowid",
            found: "another engine's row address",
        });

        assert!(!mismatch.contains("Uuid") && !mismatch.contains("Text"), "{mismatch}");
        assert!(!unrepresentable.contains("rowid"), "{unrepresentable}");
    }

    #[test]
    fn a_filter_value_the_column_cannot_take_says_which_column_and_why() {
        let message = filter_message(&BuildFilterError::Parse {
            column: "price".to_owned(),
            source: EditParseError::InvalidFloat,
        });

        assert_eq!(
            message,
            "This filter cannot be applied. Value for price: Enter a number"
        );
    }

    #[test]
    fn an_sql_filter_refusal_is_the_apps_sentence() {
        let message = filter_message(&BuildFilterError::RawPredicate(ExpressionSyntaxError::Invalid));

        assert_eq!(
            message,
            "This SQL filter cannot be applied. This database does not read this as one expression."
        );
    }

    #[test]
    fn every_filter_refusal_has_its_own_sentence() {
        let errors = [
            BuildFilterError::UnknownColumn("gone".to_owned()),
            BuildFilterError::MissingValue(FilterOp::Eq),
            BuildFilterError::BetweenMissingBound,
            BuildFilterError::EmptyInList,
            BuildFilterError::WrongValueShape { op: FilterOp::In },
            BuildFilterError::Parse {
                column: "id".to_owned(),
                source: EditParseError::InvalidInteger,
            },
            BuildFilterError::Bind(BindError::MissingCatalogType {
                column: "id".to_owned(),
            }),
            BuildFilterError::OperatorNotAllowed {
                column: "id".to_owned(),
                op: FilterOp::Like,
            },
            BuildFilterError::RawPredicate(ExpressionSyntaxError::Comment),
            BuildFilterError::CombinatorNotAllowed(tablepro_core::Combinator::Or),
        ];

        let messages: std::collections::HashSet<String> = errors.iter().map(filter_message).collect();

        assert_eq!(messages.len(), errors.len(), "{messages:?}");
        for error in &errors {
            assert!(!messages.contains(&error.to_string()), "{error:?} shows its log text");
        }
    }
}
