use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_linux_platform::settings::GridRowHeight;

use super::DataGrid;
use super::grid_cell::set_class;
use crate::ui::handler_guard::HandlerGuard;

impl DataGrid {
    pub(super) fn watch_display_settings(&self) {
        let Some(config) = self.config() else {
            return;
        };
        let preferences = config.settings.grid_preferences();
        let weak = self.downgrade();
        let handler = preferences.connect_changed(move |_| {
            if let Some(grid) = weak.upgrade() {
                grid.apply_display_settings();
            }
        });
        self.imp()
            .display_watch
            .replace(Some(HandlerGuard::new(preferences, handler)));
        self.apply_display_settings();
    }

    pub(super) fn apply_display_settings(&self) {
        let Some(config) = self.config() else {
            return;
        };
        let values = config.settings.grid_preferences().snapshot();
        let view = self.column_view();
        let font_changed = {
            let mut installed = self.imp().cell_font.borrow_mut();
            installed
                .get_or_insert_with(|| super::cell_font::CellFont::new(&view))
                .apply(&values.font)
        };
        for height in GridRowHeight::ALL {
            set_class(&view, height.css_class(), height == values.row_height);
        }
        set_class(&view, "tp-striped", values.show_alternate_rows);
        if let Some(numbers) = self.row_numbers_column() {
            numbers.set_visible(values.show_row_numbers);
        }
        let changed = self.imp().applied_null.borrow().as_deref() != Some(&values.null_display);
        if changed {
            self.imp().applied_null.replace(Some(values.null_display.clone()));
            self.redraw();
        }
        if changed || font_changed {
            self.fonts_changed();
        }
    }
}
