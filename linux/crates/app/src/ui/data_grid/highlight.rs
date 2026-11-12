use std::borrow::Cow;
use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::Value;
use tablepro_linux_platform::settings::DateFormat;

use super::{DataGrid, GridRow};
use crate::services::grid::display_text::whole_text;
use crate::services::grid::{HighlightColor, HighlightRule, HighlightRules, HighlightValue};
use crate::services::tab_tracker_handle::TabTrackerHandle;

/// A row's highlight, worked out once and drawn by each of its cells.
pub(super) struct RowTint {
    basis: TintBasis,
    colours: Vec<Option<HighlightColor>>,
    /// What `RowHighlight::color_of` gives a column past the grid's.
    beyond: Option<HighlightColor>,
}

impl RowTint {
    fn colour(&self, column: usize) -> Option<HighlightColor> {
        self.colours.get(column).copied().unwrap_or(self.beyond)
    }
}

/// What a row's highlight was worked out from. Each part moves when what
/// it reads changes, a tracker change no row was redrawn for included.
struct TintBasis {
    revision: u32,
    // Held, not only compared by address, so no later compile can reuse it.
    rules: Rc<HighlightRules>,
    tracker: Option<u64>,
}

impl TintBasis {
    fn holds_for(&self, other: &Self) -> bool {
        self.revision == other.revision && Rc::ptr_eq(&self.rules, &other.rules) && self.tracker == other.tracker
    }
}

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

    pub fn connect_highlight_rules_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "highlight-rules-changed",
            false,
            glib::closure_local!(move |grid: &Self| f(grid)),
        )
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
        let basis = TintBasis {
            revision: row.revision(),
            rules,
            tracker: self
                .config()
                .and_then(|config| config.tracker.as_ref().map(TabTrackerHandle::version)),
        };
        if let Some(tint) = row.tint().borrow().as_ref().filter(|tint| tint.basis.holds_for(&basis)) {
            return tint.colour(column);
        }
        let tint = self.work_out_tint(row, basis);
        let colour = tint.colour(column);
        row.tint().replace(Some(tint));
        colour
    }

    fn work_out_tint(&self, row: &GridRow, basis: TintBasis) -> RowTint {
        #[cfg(test)]
        row.count_tint();
        let columns = self.grid_columns();
        let mut values = vec![HighlightValue::Unavailable; columns.len()];
        let tracked = self.tracked();
        let mut scratch = String::new();
        let stored = row.cells();
        for read in basis.rules.columns() {
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
        let found = basis.rules.highlight(&values);
        RowTint {
            colours: (0..columns.len()).map(|column| found.color_of(column)).collect(),
            beyond: found.row,
            basis,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::edit::CellInput;
    use tablepro_core::filter::{FilterOp, FilterValue};

    use super::*;
    use crate::services::tracker_edit::TrackerEdit;
    use crate::test_support::drain_main_context;
    use crate::ui::data_grid::GridCell;
    use crate::ui::data_grid::test_grid::{Grid, key, two_text_columns, two_text_values};

    fn name_is(value: &str) -> HighlightRule {
        let mut rule = HighlightRule::new("name");
        rule.value = Some(FilterValue::Single(value.into()));
        rule
    }

    fn tinted(cell: &GridCell) -> bool {
        cell.has_css_class(HighlightColor::Yellow.css_class())
    }

    fn rename_first(grid: &Grid, from: &str, to: &str) {
        let delta = grid.tracker.apply(TrackerEdit::Cell {
            row_key: key(1),
            col: 1,
            original: Value::Text(from.into()),
            value: CellInput::Value(Value::Text(to.into())),
        });
        grid.grid.apply_delta(&delta);
    }

    #[gtk4::test]
    fn a_row_works_out_its_highlight_once_for_all_of_its_cells() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        grid.grid.set_highlight_rules(vec![name_is("A")]);
        drain_main_context();
        let row = grid.grid.store().row(0).expect("a row");
        let cells = [grid.cell_of(1, 0), grid.cell_of(1, 1)];
        let drawn: Vec<u32> = cells.iter().map(GridCell::render_count).collect();
        let worked_out = row.tints_worked_out();

        row.bump_revision();

        for (cell, before) in cells.iter().zip(drawn) {
            assert_eq!(cell.render_count(), before + 1, "every cell of the row drew again");
            assert!(tinted(cell), "a cell of the row lost its colour");
        }
        assert_eq!(row.tints_worked_out(), worked_out + 1, "each cell ran the rules again");
    }

    #[gtk4::test]
    fn an_edit_to_the_rule_column_recolours_the_other_cells_of_its_row() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        grid.grid.set_highlight_rules(vec![name_is("A")]);
        drain_main_context();
        let id_cell = grid.cell_of(1, 0);
        assert!(tinted(&id_cell));

        rename_first(&grid, "A", "Z");
        assert!(
            !tinted(&id_cell),
            "the id kept the colour of a name the row no longer has"
        );

        grid.grid.undo();
        assert!(tinted(&id_cell), "undo left the id without its colour");
    }

    #[gtk4::test]
    fn a_tracker_change_no_row_was_redrawn_for_reaches_the_next_draw() {
        let grid = Grid::open(two_text_columns(), two_text_values());
        grid.grid.set_highlight_rules(vec![name_is("Z")]);
        rename_first(&grid, "A", "Z");
        let id_cell = grid.cell_of(1, 0);
        assert!(tinted(&id_cell));

        // As a close prompt's Discard leaves the grid until the next page lands.
        let _ = grid.tracker.discard();
        id_cell.render();

        assert!(!tinted(&id_cell), "the draw kept the colour of the discarded edit");
    }

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
