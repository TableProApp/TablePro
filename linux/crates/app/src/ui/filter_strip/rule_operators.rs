use std::sync::Arc;

use tablepro_core::dialect::SqlDialect;
use tablepro_core::{ColumnInfo, Combinator, FilterOp, FilterValue};

/// An operator as the operator dropdown shows it.
pub(super) struct OpEntry {
    pub(super) op: FilterOp,
    pub(super) label: &'static str,
    pub(super) shape: ValueShape,
}

/// What a rule compares against, which decides the value editor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ValueShape {
    None,
    Single,
    Pair,
    List,
}

impl ValueShape {
    /// The blank value a rule takes when its operator changes to one of
    /// this shape.
    pub(super) fn empty_value(self) -> Option<FilterValue> {
        match self {
            Self::None => None,
            Self::Single => Some(FilterValue::Single(String::new())),
            Self::Pair => Some(FilterValue::Pair(String::new(), String::new())),
            Self::List => Some(FilterValue::List(Vec::new())),
        }
    }
}

/// What the connection's engine evaluates in a filter: the operators
/// for each column and whether rules can match any rather than all.
/// Without a connection, every operator the column's kind takes.
#[derive(Clone, Default)]
pub(crate) struct FilterVocabulary {
    dialect: Option<Arc<dyn SqlDialect>>,
}

impl FilterVocabulary {
    pub(crate) fn of(dialect: Option<Arc<dyn SqlDialect>>) -> Self {
        Self { dialect }
    }

    pub(super) fn operators(&self, column: &ColumnInfo) -> &'static [FilterOp] {
        match &self.dialect {
            Some(dialect) => dialect.filter_operators(column),
            None => tablepro_core::operators_for(&column.column_type.kind),
        }
    }

    pub(super) fn matches_any(&self) -> bool {
        self.dialect
            .as_ref()
            .is_none_or(|dialect| dialect.filter_combinators().contains(&Combinator::Or))
    }
}

/// The operators this column allows, with the label and value shape
/// the dropdown needs for each.
///
/// The set itself comes from the dialect the builder writes with, so
/// what the strip offers and what the builder accepts cannot drift
/// apart: an operator the user can pick is one the filter can be built
/// from.
pub(super) fn operators_for(column: &ColumnInfo, vocabulary: &FilterVocabulary) -> Vec<OpEntry> {
    vocabulary
        .operators(column)
        .iter()
        .map(|op| OpEntry {
            op: *op,
            label: label_for(*op),
            shape: shape_for(*op),
        })
        .collect()
}

fn label_for(op: FilterOp) -> &'static str {
    match op {
        FilterOp::Eq => "equals",
        FilterOp::NotEq => "doesn't equal",
        FilterOp::Lt => "less than",
        FilterOp::LtEq => "at most",
        FilterOp::Gt => "greater than",
        FilterOp::GtEq => "at least",
        FilterOp::Contains => "contains",
        FilterOp::StartsWith => "starts with",
        FilterOp::EndsWith => "ends with",
        FilterOp::Like => "matches pattern",
        FilterOp::NotLike => "doesn't match pattern",
        FilterOp::Ilike => "matches, ignoring case",
        FilterOp::IsNull => "is empty",
        FilterOp::IsNotNull => "is not empty",
        FilterOp::In => "is one of",
        FilterOp::NotIn => "is none of",
        FilterOp::Between => "between",
    }
}

fn shape_for(op: FilterOp) -> ValueShape {
    match op {
        FilterOp::IsNull | FilterOp::IsNotNull => ValueShape::None,
        FilterOp::In | FilterOp::NotIn => ValueShape::List,
        FilterOp::Between => ValueShape::Pair,
        _ => ValueShape::Single,
    }
}

/// A column the strip can fall back on when the schema has not
/// loaded, so a saved rule still renders with its own name.
pub(super) fn placeholder_column(name: &str) -> ColumnInfo {
    ColumnInfo {
        name: name.to_owned(),
        column_type: tablepro_core::column::ColumnType::unknown(),
        nullable: true,
        primary_key: false,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: tablepro_core::column::ColumnDefault::None,
        comment: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_shape_starts_blank() {
        assert_eq!(ValueShape::None.empty_value(), None);
        assert_eq!(
            ValueShape::Single.empty_value(),
            Some(FilterValue::Single(String::new()))
        );
        assert_eq!(
            ValueShape::Pair.empty_value(),
            Some(FilterValue::Pair(String::new(), String::new()))
        );
        assert_eq!(ValueShape::List.empty_value(), Some(FilterValue::List(Vec::new())));
    }

    #[test]
    fn the_null_tests_take_no_value_and_between_takes_two() {
        assert_eq!(shape_for(FilterOp::IsNull), ValueShape::None);
        assert_eq!(shape_for(FilterOp::Between), ValueShape::Pair);
        assert_eq!(shape_for(FilterOp::In), ValueShape::List);
        assert_eq!(shape_for(FilterOp::Eq), ValueShape::Single);
    }
}
