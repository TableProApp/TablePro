//! Every icon name the app asks the icon theme for. Keeping them in
//! one place is what lets `all_icons_resolve` prove the set is real.

pub const ACTION_UNAVAILABLE: &str = "action-unavailable-symbolic";
pub const APPLICATIONS_ENGINEERING: &str = "applications-engineering-symbolic";
pub const APPLICATIONS_SCIENCE: &str = "applications-science-symbolic";
/// Bundled: a speech bubble, for the AI assistant.
pub const ASSISTANT: &str = "assistant-symbolic";
pub const CHANGES_PREVENT: &str = "changes-prevent-symbolic";
pub const COMPUTER: &str = "computer-symbolic";
pub const DIALOG_ERROR: &str = "dialog-error-symbolic";
pub const DIALOG_WARNING: &str = "dialog-warning-symbolic";
pub const DOCUMENT_EDIT: &str = "document-edit-symbolic";
/// Not in Adwaita; the app's resources carry it, as GNOME Text Editor's do.
pub const DOCUMENT_MODIFIED: &str = "document-modified-symbolic";
pub const DOCUMENT_OPEN: &str = "document-open-symbolic";
pub const DOCUMENT_OPEN_RECENT: &str = "document-open-recent-symbolic";
pub const DOCUMENT_SAVE: &str = "document-save-symbolic";
pub const DRIVE_HARDDISK: &str = "drive-harddisk-symbolic";
pub const EDIT_CLEAR: &str = "edit-clear-symbolic";
pub const EDIT_COPY: &str = "edit-copy-symbolic";
pub const EDIT_DELETE: &str = "edit-delete-symbolic";
pub const EDIT_FIND_REPLACE: &str = "edit-find-replace-symbolic";
pub const FOLDER: &str = "folder-symbolic";
pub const GO_DOWN: &str = "go-down-symbolic";
pub const GO_FIRST: &str = "go-first-symbolic";
pub const GO_LAST: &str = "go-last-symbolic";
pub const GO_NEXT: &str = "go-next-symbolic";
pub const GO_PREVIOUS: &str = "go-previous-symbolic";
pub const GO_UP: &str = "go-up-symbolic";
pub const LIST_ADD: &str = "list-add-symbolic";
pub const LIST_REMOVE: &str = "list-remove-symbolic";
pub const MEDIA_PLAYBACK_STOP: &str = "media-playback-stop-symbolic";
pub const NETWORK_ERROR: &str = "network-error-symbolic";
pub const NETWORK_SERVER: &str = "network-server-symbolic";
pub const OPEN_MENU: &str = "open-menu-symbolic";
pub const PACKAGE: &str = "package-x-generic-symbolic";
pub const PAN_DOWN: &str = "pan-down-symbolic";
pub const PREFERENCES_SYSTEM: &str = "preferences-system-symbolic";
pub const PROCESS_STOP: &str = "process-stop-symbolic";
pub const SECURITY_HIGH: &str = "security-high-symbolic";
pub const STARRED: &str = "starred-symbolic";
pub const STATEMENT_PENDING: &str = "statement-pending-symbolic";
pub const SIDEBAR_SHOW: &str = "sidebar-show-symbolic";
/// Not in Adwaita; GtkSourceView installs it, for its own snippet
/// completion.
pub const SNIPPET: &str = "completion-snippet-symbolic";
pub const SUCCESS: &str = "object-select-symbolic";
pub const SYSTEM_RUN: &str = "system-run-symbolic";
pub const SYSTEM_SEARCH: &str = "system-search-symbolic";
pub const TABLE_RELATION: &str = "table-relation-symbolic";
pub const TAB_NEW: &str = "tab-new-symbolic";
pub const TEXT_EDITOR: &str = "text-editor-symbolic";
pub const TEXT_X_GENERIC: &str = "text-x-generic-symbolic";
pub const USER_HOME: &str = "user-home-symbolic";
pub const USER_TRASH: &str = "user-trash-symbolic";
pub const UTILITIES_TERMINAL: &str = "utilities-terminal-symbolic";
pub const VIEW_GRID: &str = "view-grid-symbolic";
pub const VIEW_LIST: &str = "view-list-symbolic";
pub const VIEW_MORE: &str = "view-more-symbolic";
pub const VIEW_PAGED: &str = "view-paged-symbolic";
pub const VIEW_PIN: &str = "view-pin-symbolic";
pub const VIEW_REFRESH: &str = "view-refresh-symbolic";
pub const VIEW_REVEAL: &str = "view-reveal-symbolic";
pub const VIEW_SORT_ASCENDING: &str = "view-sort-ascending-symbolic";
pub const WEATHER_OVERCAST: &str = "weather-overcast-symbolic";
pub const WEB_BROWSER: &str = "web-browser-symbolic";
pub const WINDOW_CLOSE: &str = "window-close-symbolic";
pub const ZOOM_FIT_BEST: &str = "zoom-fit-best-symbolic";
pub const ZOOM_IN: &str = "zoom-in-symbolic";
pub const ZOOM_OUT: &str = "zoom-out-symbolic";

#[cfg_attr(
    not(test),
    expect(
        dead_code,
        reason = "the app uses the individual constants; ALL exists so all_icons_resolve can check the whole set"
    )
)]
pub const ALL: &[&str] = &[
    ACTION_UNAVAILABLE,
    APPLICATIONS_ENGINEERING,
    APPLICATIONS_SCIENCE,
    ASSISTANT,
    CHANGES_PREVENT,
    COMPUTER,
    DIALOG_ERROR,
    DIALOG_WARNING,
    DOCUMENT_EDIT,
    DOCUMENT_MODIFIED,
    DOCUMENT_OPEN,
    DOCUMENT_OPEN_RECENT,
    DOCUMENT_SAVE,
    DRIVE_HARDDISK,
    EDIT_CLEAR,
    EDIT_COPY,
    EDIT_DELETE,
    EDIT_FIND_REPLACE,
    FOLDER,
    GO_DOWN,
    GO_FIRST,
    GO_LAST,
    GO_NEXT,
    GO_PREVIOUS,
    GO_UP,
    LIST_ADD,
    LIST_REMOVE,
    MEDIA_PLAYBACK_STOP,
    NETWORK_ERROR,
    NETWORK_SERVER,
    OPEN_MENU,
    PACKAGE,
    PAN_DOWN,
    PREFERENCES_SYSTEM,
    PROCESS_STOP,
    SECURITY_HIGH,
    SIDEBAR_SHOW,
    SNIPPET,
    STARRED,
    STATEMENT_PENDING,
    SUCCESS,
    SYSTEM_RUN,
    SYSTEM_SEARCH,
    TABLE_RELATION,
    TAB_NEW,
    TEXT_EDITOR,
    TEXT_X_GENERIC,
    USER_HOME,
    USER_TRASH,
    UTILITIES_TERMINAL,
    VIEW_GRID,
    VIEW_LIST,
    VIEW_MORE,
    VIEW_PAGED,
    VIEW_PIN,
    VIEW_REFRESH,
    VIEW_REVEAL,
    VIEW_SORT_ASCENDING,
    WEATHER_OVERCAST,
    WEB_BROWSER,
    WINDOW_CLOSE,
    ZOOM_FIT_BEST,
    ZOOM_IN,
    ZOOM_OUT,
];

/// The theme's icon for each icon a connection can carry.
pub fn connection_icon(icon: tablepro_storage::ConnectionIcon) -> &'static str {
    use tablepro_storage::ConnectionIcon;
    match icon {
        ConnectionIcon::Server => NETWORK_SERVER,
        ConnectionIcon::Computer => COMPUTER,
        ConnectionIcon::Disk => DRIVE_HARDDISK,
        ConnectionIcon::Folder => FOLDER,
        ConnectionIcon::Home => USER_HOME,
        ConnectionIcon::Cloud => WEATHER_OVERCAST,
        ConnectionIcon::Web => WEB_BROWSER,
        ConnectionIcon::Terminal => UTILITIES_TERMINAL,
        ConnectionIcon::Package => PACKAGE,
        ConnectionIcon::Lab => APPLICATIONS_SCIENCE,
        ConnectionIcon::Tools => APPLICATIONS_ENGINEERING,
        ConnectionIcon::Star => STARRED,
        ConnectionIcon::Warning => DIALOG_WARNING,
        ConnectionIcon::Shield => SECURITY_HIGH,
        ConnectionIcon::Lock => CHANGES_PREVENT,
    }
}

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
    fn every_connection_icon_is_one_the_set_checks_and_none_repeats() {
        let names: std::collections::HashSet<&str> = tablepro_storage::ConnectionIcon::ALL
            .into_iter()
            .map(connection_icon)
            .collect();

        assert_eq!(names.len(), tablepro_storage::ConnectionIcon::ALL.len());
        for name in names {
            assert!(
                ALL.contains(&name),
                "{name} is not in ALL, so nothing checks it resolves"
            );
        }
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
