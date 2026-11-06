//! A saved connection's other databases, open beside it in the window
//! that holds it ([0030]). The connection's open session owns them: its
//! teardown takes them, and a database still opening holds its claim
//! there, so none outlives the connection or keeps its key claimed.
//!
//! [0030]: ../../../../../docs/decisions/0030-a-database-is-a-session-of-its-own.md

use std::sync::Arc;

use futures::FutureExt;
use futures::channel::oneshot;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{self as gtk, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::ddl::DropDatabaseOptions;
use tablepro_core::dialect::DatabaseLayout;
use tablepro_core::meta::SchemaInfo;
use tablepro_session::operation::OperationKind;
use tablepro_session::{ConnectError, Session, SessionClaim, SessionKey};
use tokio_util::sync::{CancellationToken, DropGuard};
use uuid::Uuid;

use super::session_page::OpenSession;
use super::session_teardown::SessionClosing;
use super::{MovedTab, SessionWindow};
use crate::i18n::{gettext, gettext_f};
use crate::runtime::DeliverInput;
use crate::ui::error_text::{connect_error_message, operation_error_message};
use crate::ui::workspace::{DatabaseDrop, Workspace, WorkspaceInput};
use crate::workspace::CloseDecision;

/// The response of the chooser that opens the database picked.
const OPEN: &str = "open";
/// The response of the chooser that goes on to ask about dropping the
/// database picked.
const CONTINUE: &str = "continue";

/// What a chooser of the server's databases asks.
struct Chooser {
    heading: String,
    body: String,
    response: &'static str,
    label: String,
}

/// A drop a session asked for, held until the window has let go of the
/// database.
struct Release {
    target: DatabaseDrop,
    options: DropDatabaseOptions,
}

impl Release {
    /// Only the session that confirmed the drop gets it back. One that
    /// went meanwhile took the drop's hold on the database with it.
    fn hand_back(self, window: &SessionWindow) {
        let workspace = window.find_open(|open| {
            (open.claim.key() == &self.target.key && self.target.confirmed_by(&open.session))
                .then(|| open.workspace.clone())
        });
        match workspace.and_then(|workspace| workspace.sender()) {
            Some(input) => input.deliver(WorkspaceInput::DropDatabaseReleased {
                target: self.target,
                options: self.options,
            }),
            None => tracing::debug!("the session that asked to drop a database is gone, so nothing is dropped"),
        }
    }
}

#[derive(Default)]
pub(crate) struct OtherDatabases {
    pub(super) open: Vec<OpenSession>,
    opening: Vec<Opening>,
    /// Databases on their way to a drop, which nothing opens until it
    /// ends. They go with the connection's session.
    dropping: Vec<String>,
}

/// A database still opening. Dropping it stops the open and lets its
/// key go.
struct Opening {
    database: String,
    claim: SessionClaim,
    _stop: DropGuard,
    /// Answers once the open has ended and closed what a stopped open
    /// still connected.
    settled: oneshot::Receiver<()>,
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

    /// Take the open of `database` out, which stops it once dropped.
    fn stop_opening(&mut self, database: &str) -> Option<Opening> {
        let position = self.opening.iter().position(|opening| opening.database == database)?;
        Some(self.opening.remove(position))
    }

    fn reserve(&mut self, database: &str) {
        if !self.is_dropping(database) {
            self.dropping.push(database.to_owned());
        }
    }

    fn lift(&mut self, database: &str) {
        self.dropping.retain(|name| name != database);
    }

    fn is_dropping(&self, database: &str) -> bool {
        self.dropping.iter().any(|name| name == database)
    }
}

fn shut_down(session: Arc<Session>) -> SessionClosing {
    session.begin_shutdown().map(drop).boxed_local()
}

/// Whether `key` is a session of the connection `of` is, or `of` itself
/// where it names no saved connection.
fn same_connection(key: &SessionKey, of: &SessionKey) -> bool {
    match (connection_of(key), connection_of(of)) {
        (Some(key), Some(of)) => key == of,
        _ => key == of,
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

/// The databases a drop can offer: neither the connection's own, the
/// server's, nor one the engine keeps for itself.
pub(super) fn droppable(databases: &[SchemaInfo], own: Option<&str>, protects: impl Fn(&str) -> bool) -> Vec<String> {
    databases
        .iter()
        .filter(|database| {
            !database.is_default
                && !database.is_system
                && own != Some(database.name.as_str())
                && !protects(&database.name)
        })
        .map(|database| database.name.clone())
        .collect()
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
                && !open.databases.names().contains(&database)
                && !open.databases.is_dropping(&database);
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
        let (settle, settled) = oneshot::channel();
        {
            let mut sessions = self.imp().sessions.borrow_mut();
            let Some(open) = sessions.iter_mut().find(|open| open.claim.key() == &connection) else {
                return;
            };
            open.databases.opening.push(Opening {
                database: database.clone(),
                claim,
                _stop: stop.clone().drop_guard(),
                settled,
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
            let closing = match window.upgrade() {
                Some(window) => window.on_database_opened(id, &origin, database, opened),
                None => opened.ok().and_then(Result::ok).map(shut_down),
            };
            if let Some(closing) = closing {
                closing.await;
            }
            let _ = settle.send(());
        });
    }

    /// The claim is still the connection's only while the session that
    /// asked holds it: a teardown, or a reconnect that replaced it,
    /// dropped the open with it. A session an open stopped too late
    /// still made is closed, which the drop that stopped it waits for.
    fn on_database_opened(
        &self,
        id: Uuid,
        origin: &Arc<Session>,
        database: String,
        opened: Result<Result<Arc<Session>, ConnectError>, tablepro_session::runtime::TaskFailure>,
    ) -> Option<SessionClosing> {
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
            (None, Ok(Ok(session))) => return Some(shut_down(session)),
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
        None
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
            .find_open(|open| {
                (open.claim.key() == &SessionKey::Saved(id)).then(|| {
                    let mut taken = open.databases.names();
                    taken.extend(open.databases.dropping.iter().cloned());
                    taken
                })
            })
            .unwrap_or_default();
        let names = offered(databases, &open);
        if names.is_empty() {
            self.show_toast(&gettext("No other database of this server to open"));
            return;
        }
        let chooser = Chooser {
            heading: gettext("Open Database"),
            body: gettext("It opens beside the connection, with tables and tabs of its own."),
            response: OPEN,
            label: gettext("Open"),
        };
        self.ask_which(chooser, names, move |window, database| {
            // A drop can have started while the chooser was open.
            match window.is_dropping(id, &database) {
                true => window.show_toast(&gettext_f(
                    "“{database}” is being dropped, so it cannot open.",
                    &[("database", &database)],
                )),
                false => window.open_database(id, database),
            }
        });
    }

    /// Whether the connection `id`'s database `database` is on its way to
    /// a drop.
    fn is_dropping(&self, id: Uuid, database: &str) -> bool {
        self.find_open(|open| {
            (open.claim.key() == &SessionKey::Saved(id)).then(|| open.databases.is_dropping(database))
        })
        .unwrap_or(false)
    }

    /// Ask which of `names` to act on, in an alert with a drop-down.
    fn ask_which(&self, chooser: Chooser, names: Vec<String>, picked: impl Fn(&SessionWindow, String) + 'static) {
        let strings: Vec<&str> = names.iter().map(String::as_str).collect();
        let choice = gtk::DropDown::from_strings(&strings);
        choice.update_property(&[gtk::accessible::Property::Label(&gettext("Database"))]);
        let dialog = adw::AlertDialog::builder()
            .heading(chooser.heading)
            .body(chooser.body)
            .extra_child(&choice)
            .default_response(chooser.response)
            .close_response("cancel")
            .build();
        dialog.add_responses(&[("cancel", &gettext("Cancel")), (chooser.response, &chooser.label)]);
        dialog.set_response_appearance(chooser.response, adw::ResponseAppearance::Suggested);
        let window = self.downgrade();
        let response = chooser.response;
        dialog.connect_response(None, move |_, answered| {
            let database = usize::try_from(choice.selected())
                .ok()
                .and_then(|at| names.get(at))
                .cloned();
            if let (true, Some(window), Some(database)) = (answered == response, window.upgrade(), database) {
                picked(&window, database);
            }
        });
        dialog.present(Some(self));
    }

    /// Drop Database… on a connection's row asks which of the server's
    /// databases first; on the row of a database open beside it, that
    /// one is meant. The connection's own session asks and drops.
    pub(super) fn drop_database_in(&self, key: SessionKey) {
        match key {
            SessionKey::SavedIn { id, database } => {
                self.deliver_to(&SessionKey::Saved(id), WorkspaceInput::DropDatabasePrompt(database));
            }
            SessionKey::Saved(id) => self.choose_database_to_drop(id),
            SessionKey::File(_) => {}
        }
    }

    fn choose_database_to_drop(&self, id: Uuid) {
        let key = SessionKey::Saved(id);
        let (Some(session), Some(state)) = (self.held_session(&key), self.state()) else {
            return;
        };
        let listed = session.clone();
        let listing = state.services.tasks.spawn_task(async move {
            listed
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
                Ok(Ok(databases)) => window.ask_database_to_drop(id, &session, &databases),
                Ok(Err(error)) => window.show_toast(&operation_error_message(&error)),
                Err(failure) => tracing::warn!(%failure, "listing the server's databases failed"),
            }
        });
    }

    fn ask_database_to_drop(&self, id: Uuid, session: &Session, databases: &[SchemaInfo]) {
        let Some(dialect) = session.current_dialect() else {
            return;
        };
        let names = droppable(databases, session.database(), |name| {
            tablepro_core::ddl::protects_database(&*dialect, name)
        });
        if names.is_empty() {
            self.show_toast(&gettext("No database of this server can be dropped from here"));
            return;
        }
        let chooser = Chooser {
            heading: gettext("Drop Database"),
            body: gettext("Nothing is dropped until you confirm on the next step."),
            response: CONTINUE,
            label: gettext("Continue"),
        };
        self.ask_which(chooser, names, move |window, database| {
            window.deliver_to(&SessionKey::Saved(id), WorkspaceInput::DropDatabasePrompt(database));
        });
    }

    /// Close the session the window holds on the database a session is
    /// dropping, through that session's own prompts and down to its last
    /// connection, then hand the drop back to the session that asked. From
    /// now until the drop ends nothing opens the database. A prompt
    /// answered Cancel drops nothing (0034).
    pub(super) fn release_database(&self, target: DatabaseDrop, options: DropDatabaseOptions) {
        let release = Release { target, options };
        let Some(id) = connection_of(&release.target.key) else {
            release.hand_back(self);
            return;
        };
        let Some(stopped) = self.reserve_for_drop(&release.target) else {
            tracing::debug!("the session that asked to drop a database is gone, so nothing is dropped");
            return;
        };
        let sibling = SessionKey::SavedIn {
            id,
            database: release.target.database.clone(),
        };
        if !self.holds_session(&sibling) {
            self.hand_back_after(stopped, release);
            return;
        }
        let (Some(handles), Some(guards)) = (self.teardown_handles(&sibling), self.close_guards()) else {
            self.lift_reservation(&release.target);
            return;
        };
        guards.begin_teardown();
        if guards.may_tear_down(&handles) {
            self.take_down_then_drop(&sibling, release);
            return;
        }
        let window = self.downgrade();
        guards.ask_tear_down(self.upcast_ref(), &handles, move |decision| {
            let Some(window) = window.upgrade() else {
                return;
            };
            match decision {
                CloseDecision::Approved => window.take_down_then_drop(&sibling, release),
                CloseDecision::Cancelled => window.lift_reservation(&release.target),
            }
        });
    }

    fn take_down_then_drop(&self, sibling: &SessionKey, release: Release) {
        match self.take_down_session(sibling) {
            Some(closing) => self.hand_back_after(closing, release),
            None => release.hand_back(self),
        }
    }

    /// Hand the drop back once `closed` answers: what the window held on
    /// the database has closed its connections.
    fn hand_back_after(&self, closed: SessionClosing, release: Release) {
        let window = self.downgrade();
        glib::spawn_future_local(async move {
            closed.await;
            if let Some(window) = window.upgrade() {
                release.hand_back(&window);
            }
        });
    }

    /// Hold the database for the drop on the session that asked, and stop
    /// an open of it still running. What answers once that open has ended,
    /// or `None` when the session that asked is gone.
    fn reserve_for_drop(&self, target: &DatabaseDrop) -> Option<SessionClosing> {
        let stopped = {
            let mut sessions = self.imp().sessions.try_borrow_mut().ok()?;
            let owner = sessions
                .iter_mut()
                .find(|open| open.claim.key() == &target.key && target.confirmed_by(&open.session))?;
            owner.databases.reserve(&target.database);
            owner.databases.stop_opening(&target.database)
        };
        // Its claim and its stop go here, outside the borrow of the
        // sessions, which letting a claim go can read.
        let settled: SessionClosing = match stopped {
            Some(Opening { settled, .. }) => settled.map(drop).boxed_local(),
            None => Box::pin(std::future::ready(())),
        };
        Some(settled)
    }

    /// The drop ended or will not run, so the database may open again.
    /// Only the session that asked holds it.
    pub(super) fn lift_reservation(&self, target: &DatabaseDrop) {
        let Ok(mut sessions) = self.imp().sessions.try_borrow_mut() else {
            return;
        };
        let owner = sessions
            .iter_mut()
            .find(|open| open.claim.key() == &target.key && target.confirmed_by(&open.session));
        if let Some(owner) = owner {
            owner.databases.lift(&target.database);
        }
    }

    /// Every session of the connection under `key` lists the server's
    /// databases again.
    pub(super) fn databases_changed(&self, key: &SessionKey) {
        let workspaces: Vec<Workspace> = self
            .imp()
            .sessions
            .try_borrow()
            .map(|sessions| {
                sessions
                    .iter()
                    .flat_map(OpenSession::with_databases)
                    .filter(|open| same_connection(open.claim.key(), key))
                    .map(|open| open.workspace.clone())
                    .collect()
            })
            .unwrap_or_default();
        for workspace in workspaces {
            if let Some(input) = workspace.sender() {
                input.deliver(WorkspaceInput::DatabasesChanged);
            }
        }
    }

    /// A database just created opens beside the connection where its
    /// catalog lists only its own database, so it shows (0034).
    pub(super) fn open_database_in(&self, key: &SessionKey, database: String) {
        if let Some(id) = connection_of(key)
            && self.opens_databases(id)
        {
            self.open_database(id, database);
        }
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
