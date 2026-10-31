use gtk4::gio;
use tablepro_session::SessionKey;

/// The window actions the tree's connection rows reach, each with the
/// session's key as its target.
pub(super) const SHOW_SESSION: &str = "win.show-session";
const NEW_QUERY_IN: &str = "win.new-query-in";
const REFRESH_IN: &str = "win.refresh-in";
pub(super) const DISCONNECT_SESSION: &str = "win.disconnect-session";
const STOP_CONNECTING: &str = "win.stop-connecting";
pub(super) const SHOW_CONNECT_FAILURE: &str = "win.show-connect-failure";
const FORGET_CONNECT_FAILURE: &str = "win.forget-connect-failure";

/// What a connection is doing in the window, which its menu leads with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum InWindow {
    Open,
    Connecting,
    /// Closed, `failed` when its last connect failed, `stored` while a
    /// saved connection names it.
    Closed {
        failed: bool,
        stored: bool,
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
            add(crate::i18n::gettext("_New Query"), NEW_QUERY_IN);
            add(crate::i18n::gettext("Re_fresh"), REFRESH_IN);
            add(crate::i18n::gettext("_Disconnect"), DISCONNECT_SESSION);
        }
        // A connect can wait for a host that never answers.
        InWindow::Connecting => add(crate::i18n::gettext("Stop _Connecting"), STOP_CONNECTING),
        InWindow::Closed { failed, stored } => {
            if stored && let SessionKey::Saved(id) = key {
                menu.append_item(&crate::ui::picker::connect_item(*id));
            }
            if failed {
                add(crate::i18n::gettext("S_how Error"), SHOW_CONNECT_FAILURE);
            }
            // Its row is only the failure's; nothing else removes it.
            if failed && !stored {
                add(crate::i18n::gettext("_Remove"), FORGET_CONNECT_FAILURE);
            }
        }
    }
    menu
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;
    use crate::test_support::assert_access_keys;

    #[test]
    fn every_state_keeps_the_access_keys_of_the_connections_menu_apart() {
        let id = Uuid::new_v4();
        let key = SessionKey::Saved(id);
        let stored = [
            InWindow::Open,
            InWindow::Connecting,
            InWindow::Closed {
                failed: true,
                stored: true,
            },
        ];

        for state in stored {
            assert_access_keys(&crate::ui::picker::connection_menu_with(
                &session_section(&key, state),
                id,
                &[],
                &[],
            ));
        }
        // No saved connection names this one, so the section is the menu.
        assert_access_keys(&session_section(
            &key,
            InWindow::Closed {
                failed: true,
                stored: false,
            },
        ));
    }
}
