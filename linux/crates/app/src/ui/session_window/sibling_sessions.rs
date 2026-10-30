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
    /// or opening already is left as it is; so is a connection this window
    /// does not hold, whose window opens its own.
    pub(crate) fn open_database(&self, id: Uuid, database: String) {
        let key = SessionKey::SavedIn {
            id,
            database: database.clone(),
        };
        if self.held_session(&key).is_some() || self.imp().opening_databases.borrow().contains_key(&key) {
            return;
        }
        let (Some(origin), Some(state)) = (self.held_session(&SessionKey::Saved(id)), self.state()) else {
            return;
        };
        if origin.database() == Some(database.as_str()) {
            return;
        }
        let Some(claim) = self.claim(key.clone()) else {
            return;
        };
        let cancel = CancellationToken::new();
        self.imp()
            .opening_databases
            .borrow_mut()
            .insert(key.clone(), cancel.clone());
        let opening = {
            let (database, origin, cancel) = (database.clone(), origin.clone(), cancel.clone());
            state
                .services
                .tasks
                .spawn_task(async move { origin.open_in_database(&database, cancel).await })
        };
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let opened = opening.await;
            // One stopped with its connection was taken off the list then,
            // and one under the same name since is another's.
            if !cancel.is_cancelled()
                && let Some(window) = window.upgrade()
            {
                window.imp().opening_databases.borrow_mut().remove(&key);
            }
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
                    window.remember_session(claim.key(), None);
                    window.join(claim, session.clone(), &[]);
                    window.hand_out(id, &session);
                }
                Ok(Err(error)) => {
                    // As a connection that no longer opens, a database
                    // restored at launch is not tried again at the next.
                    window.forget_session(claim.key());
                    window.show_toast(&gettext_f(
                        "Could not open the database “{database}”: {error}",
                        &[("database", &database), ("error", &connect_error_message(&error))],
                    ));
                }
                Err(failure) => {
                    tracing::warn!(%failure, "opening another database failed");
                }
            }
        });
    }

    /// Give the connection `id`'s query tabs in `session`'s database its
    /// catalog, a tab moved there while it opened or before it reopened
    /// included.
    fn hand_out(&self, id: Uuid, session: &Arc<Session>) {
        let workspaces: Vec<_> = self
            .imp()
            .sessions
            .borrow()
            .iter()
            .filter(|open| matches!(open.claim.key(), SessionKey::Saved(of) | SessionKey::SavedIn { id: of, .. } if *of == id))
            .map(|open| open.workspace.clone())
            .collect();
        for workspace in workspaces {
            if let Some(sender) = workspace.sender() {
                sender.deliver(WorkspaceInput::DatabaseOpened(session.clone()));
            }
        }
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

    /// An editor tab of the session under `key` moved to `database`: hand
    /// its completion that database's session, the connection's or one
    /// beside it, opening that one first (0030). Back on its own session's
    /// database the tab reads that session's catalog.
    pub(super) fn follow_database(&self, key: &SessionKey, tab_id: Uuid, database: String) {
        let id = match key {
            SessionKey::Saved(id) | SessionKey::SavedIn { id, .. } => *id,
            SessionKey::File(_) => return,
        };
        let Some(parent) = self.held_session(&SessionKey::Saved(id)) else {
            return;
        };
        let sibling = SessionKey::SavedIn {
            id,
            database: database.clone(),
        };
        if database.is_empty() {
            self.hand_over(key, tab_id, None);
        } else if parent.database() == Some(database.as_str()) {
            self.hand_over(key, tab_id, Some(parent));
        } else if let Some(session) = self.held_session(&sibling) {
            self.hand_over(key, tab_id, Some(session));
        } else {
            // Its session hands itself to the tab once it joins.
            self.open_database(id, database);
        }
    }

    fn hand_over(&self, from: &SessionKey, tab_id: Uuid, session: Option<Arc<Session>>) {
        if let Some(sender) = self.session_workspace(from).and_then(|workspace| workspace.sender()) {
            sender.deliver(WorkspaceInput::FollowCatalog { tab_id, session });
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
