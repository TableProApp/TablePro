use gtk4::{gio, glib};
use tablepro_core::ddl::DatabaseNoun;
use tablepro_session::SessionKey;

use super::sidebar_affordances::SidebarAffordances;

/// The window actions the tree's connection rows reach, each with the
/// session's key as its target.
pub(super) const SHOW_SESSION: &str = "win.show-session";
const NEW_QUERY_IN: &str = "win.new-query-in";
const REFRESH_IN: &str = "win.refresh-in";
const OPEN_DATABASE_IN: &str = "win.open-database-in";
const NEW_DATABASE_IN: &str = "win.new-database-in";
const NEW_SCHEMA_IN: &str = "win.new-schema-in";
const DROP_DATABASE_IN: &str = "win.drop-database-in";
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
/// Connect for a saved connection, and the reason a connect failed. An
/// open session's `affordances` offer Open Database… on a saved
/// connection's own row whose catalog holds one database, New Database…
/// where the engine makes one, and Drop Database… on that row, which
/// picks among the server's databases, or on another database's row
/// beside it (0033).
pub(super) fn session_section(key: &SessionKey, state: InWindow, affordances: SidebarAffordances) -> gio::Menu {
    let target = crate::ui::session_target::to_variant(key);
    let menu = gio::Menu::new();
    let add = |label: String, action: &str| menu.append_item(&item(&label, action, &target));
    match state {
        InWindow::Open => {
            // Q, so New Database… can take N: each of its other letters is Disconnect's or the picker's.
            add(crate::i18n::gettext("New _Query"), NEW_QUERY_IN);
            add(crate::i18n::gettext("Re_fresh"), REFRESH_IN);
            if matches!(key, SessionKey::Saved(_)) && affordances.opens_databases {
                add(crate::i18n::gettext("_Open Database…"), OPEN_DATABASE_IN);
            }
            if affordances.offers_new_database() {
                let label = match affordances.catalog.database_noun {
                    DatabaseNoun::Database => crate::i18n::gettext("_New Database…"),
                    DatabaseNoun::Keyspace => crate::i18n::gettext("_New Keyspace…"),
                };
                add(label, NEW_DATABASE_IN);
            }
            // Here too, for a database whose every schema was dropped and so has no schema row.
            if affordances.offers_new_schema() {
                add(crate::i18n::gettext("New Sc_hema…"), NEW_SCHEMA_IN);
            }
            add(crate::i18n::gettext("_Disconnect"), DISCONNECT_SESSION);
            if drops_database(key, affordances) {
                let danger = gio::Menu::new();
                danger.append_item(&item(
                    &crate::i18n::gettext("Drop Data_base…"),
                    DROP_DATABASE_IN,
                    &target,
                ));
                menu.append_section(None, &danger);
            }
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

/// Whether the row of an open session offers Drop Database…. Only
/// engines whose connection holds one database open another beside it,
/// and a file holds no other.
fn drops_database(key: &SessionKey, affordances: SidebarAffordances) -> bool {
    let row = match key {
        SessionKey::Saved(_) => affordances.opens_databases,
        SessionKey::SavedIn { .. } => affordances.own_database_droppable,
        SessionKey::File(_) => false,
    };
    row && affordances.offers_drop_database()
}

fn item(label: &str, action: &str, target: &glib::Variant) -> gio::MenuItem {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(action), Some(target));
    item
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use tablepro_core::ddl::CatalogCapabilities;
    use tablepro_storage::{ConnectionList, ConnectionTag, SavedConnection};
    use uuid::Uuid;

    use super::*;
    use crate::services::library_outline::{LibraryOutline, LibrarySection};
    use crate::test_support::assert_access_keys;

    /// An engine that holds one database per connection and makes and
    /// drops them, as PostgreSQL does.
    fn databases() -> SidebarAffordances {
        SidebarAffordances {
            opens_databases: true,
            own_database_droppable: true,
            catalog: CatalogCapabilities {
                create_database: true,
                drop_database: true,
                create_schema: true,
                ..CatalogCapabilities::default()
            },
            ..SidebarAffordances::default()
        }
    }

    fn keyspaces() -> SidebarAffordances {
        let mut affordances = databases();
        affordances.opens_databases = false;
        affordances.lists_databases = true;
        affordances.catalog.database_noun = DatabaseNoun::Keyspace;
        affordances
    }

    /// Each item's action and target, sections flattened.
    fn items(menu: &gio::MenuModel) -> Vec<(String, Option<String>)> {
        let mut found = Vec::new();
        for index in 0..menu.n_items() {
            if let Some(action) = menu
                .item_attribute_value(index, "action", None)
                .and_then(|value| value.get::<String>())
            {
                let target = menu
                    .item_attribute_value(index, "target", None)
                    .and_then(|value| value.get::<String>());
                found.push((action, target));
            }
            if let Some(section) = menu.item_link(index, "section") {
                found.extend(items(&section));
            }
        }
        found
    }

    fn actions(menu: &gio::Menu) -> Vec<String> {
        items(menu.upcast_ref()).into_iter().map(|(action, _)| action).collect()
    }

    #[test]
    fn a_connection_that_makes_schemas_offers_one_without_a_schema_row() {
        let key = SessionKey::Saved(Uuid::new_v4());
        let schemas = SidebarAffordances {
            catalog: CatalogCapabilities {
                create_schema: true,
                ..CatalogCapabilities::default()
            },
            ..SidebarAffordances::default()
        };
        let read_only = SidebarAffordances {
            read_only: true,
            ..schemas
        };

        assert!(actions(&session_section(&key, InWindow::Open, schemas)).contains(&NEW_SCHEMA_IN.to_owned()));
        assert!(!actions(&session_section(&key, InWindow::Open, read_only)).contains(&NEW_SCHEMA_IN.to_owned()));
    }

    #[test]
    fn every_state_keeps_the_access_keys_of_the_connections_menu_apart() {
        let id = Uuid::new_v4();
        let key = SessionKey::Saved(id);
        let outline = LibraryOutline::new(&ConnectionList::new(
            Vec::<SavedConnection>::new(),
            Vec::<ConnectionTag>::new(),
        ));
        let stored = [
            InWindow::Open,
            InWindow::Connecting,
            InWindow::Closed {
                failed: true,
                stored: true,
            },
        ];

        for affordances in [databases(), keyspaces()] {
            for state in stored {
                assert_access_keys(&crate::ui::picker::connection_menu_with(
                    &session_section(&key, state, affordances),
                    id,
                    LibrarySection::Tree,
                    &outline,
                    &[],
                ));
            }
        }
        // No saved connection names this one, so the section is the menu.
        assert_access_keys(&session_section(
            &key,
            InWindow::Closed {
                failed: true,
                stored: false,
            },
            databases(),
        ));
        let beside = SessionKey::SavedIn {
            id,
            database: "shop".to_owned(),
        };
        assert_access_keys(&session_section(&beside, InWindow::Open, databases()));
    }

    #[test]
    fn a_new_database_is_offered_where_the_engine_makes_one_and_writes_are_allowed() {
        let key = SessionKey::Saved(Uuid::new_v4());
        let read_only = SidebarAffordances {
            read_only: true,
            ..databases()
        };
        let cannot = SidebarAffordances {
            catalog: CatalogCapabilities::default(),
            ..databases()
        };

        let offered = actions(&session_section(&key, InWindow::Open, databases()));
        let target = items(session_section(&key, InWindow::Open, databases()).upcast_ref())
            .into_iter()
            .find(|(action, _)| action == NEW_DATABASE_IN)
            .and_then(|(_, target)| target);

        assert!(offered.contains(&NEW_DATABASE_IN.to_owned()), "{offered:?}");
        assert_eq!(target, crate::ui::session_target::to_variant(&key).get::<String>());
        for affordances in [read_only, cannot] {
            let offered = actions(&session_section(&key, InWindow::Open, affordances));
            assert!(!offered.contains(&NEW_DATABASE_IN.to_owned()), "{offered:?}");
            assert!(!offered.contains(&DROP_DATABASE_IN.to_owned()), "{offered:?}");
        }
        assert!(
            !actions(&session_section(&key, InWindow::Connecting, databases())).contains(&NEW_DATABASE_IN.to_owned()),
            "a session still connecting"
        );
    }

    #[test]
    fn a_database_is_dropped_from_its_connections_row_or_its_own_beside_it() {
        let id = Uuid::new_v4();
        let own = SessionKey::Saved(id);
        let beside = SessionKey::SavedIn {
            id,
            database: "shop".to_owned(),
        };
        let kept = SidebarAffordances {
            own_database_droppable: false,
            ..databases()
        };
        let drops = |key: &SessionKey, affordances| {
            items(session_section(key, InWindow::Open, affordances).upcast_ref())
                .into_iter()
                .find(|(action, _)| action == DROP_DATABASE_IN)
                .map(|(_, target)| target)
        };

        assert_eq!(
            drops(&own, databases()),
            Some(crate::ui::session_target::to_variant(&own).get::<String>())
        );
        assert_eq!(
            drops(&beside, databases()),
            Some(crate::ui::session_target::to_variant(&beside).get::<String>())
        );
        assert_eq!(drops(&beside, kept), None, "a database the server keeps for itself");
        assert_eq!(
            drops(&own, keyspaces()),
            None,
            "a keyspace is dropped from its own row in the tree"
        );
        assert_eq!(
            drops(&SessionKey::File("file:///srv/shop.duckdb".to_owned()), databases()),
            None
        );
        assert_eq!(
            actions(&session_section(&beside, InWindow::Open, databases())),
            [
                NEW_QUERY_IN,
                REFRESH_IN,
                NEW_DATABASE_IN,
                NEW_SCHEMA_IN,
                DISCONNECT_SESSION,
                DROP_DATABASE_IN
            ]
        );
    }
}
