//! A saved connection's other databases, open beside it in the window
//! that holds it ([0030]). The connection's open session owns them: its
//! teardown takes them, and a database still opening holds its claim
//! there, so none outlives the connection or keeps its key claimed.
//!
//! [0030]: ../../../../../docs/decisions/0030-a-database-is-a-session-of-its-own.md

use std::sync::Arc;

use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::dialect::DatabaseLayout;
use tablepro_core::meta::SchemaInfo;
use tablepro_session::operation::OperationKind;
use tablepro_session::{ConnectError, Session, SessionClaim, SessionKey};
use tokio_util::sync::{CancellationToken, DropGuard};
use uuid::Uuid;

use super::session_page::OpenSession;
use super::{MovedTab, SessionWindow};
use crate::i18n::{gettext, gettext_f};
use crate::runtime::DeliverInput;
use crate::ui::error_text::{connect_error_message, operation_error_message};
use crate::ui::workspace::{Workspace, WorkspaceInput};

/// The response of the chooser that opens the database picked.
const OPEN: &str = "open";

#[derive(Default)]
pub(crate) struct OtherDatabases {
    pub(super) open: Vec<OpenSession>,
    opening: Vec<Opening>,
}

/// A database still opening. Dropping it stops the open and lets its
/// key go.
struct Opening {
    database: String,
    claim: SessionClaim,
    _stop: DropGuard,
}

impl OtherDatabases {
    /// The databases open or opening, by name.
    pub(super) fn names(&self) -> Vec<String> {
        let open = self.open.iter().filter_map(|open| match open.claim.key() {
            SessionKey::SavedIn { database, .. } => Some(database.clone()),
            SessionKey::Saved(_) | SessionKey::File(_) => None,
        });
        open.chain(self.opening.iter().map(|opening| opening.database.clone()))
            .collect()
    }

    /// Take the database open under `key` out of the connection.
    pub(super) fn take(&mut self, key: &SessionKey) -> Option<OpenSession> {
        let position = self.open.iter().position(|open| open.claim.key() == key)?;
        Some(self.open.remove(position))
    }

    /// Stop every open still running and hand back the databases open.
    pub(super) fn close(self) -> Vec<OpenSession> {
        drop(self.opening);
        self.open
    }

    fn take_opening(&mut self, database: &str) -> Option<SessionClaim> {
        let position = self.opening.iter().position(|opening| opening.database == database)?;
        Some(self.opening.remove(position).claim)
    }
}

/// The saved connection a session belongs to, its own or another of
/// its databases.
fn connection_of(key: &SessionKey) -> Option<Uuid> {
    match key {
        SessionKey::Saved(id) | SessionKey::SavedIn { id, .. } => Some(*id),
        SessionKey::File(_) => None,
    }
}

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
    /// Open the connection `id`'s database `database` beside it, with
    /// the stored secret and the connection's Safe Mode level. One open
    /// or opening already is left as it is.
    pub(crate) fn open_database(&self, id: Uuid, database: String) {
        let connection = SessionKey::Saved(id);
        let Some(state) = self.state() else {
            return;
        };
        let origin = self.find_open(|open| {
            let wanted = open.claim.key() == &connection
                && open.session.database() != Some(database.as_str())
                && !open.databases.names().contains(&database);
            wanted.then(|| open.session.clone())
        });
        let Some(origin) = origin else {
            return;
        };
        let Some(claim) = self.claim(SessionKey::SavedIn {
            id,
            database: database.clone(),
        }) else {
            return;
        };
        let stop = CancellationToken::new();
        {
            let mut sessions = self.imp().sessions.borrow_mut();
            let Some(open) = sessions.iter_mut().find(|open| open.claim.key() == &connection) else {
                return;
            };
            open.databases.opening.push(Opening {
                database: database.clone(),
                claim,
                _stop: stop.clone().drop_guard(),
            });
        }
        let opening = {
            let (database, origin) = (database.clone(), origin.clone());
            state
                .services
                .tasks
                .spawn_task(async move { origin.open_in_database(&database, stop).await })
        };
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            let opened = opening.await;
            match window.upgrade() {
                Some(window) => window.on_database_opened(id, &origin, database, opened),
                None => {
                    if let Ok(Ok(session)) = opened {
                        drop(session.begin_shutdown());
                    }
                }
            }
        });
    }

    /// The claim is still the connection's only while the session that
    /// asked holds it: a teardown, or a reconnect that replaced it,
    /// dropped the open with it.
    fn on_database_opened(
        &self,
        id: Uuid,
        origin: &Arc<Session>,
        database: String,
        opened: Result<Result<Arc<Session>, ConnectError>, tablepro_session::runtime::TaskFailure>,
    ) {
        let claim = self
            .imp()
            .sessions
            .borrow_mut()
            .iter_mut()
            .find(|open| open.claim.key() == &SessionKey::Saved(id) && Arc::ptr_eq(&open.session, origin))
            .and_then(|open| open.databases.take_opening(&database));
        match (claim, opened) {
            (Some(claim), Ok(Ok(session))) => {
                // A level picked once the open had read the connection's
                // went only to the databases already open.
                session.set_safe_mode(origin.safe_mode());
                self.join_database(id, claim, session);
            }
            (None, Ok(Ok(session))) => drop(session.begin_shutdown()),
            (Some(_), Ok(Err(error))) if !matches!(error, ConnectError::Cancelled) => {
                // A database restored at launch that no longer opens is
                // not tried again at the next one.
                self.forget_session(&SessionKey::SavedIn {
                    id,
                    database: database.clone(),
                });
                self.show_toast(&gettext_f(
                    "Could not open the database “{database}”: {error}",
                    &[("database", &database), ("error", &connect_error_message(&error))],
                ));
            }
            (_, Ok(Err(_))) => {}
            (_, Err(failure)) => tracing::warn!(%failure, "opening another database failed"),
        }
    }

    /// Build the database's workspace in the shell and give it to the
    /// connection's open session.
    fn join_database(&self, id: Uuid, claim: SessionClaim, session: Arc<Session>) {
        let Some(shell) = self.shell() else {
            drop(session.begin_shutdown());
            return;
        };
        claim.attach(&session);
        let key = claim.key().clone();
        let Some(workspace) = self.new_workspace(key.clone(), &session, &shell) else {
            drop(session.begin_shutdown());
            return;
        };
        let joined = session.clone();
        let others = {
            let mut sessions = self.imp().sessions.borrow_mut();
            let Some(connection) = sessions
                .iter_mut()
                .find(|open| open.claim.key() == &SessionKey::Saved(id))
            else {
                workspace.shutdown(true);
                drop(session.begin_shutdown());
                return;
            };
            let others: Vec<Workspace> = connection.with_databases().map(|open| open.workspace.clone()).collect();
            connection
                .databases
                .open
                .push(OpenSession::new(claim, session, workspace.clone()));
            others
        };
        self.remember_session(&key, None);
        self.render();
        shell.add_session(&workspace);
        workspace.start();
        self.sync_actions();
        // The connection's tabs in that database read its catalog now.
        for other in others {
            if let Some(input) = other.sender() {
                input.deliver(WorkspaceInput::DatabaseOpened(joined.clone()));
            }
        }
    }

    /// What an editor tab that moved to another database asks of the
    /// window.
    pub(super) fn on_moved_tab(&self, asked: MovedTab) {
        match asked {
            MovedTab::Follow { key, tab_id, database } => self.follow_database(&key, tab_id, database),
            MovedTab::Refresh { key, database } => self.refresh_database(&key, database),
        }
    }

    /// Editor tab `tab_id` of the session under `key` moved to
    /// `database`, `None` for the connection's own. Its completion reads
    /// the session the window holds for that database, opened beside
    /// the connection where a connection's catalog holds one database.
    fn follow_database(&self, key: &SessionKey, tab_id: Uuid, database: Option<String>) {
        // A tab of another database's own workspace keeps that catalog:
        // the connection's session may not know the name of its own.
        let SessionKey::Saved(id) = *key else {
            return;
        };
        if !self.opens_databases(id) {
            return;
        }
        let session = match self.holding(id, database.as_deref()) {
            // The tab's own workspace reads that catalog already.
            Some((held, _)) if &held == key => None,
            Some((_, session)) => Some(session),
            None => {
                if let Some(database) = database {
                    self.open_database(id, database);
                }
                return;
            }
        };
        self.deliver_to(key, WorkspaceInput::FollowCatalog { tab_id, session });
    }

    /// A tab of the session under `key` changed the catalog of
    /// `database`: the session holding it reads its catalog again.
    fn refresh_database(&self, key: &SessionKey, database: String) {
        let Some(id) = connection_of(key) else {
            return;
        };
        if let Some((held, _)) = self.holding(id, Some(&database)).filter(|(held, _)| held != key) {
            self.deliver_to(&held, WorkspaceInput::RefreshCatalog);
        }
    }

    /// The key and session the window holds for the connection `id`'s
    /// database `database`, `None` for its own.
    fn holding(&self, id: Uuid, database: Option<&str>) -> Option<(SessionKey, Arc<Session>)> {
        self.find_open(|open| {
            let holds = match (open.claim.key(), database) {
                (SessionKey::Saved(of), None) => *of == id,
                (SessionKey::Saved(of), Some(name)) => *of == id && open.session.database() == Some(name),
                (SessionKey::SavedIn { id: of, database: held }, Some(name)) => *of == id && held == name,
                (SessionKey::SavedIn { .. } | SessionKey::File(_), _) => false,
            };
            holds.then(|| (open.claim.key().clone(), open.session.clone()))
        })
    }

    /// Whether the connection `id`'s catalog holds only its own database,
    /// so another one needs a session of its own (0030).
    fn opens_databases(&self, id: Uuid) -> bool {
        self.held_session(&SessionKey::Saved(id))
            .and_then(|session| session.current_dialect())
            .is_some_and(|dialect| dialect.database_layout() == DatabaseLayout::WithSchemas)
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
        let listing = state.services.tasks.spawn_task(async move {
            session
                .run(OperationKind::Metadata, |lease, options| async move {
                    Ok(lease.list_databases(options).await?)
                })
                .await
        });
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
        let open = self
            .find_open(|open| (open.claim.key() == &SessionKey::Saved(id)).then(|| open.databases.names()))
            .unwrap_or_default();
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

    /// The session the window holds under `key`.
    pub(super) fn held_session(&self, key: &SessionKey) -> Option<Arc<Session>> {
        self.find_open(|open| (open.claim.key() == key).then(|| open.session.clone()))
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
