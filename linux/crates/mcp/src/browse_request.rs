use tablepro_core::browse::SortKey;
use tablepro_core::{ColumnInfo, Combinator, FilterOp, FilterRule, FilterSet, FilterValue};

use crate::tool_args::{Direction, FilterArg, FilterOperator, Logic, SortArg};
use crate::tool_error::ToolError;

/// The filter strip's filter for a client's conditions. There is no raw
/// SQL predicate: a client that needs one writes the query itself, and
/// it then goes through the statement gate.
pub fn filter_set(filters: &[FilterArg], logic: Option<Logic>) -> Result<FilterSet, ToolError> {
    let rules = filters.iter().map(rule).collect::<Result<Vec<_>, _>>()?;
    Ok(FilterSet {
        combinator: match logic.unwrap_or(Logic::And) {
            Logic::And => Combinator::And,
            Logic::Or => Combinator::Or,
        },
        rules,
        extra_sql: None,
    })
}

fn rule(filter: &FilterArg) -> Result<FilterRule, ToolError> {
    let op = operator(filter.operator);
    let value = match filter.operator {
        FilterOperator::IsNull | FilterOperator::IsNotNull => {
            if filter.value.is_some() || filter.values.is_some() {
                return Err(invalid(&filter.column, "is_null and is_not_null take no value"));
            }
            None
        }
        FilterOperator::In | FilterOperator::NotIn => match &filter.values {
            Some(values) if !values.is_empty() && filter.value.is_none() => Some(FilterValue::List(values.clone())),
            _ => return Err(invalid(&filter.column, "in and not_in take a non-empty values list")),
        },
        FilterOperator::Between => match filter.values.as_deref() {
            Some([low, high]) if filter.value.is_none() => Some(FilterValue::Pair(low.clone(), high.clone())),
            _ => {
                return Err(invalid(
                    &filter.column,
                    "between takes values with a low and a high bound",
                ));
            }
        },
        _ => match (&filter.value, &filter.values) {
            (Some(value), None) => Some(FilterValue::Single(value.clone())),
            _ => return Err(invalid(&filter.column, "this operator takes one value")),
        },
    };
    Ok(FilterRule {
        column: filter.column.clone(),
        op,
        value,
    })
}

fn operator(operator: FilterOperator) -> FilterOp {
    match operator {
        FilterOperator::Eq => FilterOp::Eq,
        FilterOperator::NotEq => FilterOp::NotEq,
        FilterOperator::Lt => FilterOp::Lt,
        FilterOperator::LtEq => FilterOp::LtEq,
        FilterOperator::Gt => FilterOp::Gt,
        FilterOperator::GtEq => FilterOp::GtEq,
        FilterOperator::Contains => FilterOp::Contains,
        FilterOperator::StartsWith => FilterOp::StartsWith,
        FilterOperator::EndsWith => FilterOp::EndsWith,
        FilterOperator::Like => FilterOp::Like,
        FilterOperator::NotLike => FilterOp::NotLike,
        FilterOperator::Ilike => FilterOp::Ilike,
        FilterOperator::IsNull => FilterOp::IsNull,
        FilterOperator::IsNotNull => FilterOp::IsNotNull,
        FilterOperator::In => FilterOp::In,
        FilterOperator::NotIn => FilterOp::NotIn,
        FilterOperator::Between => FilterOp::Between,
    }
}

pub fn sort_keys(sort: &[SortArg], columns: &[ColumnInfo]) -> Result<Vec<SortKey>, ToolError> {
    sort.iter()
        .map(|key| {
            let column = columns
                .iter()
                .position(|column| column.name == key.column)
                .ok_or_else(|| ToolError::InvalidArgument(format!("the table has no column named {}", key.column)))?;
            Ok(SortKey {
                column,
                ascending: key.direction != Some(Direction::Descending),
            })
        })
        .collect()
}

fn invalid(column: &str, problem: &str) -> ToolError {
    ToolError::InvalidArgument(format!("filter on {column}: {problem}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filter(operator: FilterOperator, value: Option<&str>, values: Option<&[&str]>) -> FilterArg {
        FilterArg {
            column: "status".to_owned(),
            operator,
            value: value.map(str::to_owned),
            values: values.map(|values| values.iter().map(|value| (*value).to_owned()).collect()),
        }
    }

    #[test]
    fn each_operator_takes_the_value_shape_the_strip_uses() {
        let set = filter_set(
            &[
                filter(FilterOperator::Eq, Some("open"), None),
                filter(FilterOperator::In, None, Some(&["a", "b"])),
                filter(FilterOperator::Between, None, Some(&["1", "9"])),
                filter(FilterOperator::IsNull, None, None),
            ],
            Some(Logic::Or),
        )
        .expect("a filter");

        assert_eq!(set.combinator, Combinator::Or);
        assert_eq!(set.extra_sql, None);
        let values: Vec<Option<FilterValue>> = set.rules.into_iter().map(|rule| rule.value).collect();
        assert_eq!(
            values,
            [
                Some(FilterValue::Single("open".to_owned())),
                Some(FilterValue::List(vec!["a".to_owned(), "b".to_owned()])),
                Some(FilterValue::Pair("1".to_owned(), "9".to_owned())),
                None,
            ]
        );
    }

    #[test]
    fn a_value_of_the_wrong_shape_is_refused() {
        let wrong = [
            filter(FilterOperator::Eq, None, None),
            filter(FilterOperator::Eq, Some("a"), Some(&["b"])),
            filter(FilterOperator::In, None, Some(&[])),
            filter(FilterOperator::Between, None, Some(&["1"])),
            filter(FilterOperator::IsNull, Some("x"), None),
        ];
        for filter in wrong {
            let refused = filter_set(std::slice::from_ref(&filter), None);
            assert!(
                matches!(refused, Err(ToolError::InvalidArgument(_))),
                "{filter:?} was accepted"
            );
        }
    }

    #[test]
    fn a_sort_names_columns_by_position() {
        let columns: Vec<ColumnInfo> = Vec::new();
        let unknown = SortArg {
            column: "missing".to_owned(),
            direction: None,
        };

        assert!(matches!(
            sort_keys(&[unknown], &columns),
            Err(ToolError::InvalidArgument(_))
        ));
    }
}
