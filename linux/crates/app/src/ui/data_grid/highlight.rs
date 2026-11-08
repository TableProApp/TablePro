//! Highlight rules on the grid: the rules the user wrote for the table or
//! result, compiled against its columns, and the colour each cell draws
//! from them (`HighlightRules`).

use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;

use super::{DataGrid, GridRow};
use crate::services::grid::display_text::display_text;
use crate::services::grid::{HighlightColor, HighlightRule, HighlightRules};

impl DataGrid {
    /// Paint rows and cells by `rules`, which replace the ones held.
    pub fn set_highlight_rules(&self, rules: Vec<HighlightRule>) {
        self.imp().highlight_source.replace(rules);
        self.compile_highlights();
        self.redraw();
        self.emit_by_name::<()>("highlight-rules-changed", &[]);
    }

    /// The rules changed, as the popover or a load sets them, for a host that keeps them.
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

    /// Match the rules to the columns the grid has now. A rule for a
    /// column that another read lacks waits and paints nothing.
    pub(super) fn compile_highlights(&self) {
        let names: Vec<String> = self.grid_columns().iter().map(|column| column.name.clone()).collect();
        let compiled = HighlightRules::compile(&self.imp().highlight_source.borrow(), &names);
        self.imp().highlights.replace(Rc::new(compiled));
    }

    /// The colour the cell of `row` in `column` draws, if a rule holds for it.
    pub(super) fn highlight_of(&self, row: &GridRow, column: usize) -> Option<HighlightColor> {
        let rules = self.imp().highlights.borrow().clone();
        if rules.is_empty() {
            return None;
        }
        let columns = self.grid_columns();
        // A rule reads only its own column's text, so the others stay empty.
        let mut texts: Vec<Option<String>> = vec![None; columns.len()];
        let tracked = self.tracked();
        let mut scratch = String::new();
        for read in rules.columns() {
            let Some(definition) = columns.get(read) else {
                continue;
            };
            texts[read] = tracked.with_value(row, read, |value, computed| {
                if computed.is_some() || value.is_null() {
                    return None;
                }
                Some(
                    display_text(value, &definition.column_type, &mut scratch)
                        .text
                        .to_owned(),
                )
            });
        }
        let cells: Vec<Option<&str>> = texts.iter().map(Option::as_deref).collect();
        rules.highlight(&cells).color_of(column)
    }
}
