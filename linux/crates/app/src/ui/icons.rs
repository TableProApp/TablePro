//! Every icon name the app asks the icon theme for. Keeping them in
//! one place is what lets `all_icons_resolve` prove the set is real.

pub const DIALOG_ERROR: &str = "dialog-error-symbolic";
pub const DIALOG_WARNING: &str = "dialog-warning-symbolic";
pub const DOCUMENT_OPEN: &str = "document-open-symbolic";
pub const DOCUMENT_OPEN_RECENT: &str = "document-open-recent-symbolic";
pub const DOCUMENT_SAVE: &str = "document-save-symbolic";
pub const EDIT_COPY: &str = "edit-copy-symbolic";
pub const GO_FIRST: &str = "go-first-symbolic";
pub const GO_LAST: &str = "go-last-symbolic";
pub const GO_NEXT: &str = "go-next-symbolic";
pub const GO_PREVIOUS: &str = "go-previous-symbolic";
pub const LIST_ADD: &str = "list-add-symbolic";
pub const MEDIA_PLAYBACK_STOP: &str = "media-playback-stop-symbolic";
pub const NETWORK_SERVER: &str = "network-server-symbolic";
pub const OPEN_MENU: &str = "open-menu-symbolic";
pub const PAN_DOWN: &str = "pan-down-symbolic";
pub const PREFERENCES_SYSTEM: &str = "preferences-system-symbolic";
pub const PROCESS_STOP: &str = "process-stop-symbolic";
pub const STATEMENT_PENDING: &str = "statement-pending-symbolic";
pub const SUCCESS: &str = "object-select-symbolic";
pub const SYSTEM_SEARCH: &str = "system-search-symbolic";
pub const TABLE_RELATION: &str = "table-relation-symbolic";
pub const TAB_NEW: &str = "tab-new-symbolic";
pub const TEXT_EDITOR: &str = "text-editor-symbolic";
pub const TEXT_X_GENERIC: &str = "text-x-generic-symbolic";
pub const USER_TRASH: &str = "user-trash-symbolic";
pub const VIEW_GRID: &str = "view-grid-symbolic";
pub const VIEW_LIST: &str = "view-list-symbolic";
pub const VIEW_MORE: &str = "view-more-symbolic";
pub const VIEW_PIN: &str = "view-pin-symbolic";
pub const VIEW_SORT_ASCENDING: &str = "view-sort-ascending-symbolic";
pub const WINDOW_CLOSE: &str = "window-close-symbolic";

#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "the app uses the individual constants; ALL exists so all_icons_resolve can check the whole set"
    )
)]
pub const ALL: &[&str] = &[
    DIALOG_ERROR,
    DIALOG_WARNING,
    DOCUMENT_OPEN,
    DOCUMENT_OPEN_RECENT,
    DOCUMENT_SAVE,
    EDIT_COPY,
    GO_FIRST,
    GO_LAST,
    GO_NEXT,
    GO_PREVIOUS,
    LIST_ADD,
    MEDIA_PLAYBACK_STOP,
    NETWORK_SERVER,
    OPEN_MENU,
    PAN_DOWN,
    PREFERENCES_SYSTEM,
    PROCESS_STOP,
    STATEMENT_PENDING,
    SUCCESS,
    SYSTEM_SEARCH,
    TABLE_RELATION,
    TAB_NEW,
    TEXT_EDITOR,
    TEXT_X_GENERIC,
    USER_TRASH,
    VIEW_GRID,
    VIEW_LIST,
    VIEW_MORE,
    VIEW_PIN,
    VIEW_SORT_ASCENDING,
    WINDOW_CLOSE,
];

#[cfg(test)]
mod tests {
    use super::*;

    /// A name the icon theme cannot resolve renders as a blank square at
    /// runtime with no warning, so the whole set is checked here.
    #[gtk4::test]
    fn all_icons_resolve() {
        crate::register_test_resources();
        let display = gtk4::gdk::Display::default().expect("a display under the test backend");
        let theme = gtk4::IconTheme::for_display(&display);
        theme.add_resource_path(&format!("{}/icons", crate::config::RESOURCE_BASE_PATH));

        let missing: Vec<&str> = ALL.iter().copied().filter(|name| !theme.has_icon(name)).collect();

        assert!(missing.is_empty(), "the icon theme cannot resolve {missing:?}");
    }

    #[test]
    fn no_removed_emblem_icons_remain() {
        for name in ALL {
            assert!(
                !name.starts_with("emblem-"),
                "{name} was removed from adwaita-icon-theme"
            );
        }
    }
}
