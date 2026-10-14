use tablepro_core::{ColumnInfo, FilterOp, FilterValue};

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

/// The operators this column allows, with the label and value shape
/// the dropdown needs for each.
///
/// The set itself comes from core, so what the strip offers and what
/// the builder accepts cannot drift apart: an operator the user can
/// pick is one the filter can be built from.
pub(super) fn operators_for(column: &ColumnInfo) -> Vec<OpEntry> {
    tablepro_core::operators_for(&column.column_type.kind)
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

/// A column the user can filter on at all.
///
/// A blob is left out of the dropdown: nothing they could type would
/// compare against one, so offering it would only lead to a filter
/// that never matches.
pub(super) fn is_filterable(column: &ColumnInfo) -> bool {
    !matches!(column.column_type.kind, tablepro_core::column::ColumnKind::Bytes { .. })
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
    fn a_blob_is_not_filterable() {
        let mut blob = placeholder_column("payload");
        blob.column_type.kind = tablepro_core::column::ColumnKind::Bytes {
            length: tablepro_core::column::TextLength::Unbounded,
        };

        assert!(!is_filterable(&blob));
        assert!(is_filterable(&placeholder_column("name")));
    }

    #[test]
    fn the_null_tests_take_no_value_and_between_takes_two() {
        assert_eq!(shape_for(FilterOp::IsNull), ValueShape::None);
        assert_eq!(shape_for(FilterOp::Between), ValueShape::Pair);
        assert_eq!(shape_for(FilterOp::In), ValueShape::List);
        assert_eq!(shape_for(FilterOp::Eq), ValueShape::Single);
    }
}
