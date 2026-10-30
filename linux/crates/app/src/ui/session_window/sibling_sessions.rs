//! Another of a saved connection's databases, opened beside it in the
//! window that holds the connection ([0030]): a sibling session with a
//! workspace and a sidebar branch of its own, as the connection has.
//!
//! [0030]: ../../../../../docs/decisions/0030-a-database-is-a-session-of-its-own.md

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::meta::SchemaInfo;
use tablepro_session::operation::OperationKind;
use tablepro_session::{Session, SessionKey};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use super::SessionWindow;
use crate::i18n::{gettext, gettext_f};
use crate::runtime::DeliverInput;
use crate::ui::error_text::{connect_error_message, operation_error_message};
use crate::ui::workspace::WorkspaceInput;

/// The response of the chooser that opens the database picked.
const OPEN: &str = "open";

/// The databases to offer: neither the connection's own nor one open
/// already, the user's first and the server's own after, as the editor
/// bar's menu lists them.
pub(super) fn offered(databases: &[SchemaInfo], open: &[String]) -> Vec<String> {
    let mut offered: Vec<&SchemaInfo> = databases
        .iter()
        .filter(|database| !database.is_default && !open.contains(&database.name))
        .collect();
    offered.sort_by_key(|database| database.is_system);
    offered.into_iter().map(|database| database.name.clone()).collect()
}

impl SessionWindow {
    /// Open the connection `id`'s database `database` beside it. One open
    /// already is left as it is; so is a connection this window does not
    /// hold, whose window opens its own.
    pub(crate) fn open_database(&self, id: Uuid, database: String) {
        self.open_database_then(id, database, |_, _| {});
    }

    /// Open the database as `open_database` does, then call `then` with
    /// its session, at once when it is open already.
    fn open_database_then(
        &self,
        id: Uuid,
        database: String,
        then: impl FnOnce(&SessionWindow, Arc<Session>) + 'static,
    ) {
        let key = SessionKey::SavedIn {
            id,
            database: database.clone(),
        };
        if let Some(session) = self.held_session(&key) {
            then(self, session);
            return;
        }
        let (Some(origin), Some(state)) = (self.held_session(&SessionKey::Saved(id)), self.state()) else {
            return;
        };
        if origin.database() == Some(database.as_str()) {
            return;
        }
        let Some(claim) = self.claim(key) else {
            return;
        };
        let opening = {
            let (database, origin) = (database.clone(), origin.clone());
            state
                .services
                .tasks
                .spawn_task(async move { origin.open_in_database(&database, CancellationToken::new()).await })
        };
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let opened = opening.await;
            // A database goes with the connection it opened from, which may
            // have gone, or been opened again, while it opened.
            let window = window.upgrade().filter(|window| {
                window
                    .held_session(&SessionKey::Saved(id))
                    .is_some_and(|now| Arc::ptr_eq(&now, &origin))
            });
            let Some(window) = window else {
                if let Ok(Ok(session)) = opened {
                    drop(session.begin_shutdown());
                }
                return;
            };
            match opened {
                Ok(Ok(session)) => {
                    window.join(claim, session.clone(), &[]);
                    then(&window, session);
                }
                Ok(Err(error)) => window.show_toast(&gettext_f(
                    "Could not open the database “{database}”: {error}",
                    &[("database", &database), ("error", &connect_error_message(&error))],
                )),
                Err(failure) => {
                    tracing::warn!(%failure, "opening another database failed");
                }
            }
        });
    }

    /// Open Database…: list the server's databases, then ask which to
    /// open beside the connection under `key`.
    pub(super) fn choose_database_in(&self, key: SessionKey) {
        let SessionKey::Saved(id) = key else {
            return;
        };
        let (Some(session), Some(state)) = (self.held_session(&key), self.state()) else {
            return;
        };
        let listing = {
            let session = session.clone();
            state.services.tasks.spawn_task(async move {
                session
                    .run(OperationKind::Metadata, |lease, options| async move {
                        Ok(lease.list_databases(options).await?)
                    })
                    .await
            })
        };
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let listed = listing.await;
            let Some(window) = window.upgrade() else {
                return;
            };
            match listed {
                Ok(Ok(databases)) => window.ask_database(id, &databases),
                Ok(Err(error)) => window.show_toast(&operation_error_message(&error)),
                Err(failure) => tracing::warn!(%failure, "listing the server's databases failed"),
            }
        });
    }

    fn ask_database(&self, id: Uuid, databases: &[SchemaInfo]) {
        let open: Vec<String> = self
            .imp()
            .sessions
            .borrow()
            .iter()
            .filter_map(|open| match open.claim.key() {
                SessionKey::SavedIn { id: of, database } if *of == id => Some(database.clone()),
                _ => None,
            })
            .collect();
        let names = offered(databases, &open);
        if names.is_empty() {
            self.show_toast(&gettext("No other database of this server to open"));
            return;
        }
        let strings: Vec<&str> = names.iter().map(String::as_str).collect();
        let choice = gtk::DropDown::from_strings(&strings);
        choice.update_property(&[gtk::accessible::Property::Label(&gettext("Database"))]);
        let dialog = adw::AlertDialog::builder()
            .heading(gettext("Open Database"))
            .body(gettext(
                "It opens beside the connection, with tables and tabs of its own.",
            ))
            .extra_child(&choice)
            .default_response(OPEN)
            .close_response("cancel")
            .build();
        dialog.add_responses(&[("cancel", &gettext("Cancel")), (OPEN, &gettext("Open"))]);
        dialog.set_response_appearance(OPEN, adw::ResponseAppearance::Suggested);
        let window = self.downgrade();
        dialog.connect_response(None, move |_, response| {
            let picked = usize::try_from(choice.selected())
                .ok()
                .and_then(|at| names.get(at))
                .cloned();
            if let (OPEN, Some(window), Some(database)) = (response, window.upgrade(), picked) {
                window.open_database(id, database);
            }
        });
        dialog.present(Some(self));
    }

    /// An editor tab of the session under `key` moved to `database`: open
    /// or reach that database's session, hand it to the tab's completion,
    /// and select its row, as the macOS window follows the tab (0030). Back
    /// on the connection's own database the tab reads the connection's.
    pub(super) fn follow_database(&self, key: &SessionKey, tab_id: Uuid, database: String) {
        let SessionKey::Saved(id) = *key else {
            return;
        };
        let Some(origin) = self.held_session(key) else {
            return;
        };
        if database.is_empty() || origin.database() == Some(database.as_str()) {
            self.hand_over(id, tab_id, None, key);
            return;
        }
        let row = SessionKey::SavedIn {
            id,
            database: database.clone(),
        };
        self.open_database_then(id, database, move |window, session| {
            window.hand_over(id, tab_id, Some(session), &row);
        });
    }

    /// Give the connection `id`'s editor tab `tab_id` the catalog of
    /// `session`, and select `row` in the sidebar.
    fn hand_over(&self, id: Uuid, tab_id: Uuid, session: Option<Arc<Session>>, row: &SessionKey) {
        if let Some(sender) = self
            .session_workspace(&SessionKey::Saved(id))
            .and_then(|workspace| workspace.sender())
        {
            sender.deliver(WorkspaceInput::FollowCatalog { tab_id, session });
        }
        if let Some(tree) = self.shell().and_then(|shell| shell.tree()) {
            tree.select(Some(row), None);
        }
    }

    /// The keys of the connection `id`'s other open databases.
    pub(super) fn siblings_of(&self, id: Uuid) -> Vec<SessionKey> {
        self.imp()
            .sessions
            .borrow()
            .iter()
            .map(|open| open.claim.key().clone())
            .filter(|key| matches!(key, SessionKey::SavedIn { id: of, .. } if *of == id))
            .collect()
    }

    /// The session the window holds under `key`.
    pub(super) fn held_session(&self, key: &SessionKey) -> Option<Arc<Session>> {
        let sessions = self.imp().sessions.try_borrow().ok()?;
        sessions
            .iter()
            .find(|open| open.claim.key() == key)
            .map(|open| open.session.clone())
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::SchemaInfo;

    use super::offered;

    fn database(name: &str, is_default: bool, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default,
            is_system,
        }
    }

    #[test]
    fn the_chooser_offers_the_other_databases_the_users_first() {
        let databases = [
            database("mysql", false, true),
            database("shop", true, false),
            database("analytics", false, false),
            database("archive", false, false),
        ];

        assert_eq!(
            offered(&databases, &["archive".to_owned()]),
            ["analytics", "mysql"],
            "neither the connection's own nor one open already"
        );
    }
}
