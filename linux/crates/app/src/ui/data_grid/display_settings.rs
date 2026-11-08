//! The preferences that shape how a grid reads, as the macOS data grid
//! settings do: whether rows are numbered, how much room a row takes, and
//! what a NULL shows.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_linux_platform::settings::keys;

use super::DataGrid;
use super::grid_cell::set_class;
use crate::services::grid::display_text::{DateFormat, date_format, set_date_format, set_null_display};
use crate::ui::handler_guard::HandlerGuard;

/// The classes a row height takes, one for each word the setting holds.
const HEIGHT_CLASSES: [(&str, &str); 4] = [
    ("compact", "row-compact"),
    ("normal", "row-normal"),
    ("comfortable", "row-comfortable"),
    ("spacious", "row-spacious"),
];

impl DataGrid {
    /// Follow the row numbers, the row height and the NULL text the
    /// preferences name, now and when one changes.
    pub(super) fn watch_display_settings(&self) {
        let Some(settings) = self.config().map(|config| config.settings.clone()) else {
            return;
        };
        let weak = self.downgrade();
        // Connected before the reads: GSettings emits `changed` only for a
        // key read while a handler was connected.
        let handler = settings.gio().connect_changed(None, move |_, key| {
            if matches!(
                key,
                keys::SHOW_ROW_NUMBERS | keys::GRID_ROW_HEIGHT | keys::NULL_DISPLAY | keys::DATE_FORMAT
            ) && let Some(grid) = weak.upgrade()
            {
                grid.apply_display_settings();
            }
        });
        self.imp()
            .display_watch
            .replace(Some(HandlerGuard::new(settings.gio(), handler)));
        self.apply_display_settings();
    }

    /// Read the three settings again and draw the grid by them.
    pub(super) fn apply_display_settings(&self) {
        let Some(settings) = self.config().map(|config| config.settings.clone()) else {
            return;
        };
        let view = self.column_view();
        let height = settings.grid_row_height();
        for (word, class) in HEIGHT_CLASSES {
            set_class(&view, class, word == height);
        }
        if let Some(numbers) = self.row_numbers_column() {
            numbers.set_visible(settings.show_row_numbers());
        }
        // The text is the app's to show, so every grid reads the same one.
        let null = settings.null_display();
        if crate::services::grid::display_text::null_display() != null {
            set_null_display(&null);
            self.redraw();
        }
        let dates = DateFormat::from_word(&settings.date_format());
        if date_format() != dates {
            set_date_format(dates);
            // A date's width changes with its spelling.
            self.fonts_changed();
            self.redraw();
        }
    }
}
