use gtk4 as gtk;
use gtk4::glib;
use libadwaita as adw;

use crate::ui::handler_guard::HandlerGuard;
use crate::ui::tab_load::StaleBanner;

pub(super) struct StructureTabWidgets {
    pub(super) inner_stack: gtk::Stack,
    /// The status page shown when the read fails, with the driver's
    /// error as its description.
    pub(super) error_status: adw::StatusPage,
    pub(super) stale_banner: StaleBanner,
    pub(super) name_entry: adw::EntryRow,
    /// The group around `name_entry`, visible only in New mode.
    pub(super) name_row: adw::PreferencesGroup,
    /// Blocked while the tab writes the draft's name into the entry,
    /// which is no edit.
    pub(super) name_changed: glib::SignalHandlerId,
    pub(super) columns_box: gtk::Box,
    pub(super) indexes_box: gtk::Box,
    pub(super) fks_box: gtk::Box,
    pub(super) add_column_row: adw::ButtonRow,
    pub(super) add_index_row: adw::ButtonRow,
    pub(super) add_fk_row: adw::ButtonRow,
    pub(super) sql_buffer: sourceview5::Buffer,
    pub(super) pending_label: gtk::Label,
    pub(super) save_button: gtk::Button,
    pub(super) discard_button: gtk::Button,
    pub(super) drop_button: gtk::Button,
    pub(super) saving_spinner: adw::Spinner,
    pub(super) stop_button: gtk::Button,
    /// The SQL preview follows the desktop theme through the app-wide
    /// style manager, which would keep the handler past the tab.
    pub(super) _theme_handler: HandlerGuard,
}
