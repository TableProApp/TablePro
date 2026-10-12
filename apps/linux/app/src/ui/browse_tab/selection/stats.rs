use rust_decimal::Decimal;
use tablepro_core::{ColumnInfo, Value};

#[derive(Debug, PartialEq)]
pub(in crate::ui::browse_tab) struct ColumnStats {
    pub column: String,
    pub count: u32,
    pub minimum: String,
    pub maximum: String,
    pub sum: String,
    pub average: String,
}

#[derive(Clone, Copy)]
enum Total {
    Exact {
        sum: Decimal,
        count: u32,
        minimum: Decimal,
        maximum: Decimal,
    },
    Float {
        sum: f64,
        count: u32,
        minimum: f64,
        maximum: f64,
    },
}

fn add(total: Option<Total>, value: &Value) -> Option<Option<Total>> {
    match (total, value) {
        (total, Value::Null) => Some(total),
        (None, Value::Int(n)) => Some(Some(exact(Decimal::from(*n)))),
        (None, Value::Decimal(d)) => Some(Some(exact(*d))),
        (None, Value::Float(f)) if f.is_finite() => Some(Some(float(*f))),
        (
            Some(Total::Exact {
                sum,
                count,
                minimum,
                maximum,
            }),
            Value::Int(i),
        ) => exact_add(sum, count, minimum, maximum, Decimal::from(*i)),
        (
            Some(Total::Exact {
                sum,
                count,
                minimum,
                maximum,
            }),
            Value::Decimal(d),
        ) => exact_add(sum, count, minimum, maximum, *d),
        (
            Some(Total::Float {
                sum,
                count,
                minimum,
                maximum,
            }),
            Value::Float(f),
        ) if f.is_finite() => {
            let next_sum = sum + f;
            next_sum.is_finite().then_some(Some(Total::Float {
                sum: next_sum,
                count: count.checked_add(1)?,
                minimum: minimum.min(*f),
                maximum: maximum.max(*f),
            }))
        }
        _ => None,
    }
}

fn exact(value: Decimal) -> Total {
    Total::Exact {
        sum: value,
        count: 1,
        minimum: value,
        maximum: value,
    }
}

fn float(value: f64) -> Total {
    Total::Float {
        sum: value,
        count: 1,
        minimum: value,
        maximum: value,
    }
}

fn exact_add(sum: Decimal, count: u32, minimum: Decimal, maximum: Decimal, value: Decimal) -> Option<Option<Total>> {
    Some(Some(Total::Exact {
        sum: sum.checked_add(value)?,
        count: count.checked_add(1)?,
        minimum: minimum.min(value),
        maximum: maximum.max(value),
    }))
}

fn describe(total: Total) -> Option<(String, String)> {
    match total {
        Total::Exact { sum, count, .. } => Some((
            sum.normalize().to_string(),
            (sum / Decimal::from(count)).round_dp(6).normalize().to_string(),
        )),
        Total::Float { sum, count, .. } if sum.is_finite() => {
            Some((sum.to_string(), (sum / f64::from(count)).to_string()))
        }
        Total::Float { .. } => None,
    }
}

pub(in crate::ui::browse_tab) fn column_stats(columns: &[ColumnInfo], rows: &[Vec<Value>]) -> Vec<ColumnStats> {
    columns
        .iter()
        .enumerate()
        .filter_map(|(index, column)| {
            let mut total = None;
            for row in rows {
                total = add(total, row.get(index)?)?;
            }
            let total = total?;
            let (sum, average) = describe(total)?;
            let (count, minimum, maximum) = match total {
                Total::Exact {
                    count,
                    minimum,
                    maximum,
                    ..
                } => (count, minimum.normalize().to_string(), maximum.normalize().to_string()),
                Total::Float {
                    count,
                    minimum,
                    maximum,
                    ..
                } => (count, minimum.to_string(), maximum.to_string()),
            };
            Some(ColumnStats {
                column: column.name.clone(),
                count,
                minimum,
                maximum,
                sum,
                average,
            })
        })
        .collect()
}

pub(in crate::ui::browse_tab) fn tooltip(stats: &[ColumnStats]) -> String {
    stats
        .iter()
        .map(|s| {
            crate::tr!("{column}: count {count}, min {minimum}, max {maximum}, sum {sum}, average {average}")
                .replace("{column}", &s.column)
                .replace("{count}", &s.count.to_string())
                .replace("{minimum}", &s.minimum)
                .replace("{maximum}", &s.maximum)
                .replace("{sum}", &s.sum)
                .replace("{average}", &s.average)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn column(name: &str) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: String::new(),
            nullable: true,
            primary_key: false,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn integers_sum_exactly_and_nulls_are_skipped() {
        let rows = vec![vec![Value::Int(1)], vec![Value::Null], vec![Value::Int(4)]];
        let stats = column_stats(&[column("n")], &rows);
        assert_eq!(
            stats,
            [ColumnStats {
                column: "n".into(),
                count: 2,
                minimum: "1".into(),
                maximum: "4".into(),
                sum: "5".into(),
                average: "2.5".into()
            }]
        );
    }

    #[test]
    fn decimals_keep_their_precision() {
        let d = |s: &str| Value::Decimal(s.parse().unwrap());
        let stats = column_stats(&[column("p")], &[vec![d("0.1")], vec![d("0.2")]]);
        assert_eq!(stats[0].sum, "0.3");
        assert_eq!(stats[0].minimum, "0.1");
        assert_eq!(stats[0].maximum, "0.2");
    }

    #[test]
    fn non_finite_and_overflowing_float_summaries_are_omitted() {
        let non_finite = [vec![Value::Float(f64::INFINITY)]];
        assert!(column_stats(&[column("n")], &non_finite).is_empty());
        let overflow = [vec![Value::Float(f64::MAX)], vec![Value::Float(f64::MAX)]];
        assert!(column_stats(&[column("n")], &overflow).is_empty());
    }

    #[test]
    fn mixed_or_text_columns_have_no_stats() {
        let rows = vec![
            vec![Value::Int(1), Value::Text("a".into())],
            vec![Value::Float(1.0), Value::Text("b".into())],
        ];
        assert!(column_stats(&[column("a"), column("b")], &rows).is_empty());
    }

    #[test]
    fn an_all_null_column_has_no_stats() {
        assert!(column_stats(&[column("n")], &[vec![Value::Null]]).is_empty());
    }
}
