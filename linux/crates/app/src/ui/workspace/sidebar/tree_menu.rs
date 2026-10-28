use gtk4::gio;
use tablepro_session::SessionKey;

/// The window actions the tree's connection rows reach, each with the
/// session's key as its target.
pub(super) const SHOW_SESSION: &str = "win.show-session";
const NEW_QUERY_IN: &str = "win.new-query-in";
const REFRESH_IN: &str = "win.refresh-in";
pub(super) const DISCONNECT_SESSION: &str = "win.disconnect-session";
const STOP_CONNECTING: &str = "win.stop-connecting";
const SHOW_CONNECT_FAILURE: &str = "win.show-connect-failure";

/// What a connection is doing in the window, which its menu leads with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum InWindow {
    Open,
    Connecting,
    /// Closed, `failed` when its last connect failed.
    Closed {
        failed: bool,
    },
}

/// The connection's menu section for the window: the session's own
/// actions while it is open, Stop Connecting while it connects, else
/// Connect for a saved connection, and the reason a connect failed.
pub(super) fn session_section(key: &SessionKey, state: InWindow) -> gio::Menu {
    let target = crate::ui::session_target::to_variant(key);
    let menu = gio::Menu::new();
    let add = |label: String, action: &str| {
        let item = gio::MenuItem::new(Some(&label), None);
        item.set_action_and_target_value(Some(action), Some(&target));
        menu.append_item(&item);
    };
    match state {
        InWindow::Open => {
            add(crate::i18n::gettext("New Query"), NEW_QUERY_IN);
            add(crate::i18n::gettext("Refresh"), REFRESH_IN);
            add(crate::i18n::gettext("Disconnect"), DISCONNECT_SESSION);
        }
        // A connect can wait for a host that never answers.
        InWindow::Connecting => add(crate::i18n::gettext("Stop Connecting"), STOP_CONNECTING),
        InWindow::Closed { failed } => {
            if let SessionKey::Saved(id) = key {
                menu.append_item(&crate::ui::picker::connect_item(*id));
            }
            if failed {
                add(crate::i18n::gettext("Show Error"), SHOW_CONNECT_FAILURE);
            }
        }
    }
    menu
}
