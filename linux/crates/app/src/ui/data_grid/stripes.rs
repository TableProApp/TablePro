use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use tablepro_storage::settings::keys;

use super::DataGrid;
use super::grid_cell::set_class;
use crate::ui::handler_guard::HandlerGuard;

const STRIPE: &str = "tp-stripe";
const STRIPED: &str = "tp-striped";

// Rows are recycled, so `:nth-child` cannot stripe them and GTK has no API
// to class a row: each cell's child follows its row's position instead.
pub(super) fn follow(cell: &gtk::ColumnViewCell) {
    cell.connect_notify_local(Some("position"), |cell, _| {
        if let Some(child) = cell.child() {
            let position = cell.position();
            let odd = position != gtk::INVALID_LIST_POSITION && !position.is_multiple_of(2);
            set_class(&child, STRIPE, odd);
        }
    });
}

impl DataGrid {
    pub(super) fn watch_stripes(&self) {
        let Some(settings) = self.config().map(|config| config.settings.clone()) else {
            return;
        };
        let view = self.column_view();
        // Connected before the read: GSettings emits `changed` only for a key
        // read while a handler was connected.
        let handler = settings.gio().connect_changed(
            Some(keys::SHOW_ALTERNATE_ROWS),
            glib::clone!(
                #[weak]
                view,
                move |settings, key| set_class(&view, STRIPED, settings.boolean(key))
            ),
        );
        self.imp()
            .stripes_watch
            .replace(Some(HandlerGuard::new(settings.gio(), handler)));
        set_class(&view, STRIPED, settings.show_alternate_rows());
    }
}
