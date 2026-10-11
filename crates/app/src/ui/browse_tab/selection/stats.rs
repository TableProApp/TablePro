use rust_decimal::Decimal;
use tablepro_core::{ColumnInfo, Value};

#[derive(Debug, PartialEq)]
pub(in crate::ui::browse_tab) struct ColumnStats {
    pub column: String,
    pub sum: String,
    pub average: String,
}

enum Total {
    Exact(Decimal, u32),
    Float(f64, u32),
}

fn add(total: Option<Total>, value: &Value) -> Option<Option<Total>> {
    match (total, value) {
        (total, Value::Null) => Some(total),
        (None, Value::Int(n)) => Some(Some(Total::Exact(Decimal::from(*n), 1))),
        (None, Value::Decimal(d)) => Some(Some(Total::Exact(*d, 1))),
        (None, Value::Float(f)) => Some(Some(Total::Float(*f, 1))),
        (Some(Total::Exact(sum, n)), Value::Int(i)) => {
            Some(Some(Total::Exact(sum.checked_add(Decimal::from(*i))?, n + 1)))
        }
        (Some(Total::Exact(sum, n)), Value::Decimal(d)) => Some(Some(Total::Exact(sum.checked_add(*d)?, n + 1))),
        (Some(Total::Float(sum, n)), Value::Float(f)) => Some(Some(Total::Float(sum + f, n + 1))),
        _ => None,
    }
}

fn describe(total: Total) -> Option<(String, String)> {
    match total {
        Total::Exact(sum, n) => Some((
            sum.normalize().to_string(),
            (sum / Decimal::from(n)).round_dp(6).normalize().to_string(),
        )),
        Total::Float(sum, n) if sum.is_finite() => Some((sum.to_string(), (sum / f64::from(n)).to_string())),
        Total::Float(..) => None,
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
            let (sum, average) = describe(total?)?;
            Some(ColumnStats {
                column: column.name.clone(),
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
            crate::tr!("{column}: sum {sum}, average {average}")
                .replace("{column}", &s.column)
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
