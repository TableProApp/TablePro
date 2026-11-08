//! Marks for the spaces, tabs and line breaks of the value editor, which
//! macOS's "show invisible characters" grid setting turns on.

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use sourceview5::prelude::*;
use tablepro_linux_platform::settings::keys;

use super::RowDetailPane;
use crate::ui::handler_guard::HandlerGuard;

impl RowDetailPane {
    /// Follow the preference, now and when it changes.
    pub(super) fn watch_invisibles(&self, settings: &tablepro_linux_platform::AppSettings) {
        let weak = self.downgrade();
        let handler = settings
            .gio()
            .connect_changed(Some(keys::SHOW_INVISIBLE_CHARACTERS), move |_, _| {
                if let Some(pane) = weak.upgrade() {
                    pane.apply_invisibles();
                }
            });
        self.imp()
            .guards
            .borrow_mut()
            .push(HandlerGuard::new(settings.gio(), handler));
        self.apply_invisibles();
    }

    pub(super) fn apply_invisibles(&self) {
        let Some(grid) = self.grid() else {
            return;
        };
        let Some(config) = grid.config() else {
            return;
        };
        let drawer = self.imp().value_view.space_drawer();
        drawer.set_types_for_locations(
            sourceview5::SpaceLocationFlags::ALL,
            sourceview5::SpaceTypeFlags::SPACE
                | sourceview5::SpaceTypeFlags::TAB
                | sourceview5::SpaceTypeFlags::NEWLINE
                | sourceview5::SpaceTypeFlags::NBSP,
        );
        drawer.set_enable_matrix(config.settings.show_invisible_characters());
    }
}
