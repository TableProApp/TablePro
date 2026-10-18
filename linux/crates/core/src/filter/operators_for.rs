use crate::column::ColumnKind;

use super::FilterOp;

const NULL_ONLY: &[FilterOp] = &[FilterOp::IsNull, FilterOp::IsNotNull];
const COMPARISON: &[FilterOp] = &[
    FilterOp::Eq,
    FilterOp::NotEq,
    FilterOp::Lt,
    FilterOp::LtEq,
    FilterOp::Gt,
    FilterOp::GtEq,
    FilterOp::Between,
    FilterOp::In,
    FilterOp::NotIn,
    FilterOp::IsNull,
    FilterOp::IsNotNull,
];
const TEXTUAL: &[FilterOp] = &[
    FilterOp::Eq,
    FilterOp::NotEq,
    FilterOp::Contains,
    FilterOp::StartsWith,
    FilterOp::EndsWith,
    FilterOp::Like,
    FilterOp::NotLike,
    FilterOp::Ilike,
    FilterOp::In,
    FilterOp::NotIn,
    FilterOp::IsNull,
    FilterOp::IsNotNull,
];
const EQUALITY: &[FilterOp] = &[
    FilterOp::Eq,
    FilterOp::NotEq,
    FilterOp::In,
    FilterOp::NotIn,
    FilterOp::IsNull,
    FilterOp::IsNotNull,
];

/// Which operators make sense for a column, in the order the dropdown
/// lists them.
///
/// Driven by the column's kind rather than its type name, so a new
/// engine spelling never needs a new branch here. A binary column gets
/// only the null tests: there is no text form of a blob to compare.
pub fn operators_for(kind: &ColumnKind) -> &'static [FilterOp] {
    match kind {
        ColumnKind::Bytes { .. }
        | ColumnKind::Spatial
        | ColumnKind::Array { .. }
        | ColumnKind::Variant
        | ColumnKind::Composite => NULL_ONLY,
        ColumnKind::Text { .. }
        | ColumnKind::Json { .. }
        | ColumnKind::Enum { .. }
        | ColumnKind::Xml
        | ColumnKind::Other => TEXTUAL,
        // An interval is ordered, so it compares rather than matching
        // as text.
        ColumnKind::Integer(_)
        | ColumnKind::Decimal { .. }
        | ColumnKind::Money { .. }
        | ColumnKind::Float(_)
        | ColumnKind::Date
        | ColumnKind::Time { .. }
        | ColumnKind::Timestamp { .. }
        | ColumnKind::Interval => COMPARISON,
        ColumnKind::Bool(_) | ColumnKind::Uuid | ColumnKind::BitString { .. } | ColumnKind::Network(_) => EQUALITY,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn operators_for_interval_are_comparison_not_text() {
        let interval = operators_for(&ColumnKind::Interval);

        assert!(interval.contains(&FilterOp::Between), "{interval:?}");
        assert!(interval.contains(&FilterOp::Lt), "{interval:?}");
        assert!(!interval.contains(&FilterOp::Contains), "{interval:?}");
    }

    #[test]
    fn a_kind_with_no_comparable_text_gets_only_the_null_tests() {
        let array = ColumnKind::Array {
            element: Box::new(ColumnKind::Uuid),
        };
        for kind in [ColumnKind::Spatial, ColumnKind::Composite, ColumnKind::Variant, array] {
            assert_eq!(
                operators_for(&kind),
                &[FilterOp::IsNull, FilterOp::IsNotNull],
                "{kind:?}"
            );
        }
        assert!(operators_for(&ColumnKind::Money { scale: Some(2) }).contains(&FilterOp::Between));
        assert!(operators_for(&ColumnKind::Xml).contains(&FilterOp::Contains));
    }
}
