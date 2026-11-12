use thiserror::Error;

use crate::dialect::BindError;
use crate::edit::EditParseError;
use crate::sql_syntax::ExpressionSyntaxError;
use crate::sql_syntax::mongo::ShellSyntaxError;

use super::{Combinator, FilterOp};

/// Why a filter could not be written as SQL.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum BuildFilterError {
    #[error("filter rule references unknown column: {0}")]
    UnknownColumn(String),
    #[error("operator {0:?} requires a value")]
    MissingValue(FilterOp),
    #[error("BETWEEN requires both bounds")]
    BetweenMissingBound,
    #[error("IN list cannot be empty")]
    EmptyInList,
    #[error("operator {op:?} cannot use the supplied value shape")]
    WrongValueShape { op: FilterOp },
    #[error("rule on column {column}: {source}")]
    Parse {
        column: String,
        #[source]
        source: EditParseError,
    },
    #[error(transparent)]
    Bind(#[from] BindError),
    #[error("operator {op:?} does not apply to column {column}")]
    OperatorNotAllowed { column: String, op: FilterOp },
    #[error("this engine cannot join filter rules with {0:?}")]
    CombinatorNotAllowed(Combinator),
    #[error("the SQL filter is not a single expression: {0}")]
    RawPredicate(#[source] ExpressionSyntaxError),
    #[error("the filter does not read as a document: {0}")]
    RawDocument(#[source] ShellSyntaxError),
    #[error("the filter is not a document")]
    RawNotDocument,
    #[error("field {0} has a dot in its name or starts with $, so a filter cannot name it")]
    UnaddressableField(String),
}

impl BuildFilterError {
    // Stable across releases, for an app outside Rust that words the error itself.
    pub fn code(&self) -> &'static str {
        match self {
            Self::UnknownColumn(_) => "filter.unknown_column",
            Self::MissingValue(_) => "filter.missing_value",
            Self::BetweenMissingBound => "filter.between_missing_bound",
            Self::EmptyInList => "filter.empty_in_list",
            Self::WrongValueShape { .. } => "filter.wrong_value_shape",
            Self::Parse { .. } => "filter.parse",
            Self::Bind(_) => "filter.bind",
            Self::OperatorNotAllowed { .. } => "filter.operator_not_allowed",
            Self::CombinatorNotAllowed(_) => "filter.combinator_not_allowed",
            Self::RawPredicate(_) => "filter.raw_predicate",
            Self::RawDocument(_) => "filter.raw_document",
            Self::RawNotDocument => "filter.raw_not_document",
            Self::UnaddressableField(_) => "filter.unaddressable_field",
        }
    }

    // Outermost first: a value the column cannot take adds the parse error's own code.
    pub fn codes(&self) -> Vec<&'static str> {
        match self {
            Self::Parse { source, .. } => vec![self.code(), source.code()],
            _ => vec![self.code()],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit::EditParseError;

    #[test]
    fn a_value_the_column_cannot_take_names_the_parse_error_too() {
        let error = BuildFilterError::Parse {
            column: "id".to_owned(),
            source: EditParseError::InvalidInteger,
        };

        assert_eq!(error.codes(), ["filter.parse", "edit.invalid_integer"]);
    }

    #[test]
    fn each_code_is_under_filter() {
        let errors = [
            BuildFilterError::UnknownColumn("x".to_owned()),
            BuildFilterError::MissingValue(FilterOp::Eq),
            BuildFilterError::BetweenMissingBound,
            BuildFilterError::EmptyInList,
            BuildFilterError::WrongValueShape { op: FilterOp::In },
            BuildFilterError::OperatorNotAllowed {
                column: "x".to_owned(),
                op: FilterOp::Ilike,
            },
            BuildFilterError::CombinatorNotAllowed(Combinator::Or),
            BuildFilterError::RawNotDocument,
            BuildFilterError::UnaddressableField("a.b".to_owned()),
        ];

        for error in errors {
            assert!(error.code().starts_with("filter."), "{}", error.code());
        }
    }
}
