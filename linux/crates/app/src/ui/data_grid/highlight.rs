use std::borrow::Cow;
use std::rc::Rc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::Value;
use tablepro_linux_platform::settings::DateFormat;

use super::{DataGrid, GridRow};
use crate::services::grid::display_text::whole_text;
use crate::services::grid::{HighlightColor, HighlightRule, HighlightRules, HighlightValue};

impl DataGrid {
    pub fn set_highlight_rules(&self, rules: Vec<HighlightRule>) {
        if *self.imp().highlight_source.borrow() == rules {
            return;
        }
        self.imp().highlight_source.replace(rules);
        self.compile_highlights();
        self.redraw();
        self.emit_by_name::<()>("highlight-rules-changed", &[]);
    }

    pub fn highlight_rules(&self) -> Vec<HighlightRule> {
        self.imp().highlight_source.borrow().clone()
    }

    pub(super) fn compile_highlights(&self) {
        let compiled = HighlightRules::compile(&self.imp().highlight_source.borrow(), &self.grid_columns());
        self.imp().highlights.replace(Rc::new(compiled));
    }

    pub(super) fn highlight_of(&self, row: &GridRow, column: usize) -> Option<HighlightColor> {
        let rules = self.imp().highlights.borrow().clone();
        if rules.is_empty() {
            return None;
        }
        let columns = self.grid_columns();
        let mut values = vec![HighlightValue::Unavailable; columns.len()];
        let tracked = self.tracked();
        let mut scratch = String::new();
        let stored = row.cells();
        for read in rules.columns() {
            let Some(definition) = columns.get(read) else {
                continue;
            };
            if stored.as_ref().is_some_and(|cells| read >= cells.len()) {
                continue;
            }
            values[read] = tracked.with_value(row, read, |value, computed| {
                if computed.is_some() {
                    return HighlightValue::Unavailable;
                }
                match value {
                    Value::Null => HighlightValue::Null,
                    Value::Bytes(_) => HighlightValue::NonText,
                    Value::Undecodable(_) => HighlightValue::Unavailable,
                    // Rules match the stored value, so the display's date format never changes which rows light up.
                    value => HighlightValue::Text(Cow::Owned(
                        whole_text(value, &definition.column_type, DateFormat::Iso, &mut scratch).to_owned(),
                    )),
                }
            });
        }
        rules.highlight(&values).color_of(column)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::edit::CellInput;
    use tablepro_core::filter::{FilterOp, FilterValue};

    use super::*;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::ui::data_grid::test_grid::{Grid, key, two_text_columns};

    #[gtk4::test]
    fn highlights_read_past_the_display_cut_and_follow_pending_values() {
        let long = format!("{}tail", "x".repeat(2_000));
        let grid = Grid::open(two_text_columns(), vec![vec![Value::Int(1), Value::Text(long.clone())]]);
        let mut rule = HighlightRule::new("name");
        rule.op = FilterOp::EndsWith;
        rule.value = Some(FilterValue::Single("tail".into()));
        grid.grid.set_highlight_rules(vec![rule]);
        let row = grid.grid.store().row(0).expect("a row");
        assert_eq!(grid.grid.highlight_of(&row, 1), Some(HighlightColor::Yellow));

        let delta = grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text(long),
            value: CellInput::Value(Value::Text("different".into())),
        });
        grid.grid.apply_delta(&delta);
        assert_eq!(grid.grid.highlight_of(&row, 1), None);
    }

    #[gtk4::test]
    fn computed_and_absent_cells_do_not_match_null_rules() {
        let grid = Grid::open(two_text_columns(), vec![vec![Value::Int(1), Value::Text("old".into())]]);
        let mut rule = HighlightRule::new("name");
        rule.op = FilterOp::IsNull;
        rule.value = None;
        grid.grid.set_highlight_rules(vec![rule]);
        let row = grid.grid.store().row(0).expect("a row");
        let delta = grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text("old".into()),
            value: CellInput::Default,
        });
        grid.grid.apply_delta(&delta);
        assert_eq!(grid.grid.highlight_of(&row, 1), None);

        let absent = GridRow::new(super::super::RowData::result(vec![Value::Int(2)].into()));
        assert_eq!(grid.grid.highlight_of(&absent, 1), None);
        let null = GridRow::new(super::super::RowData::result(vec![Value::Int(2), Value::Null].into()));
        assert_eq!(grid.grid.highlight_of(&null, 1), Some(HighlightColor::Yellow));
    }
}
