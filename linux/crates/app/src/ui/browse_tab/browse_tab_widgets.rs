use gtk4 as gtk;
use libadwaita as adw;

use super::pager_bar::PagerBar;
use super::pending_changes_bar::PendingChangesBar;
use crate::ui::tab_load::StaleBanner;

pub(super) struct BrowseTabWidgets {
    pub(super) inner_stack: gtk::Stack,
    pub(super) grid_holder: gtk::Box,
    pub(super) loading_page: adw::StatusPage,
    pub(super) error_page: adw::StatusPage,
    pub(super) stale_banner: StaleBanner,
    /// Banners are for states the user cannot clear by saving; pending
    /// edits show in the footer and the tab title instead.
    pub(super) read_only_banner: adw::Banner,
    pub(super) no_pk_banner: adw::Banner,
    pub(super) selection_label: gtk::Label,
    pub(super) filter_button: gtk::Button,
    pub(super) filter_badge: gtk::Label,
    pub(super) insert_button: gtk::Button,
    pub(super) delete_button: gtk::Button,
    pub(super) pager_bar: PagerBar,
    pub(super) pending_bar: PendingChangesBar,
}
