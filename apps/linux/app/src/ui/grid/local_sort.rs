use std::cmp::Ordering;

use tablepro_core::{QueryResult, Value};

pub(super) fn sorted_source_indices(result: &QueryResult, column: usize, ascending: bool) -> Option<Vec<usize>> {
    let values = result
        .rows
        .iter()
        .map(|row| row.get(column))
        .collect::<Option<Vec<_>>>()?;
    let kind = values.iter().find_map(|value| comparable_kind(value));
    if values.iter().any(|value| {
        (!matches!(value, Value::Null) && comparable_kind(value).is_none())
            || comparable_kind(value).is_some_and(|candidate| Some(candidate) != kind)
    }) {
        return None;
    }
    let mut indices = (0..result.rows.len()).collect::<Vec<_>>();
    indices.sort_by(|left, right| compare_values(values[*left], values[*right], ascending));
    Some(indices)
}

pub(super) fn is_sortable_column(result: &QueryResult, column: usize) -> bool {
    let Some(values) = result
        .rows
        .iter()
        .map(|row| row.get(column))
        .collect::<Option<Vec<_>>>()
    else {
        return false;
    };
    let kind = values.iter().find_map(|value| comparable_kind(value));
    !values.iter().any(|value| {
        (!matches!(value, Value::Null) && comparable_kind(value).is_none())
            || comparable_kind(value).is_some_and(|candidate| Some(candidate) != kind)
    })
}

fn comparable_kind(value: &Value) -> Option<std::mem::Discriminant<Value>> {
    match value {
        Value::Bool(_)
        | Value::Int(_)
        | Value::Float(_)
        | Value::Text(_)
        | Value::Bytes(_)
        | Value::Date(_)
        | Value::Time(_)
        | Value::DateTime(_)
        | Value::TimestampTz(_)
        | Value::Decimal(_)
        | Value::Uuid(_) => Some(std::mem::discriminant(value)),
        Value::Null | Value::Json(_) | Value::Undecodable(_) => None,
    }
}

fn compare_values(left: &Value, right: &Value, ascending: bool) -> Ordering {
    let order = match (left, right) {
        (Value::Null, Value::Null) => Ordering::Equal,
        (Value::Null, _) => Ordering::Greater,
        (_, Value::Null) => Ordering::Less,
        _ => compare_non_null(left, right).unwrap_or(Ordering::Equal),
    };
    if ascending || matches!((left, right), (Value::Null, _) | (_, Value::Null)) {
        order
    } else {
        order.reverse()
    }
}

fn compare_non_null(left: &Value, right: &Value) -> Option<Ordering> {
    Some(match (left, right) {
        (Value::Bool(left), Value::Bool(right)) => left.cmp(right),
        (Value::Int(left), Value::Int(right)) => left.cmp(right),
        (Value::Float(left), Value::Float(right)) => left.total_cmp(right),
        (Value::Text(left), Value::Text(right)) => left.cmp(right),
        (Value::Bytes(left), Value::Bytes(right)) => left.cmp(right),
        (Value::Date(left), Value::Date(right)) => left.cmp(right),
        (Value::Time(left), Value::Time(right)) => left.cmp(right),
        (Value::DateTime(left), Value::DateTime(right)) => left.cmp(right),
        (Value::TimestampTz(left), Value::TimestampTz(right)) => left.cmp(right),
        (Value::Decimal(left), Value::Decimal(right)) => left.cmp(right),
        (Value::Uuid(left), Value::Uuid(right)) => left.cmp(right),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use chrono::NaiveDate;
    use rust_decimal::Decimal;
    use tablepro_core::{ColumnInfo, QueryResult, Value};

    use super::sorted_source_indices;

    fn result(values: Vec<Value>) -> QueryResult {
        QueryResult {
            columns: vec![ColumnInfo {
                name: "value".into(),
                data_type: "".into(),
                nullable: true,
                primary_key: false,
                is_auto_increment: false,
                default_value: None,
                is_generated: false,
                comment: None,
                collation: None,
                enum_type: None,
                domain_type: None,
            }],
            rows: values.into_iter().map(|value| vec![value]).collect(),
            truncated: false,
        }
    }

    #[test]
    fn local_sort_orders_native_values_and_keeps_equal_rows_stable() {
        let result = result(vec![Value::Int(10), Value::Int(2), Value::Int(2)]);

        assert_eq!(sorted_source_indices(&result, 0, true), Some(vec![1, 2, 0]));
        assert_eq!(sorted_source_indices(&result, 0, false), Some(vec![0, 1, 2]));
    }

    #[test]
    fn local_sort_keeps_nulls_last_in_both_directions() {
        let result = result(vec![Value::Null, Value::Int(2), Value::Int(1)]);

        assert_eq!(sorted_source_indices(&result, 0, true), Some(vec![2, 1, 0]));
        assert_eq!(sorted_source_indices(&result, 0, false), Some(vec![1, 2, 0]));
    }

    #[test]
    fn local_sort_uses_native_decimal_and_date_ordering() {
        let decimal = result(vec![
            Value::Decimal(Decimal::new(20, 1)),
            Value::Decimal(Decimal::new(3, 1)),
        ]);
        let date = result(vec![
            Value::Date(NaiveDate::from_ymd_opt(2024, 2, 1).unwrap()),
            Value::Date(NaiveDate::from_ymd_opt(2024, 1, 1).unwrap()),
        ]);

        assert_eq!(sorted_source_indices(&decimal, 0, true), Some(vec![1, 0]));
        assert_eq!(sorted_source_indices(&date, 0, true), Some(vec![1, 0]));
    }

    #[test]
    fn local_sort_refuses_mixed_or_undecodable_columns() {
        let mixed = result(vec![Value::Int(1), Value::Text("1".into())]);
        let undecodable = result(vec![Value::Int(1), Value::Undecodable("NUMERIC".into())]);

        assert_eq!(sorted_source_indices(&mixed, 0, true), None);
        assert_eq!(sorted_source_indices(&undecodable, 0, true), None);
    }
}
