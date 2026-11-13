use super::{ColumnMasks, MaskingStyle, mask_value};
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
    // The style the column leaves with: never weaker than its rule's, so Keep takes the rule and a style that shows
    // what the rule hides becomes Full. Remove is no style.
    pub fn style(self, rule: Option<MaskingStyle>) -> Option<MaskingStyle> {
        let wanted = match self {
            Self::Keep | Self::Remove => None,
            Self::Mask(style) => Some(style),
        };
        MaskingStyle::strictest(rule, wanted)
    }
}

// How a share sends a result's visible columns: which it keeps, what it lays over each value as held, and the style
// each kept column names. The snapshot and the sheet's preview both go through it, so the preview shows what is sent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharePlan {
    kept: Vec<usize>,
    overlay: ColumnMasks,
    left: ColumnMasks,
    columns_cut: bool,
}

impl SharePlan {
    // `rules` are the visible columns' external masks (`MaskingPolicy::external_column_masks`), `shown` how the values
    // held are masked already (the grid's, none for a revealed tab), `choices` the sheet's for each visible column,
    // Keep past its end. At most `max_columns` columns are kept.
    pub fn new(
        visible: usize,
        rules: &ColumnMasks,
        shown: &ColumnMasks,
        choices: &[ShareChoice],
        max_columns: usize,
    ) -> Self {
        let choice = |index: usize| choices.get(index).copied().unwrap_or(ShareChoice::Keep);
        let mut kept: Vec<usize> = (0..visible)
            .filter(|index| choice(*index) != ShareChoice::Remove)
            .collect();
        let columns_cut = kept.len() > max_columns;
        kept.truncate(max_columns);
        let wanted = ColumnMasks::new(
            (0..visible)
                .map(|index| choice(index).style(rules.style(index)))
                .collect(),
        );
        let overlay = shown.overlay(&wanted);
        let left = shown.merged(&overlay);
        Self {
            kept,
            overlay,
            left,
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
        self.kept.iter().map(|index| self.left.style(*index)).collect()
    }

    // One row as sent. `read` gives the value held at a visible position and is asked only for kept columns.
    pub fn row(&self, visible: &[ResultColumn], mut read: impl FnMut(usize) -> Value) -> Vec<Value> {
        self.kept
            .iter()
            .map(|index| {
                let value = read(*index);
                match (self.overlay.style(*index), visible.get(*index)) {
                    (Some(style), Some(column)) => mask_value(&value, &column.column_type, style),
                    _ => value,
                }
            })
            .collect()
    }
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
    use super::MaskingStyle::{Email, Full, Hash, LastFour, Null};
    use super::*;
    use crate::column::ColumnType;

    fn columns() -> Vec<ResultColumn> {
        ["id", "email", "phone", "notes"]
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn held() -> Vec<Value> {
        ["1", "ann@example.com", "+1 555 0100", "vip"]
            .iter()
            .map(|value| Value::Text((*value).to_owned()))
            .collect()
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_rule_masked_column_never_leaves_weaker_than_its_rule() {
        assert_eq!(ShareChoice::Keep.style(Some(Email)), Some(Email));
        assert_eq!(ShareChoice::Mask(Email).style(Some(Email)), Some(Email));
        assert_eq!(ShareChoice::Mask(LastFour).style(Some(Email)), Some(Full));
        assert_eq!(ShareChoice::Mask(Null).style(Some(Email)), Some(Null));
        assert_eq!(ShareChoice::Keep.style(None), None);
        assert_eq!(ShareChoice::Mask(Hash).style(None), Some(Hash));
        assert_eq!(ShareChoice::Remove.style(Some(Email)), Some(Email));
    }

    #[test]
    fn removed_columns_go_and_the_rest_take_the_rule_and_the_choice() {
        let rules = ColumnMasks::new(vec![None, Some(Email), None, None]);
        let choices = [ShareChoice::Remove, ShareChoice::Keep, ShareChoice::Mask(LastFour)];

        let plan = SharePlan::new(4, &rules, &ColumnMasks::none(), &choices, 100);
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
    fn values_the_grid_masked_the_same_way_are_sent_as_held_and_others_tighten() {
        let rules = ColumnMasks::new(vec![None, Some(Email), None, None]);
        let shown = ColumnMasks::new(vec![None, Some(Email), Some(Hash), None]);
        let held = [text("1"), text("a•••@example.com"), text("3f2a9c1b0d4e"), text("vip")];

        let plan = SharePlan::new(
            4,
            &rules,
            &shown,
            &[ShareChoice::Keep, ShareChoice::Keep, ShareChoice::Keep],
            100,
        );
        let sent = plan.row(&columns(), |index| held[index].clone());

        assert_eq!(
            sent,
            [text("1"), text("a•••@example.com"), text("3f2a9c1b0d4e"), text("vip")]
        );
        assert_eq!(plan.masked(), [None, Some(Email), Some(Hash), None]);

        let tighter = SharePlan::new(
            4,
            &rules,
            &shown,
            &[ShareChoice::Keep, ShareChoice::Keep, ShareChoice::Mask(LastFour)],
            100,
        );
        assert_eq!(tighter.row(&columns(), |index| held[index].clone())[2], text("••••"));
        assert_eq!(tighter.masked()[2], Some(Full));
    }

    #[test]
    fn columns_past_the_cap_are_left_out_after_removals() {
        let plan = SharePlan::new(4, &ColumnMasks::none(), &ColumnMasks::none(), &[ShareChoice::Remove], 2);

        assert_eq!(plan.kept(), [1, 2]);
        assert!(plan.columns_cut());
        assert!(
            !SharePlan::new(3, &ColumnMasks::none(), &ColumnMasks::none(), &[ShareChoice::Remove], 2).columns_cut()
        );
    }

    #[test]
    fn a_summary_counts_the_rows_the_budget_keeps_or_says_why_none_go() {
        let visible = [ResultColumn::new("note", ColumnType::untyped_text("text"))];
        let plan = SharePlan::new(1, &ColumnMasks::none(), &ColumnMasks::none(), &[], 100);
        let long = |chars: usize| Value::Text("x".repeat(chars));

        let cut = plan.summary(&visible, 30, |_, _| long(200_000), 1_000);
        let refused = plan.summary(&visible, 3, |_, _| long(300_000), 1_000);
        let masked = SharePlan::new(
            1,
            &ColumnMasks::none(),
            &ColumnMasks::none(),
            &[ShareChoice::Mask(Full)],
            100,
        )
        .summary(&visible, 30, |_, _| long(200_000), 1_000);

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
        assert_eq!(masked.rows_sent, 30);
    }
}
