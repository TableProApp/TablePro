use super::{MaskingStyle, mask_value};
use crate::column::ResultColumn;
use crate::export::{SnapshotTooLarge, snapshot_row_count};
use crate::value::Value;

// What the share sheet does with one column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShareChoice {
    Keep,
    Mask(MaskingStyle),
    Remove,
}

impl ShareChoice {
    pub fn style(self) -> Option<MaskingStyle> {
        match self {
            Self::Mask(style) => Some(style),
            Self::Keep | Self::Remove => None,
        }
    }
}

// How a share sends a result's visible columns: which it keeps and how it masks each. The snapshot, the sheet's preview
// and its summary all go through it, so the sheet shows what is sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharePlan {
    kept: Vec<usize>,
    styles: Vec<Option<MaskingStyle>>,
    columns_cut: bool,
}

// What a share with a plan sends, for the sheet's note: the rows the snapshot keeps under the plan's row limit and its
// body budget, or why it cannot go at all.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareSummary {
    pub rows_sent: usize,
    pub columns_sent: usize,
    pub columns_cut: bool,
    pub too_large: Option<SnapshotTooLarge>,
}

impl SharePlan {
    // `choices` is the sheet's for each visible column, Keep past its end. At most `max_columns` columns are kept.
    pub fn new(visible: usize, choices: &[ShareChoice], max_columns: usize) -> Self {
        let choice = |index: usize| choices.get(index).copied().unwrap_or(ShareChoice::Keep);
        let mut kept: Vec<usize> = (0..visible)
            .filter(|index| choice(*index) != ShareChoice::Remove)
            .collect();
        let columns_cut = kept.len() > max_columns;
        kept.truncate(max_columns);
        Self {
            styles: (0..visible).map(|index| choice(index).style()).collect(),
            kept,
            columns_cut,
        }
    }

    // Positions among the visible columns, in order.
    pub fn kept(&self) -> &[usize] {
        &self.kept
    }

    // More columns were chosen than `max_columns`, and the rest were left out.
    pub fn columns_cut(&self) -> bool {
        self.columns_cut
    }

    pub fn columns(&self, visible: &[ResultColumn]) -> Vec<ResultColumn> {
        self.kept
            .iter()
            .filter_map(|index| visible.get(*index).cloned())
            .collect()
    }

    // The style each kept column names, in the order of `kept`.
    pub fn masked(&self) -> Vec<Option<MaskingStyle>> {
        self.kept
            .iter()
            .map(|index| self.styles.get(*index).copied().flatten())
            .collect()
    }

    // One row as sent. `read` gives the value held at a visible position and is asked only for kept columns.
    pub fn row(&self, visible: &[ResultColumn], mut read: impl FnMut(usize) -> Value) -> Vec<Value> {
        self.kept
            .iter()
            .map(|index| {
                let value = read(*index);
                match (self.styles.get(*index).copied().flatten(), visible.get(*index)) {
                    (Some(style), Some(column)) => mask_value(&value, &column.column_type, style),
                    _ => value,
                }
            })
            .collect()
    }

    // `rows` held rows of the visible columns, read one value at a time by `read(row, column)`; at most `max_rows`.
    pub fn summary(
        &self,
        visible: &[ResultColumn],
        rows: usize,
        mut read: impl FnMut(usize, usize) -> Value,
        max_rows: usize,
    ) -> ShareSummary {
        let sent = snapshot_row_count(
            &self.columns(visible),
            (0..rows).map(|row| self.row(visible, |column| read(row, column))),
            max_rows,
        );
        let (rows_sent, too_large) = match sent {
            Ok(rows) => (rows, None),
            Err(refused) => (0, Some(refused)),
        };
        ShareSummary {
            rows_sent,
            columns_sent: self.kept.len(),
            columns_cut: self.columns_cut,
            too_large,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::MaskingStyle::{Email, Full, LastFour};
    use super::*;
    use crate::column::ColumnType;

    fn columns() -> Vec<ResultColumn> {
        ["id", "email", "phone", "notes"]
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn held() -> Vec<Value> {
        ["1", "ann@example.com", "+1 555 0100", "vip"]
            .iter()
            .map(|value| text(value))
            .collect()
    }

    #[test]
    fn removed_columns_go_and_the_rest_take_their_choice() {
        let choices = [
            ShareChoice::Remove,
            ShareChoice::Mask(Email),
            ShareChoice::Mask(LastFour),
        ];

        let plan = SharePlan::new(4, &choices, 100);
        let row = held();
        let mut asked = Vec::new();
        let sent = plan.row(&columns(), |index| {
            asked.push(index);
            row[index].clone()
        });

        assert_eq!(plan.kept(), [1, 2, 3]);
        assert_eq!(asked, [1, 2, 3], "a removed column was read");
        assert_eq!(sent, [text("a•••@example.com"), text("••••0100"), text("vip")]);
        assert_eq!(plan.masked(), [Some(Email), Some(LastFour), None]);
        let names: Vec<String> = plan.columns(&columns()).into_iter().map(|column| column.name).collect();
        assert_eq!(names, ["email", "phone", "notes"]);
    }

    #[test]
    fn a_null_stays_null_under_every_style() {
        for style in MaskingStyle::ALL {
            let plan = SharePlan::new(1, &[ShareChoice::Mask(style)], 100);

            assert_eq!(plan.row(&columns(), |_| Value::Null), [Value::Null], "{style:?}");
        }
    }

    #[test]
    fn columns_past_the_cap_are_left_out_after_removals() {
        let plan = SharePlan::new(4, &[ShareChoice::Remove], 2);

        assert_eq!(plan.kept(), [1, 2]);
        assert!(plan.columns_cut());
        assert!(!SharePlan::new(3, &[ShareChoice::Remove], 2).columns_cut());
    }

    #[test]
    fn a_summary_counts_the_rows_the_budget_keeps_or_says_why_none_go() {
        let visible = [ResultColumn::new("note", ColumnType::untyped_text("text"))];
        let plan = SharePlan::new(1, &[], 100);
        let long = |chars: usize| Value::Text("x".repeat(chars));

        let cut = plan.summary(&visible, 30, |_, _| long(200_000), 1_000);
        let refused = plan.summary(&visible, 3, |_, _| long(300_000), 1_000);
        let masked =
            SharePlan::new(1, &[ShareChoice::Mask(Full)], 100).summary(&visible, 30, |_, _| long(200_000), 1_000);

        assert_eq!(
            cut,
            ShareSummary {
                rows_sent: 22,
                columns_sent: 1,
                columns_cut: false,
                too_large: None,
            }
        );
        assert_eq!(refused.rows_sent, 0);
        assert_eq!(
            refused.too_large,
            Some(SnapshotTooLarge::Cell {
                column: "note".to_owned()
            })
        );
        assert_eq!(masked.rows_sent, 30, "masked text was not what was weighed");
    }
}
