use std::sync::Arc;

use relm4::ComponentSender;
use relm4::adw::prelude::*;
use relm4::{adw, gtk};
#[cfg(test)]
use tablepro_core::QueryResult;
use tablepro_core::{
    Connection, DriverError, OperationControl, QueryCursorId, QueryCursorPage, QueryResultBatch, Session,
    SessionCommitOutcome, Value,
};
use uuid::Uuid;

use crate::services::database_service::ConnectionIdentity;

use super::{SqlEditor, SqlEditorInput};

mod export_pages;
mod toolbar;
#[cfg(test)]
pub(crate) use export_pages::query_cursor_export_factory_for_target;
pub(crate) use export_pages::{StreamSession, query_cursor_export_factory};

pub(crate) type SharedSession = Arc<tokio::sync::Mutex<Option<Box<dyn Session>>>>;

pub struct OpenedSession(pub(crate) SharedSession);

pub(crate) async fn close_for_teardown(shared: SharedSession) -> Result<(), DriverError> {
    let session = shared.lock().await.take();
    match session {
        Some(session) => session.close().await,
        None => Ok(()),
    }
}

impl std::fmt::Debug for OpenedSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("OpenedSession")
    }
}

#[derive(Clone)]
pub(crate) enum StatementTarget {
    Pool(Arc<dyn Connection>),
    Session { id: Uuid, shared: SharedSession },
    Retired { id: Uuid },
}

pub(crate) struct StatementCursor {
    target: StatementTarget,
    id: QueryCursorId,
    owned_session: bool,
}

impl StatementCursor {
    pub(crate) async fn fetch_page(&self, control: &OperationControl) -> Result<QueryCursorPage, DriverError> {
        let StatementTarget::Session { shared, .. } = &self.target else {
            return Err(DriverError::Internal("cursor target is not a session".into()));
        };
        let mut session = shared.lock().await;
        match session.as_mut() {
            Some(session) => session.fetch_query_cursor_page_controlled(self.id, control).await,
            None => Err(DriverError::Unsupported("the cursor session was closed".into())),
        }
    }

    pub(crate) async fn finish(self, close_cursor: bool) -> Result<(), DriverError> {
        let StatementTarget::Session { shared, .. } = &self.target else {
            return Err(DriverError::Internal("cursor target is not a session".into()));
        };
        let close = if close_cursor {
            let mut session = shared.lock().await;
            match session.as_mut() {
                Some(session) => {
                    let control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
                    session.close_query_cursor_controlled(self.id, &control).await
                }
                None => Ok(()),
            }
        } else {
            Ok(())
        };
        let rollback_control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        let rollback = self.target.query("ROLLBACK", &[], &rollback_control).await.map(|_| ());
        let session_close = if self.owned_session {
            close_for_teardown(shared.clone()).await
        } else {
            Ok(())
        };
        close.and(rollback).and(session_close)
    }
}

impl StatementTarget {
    pub(crate) async fn open_query_cursor(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<Option<StatementCursor>, DriverError> {
        let (target, owned_session) = match self {
            Self::Pool(connection) => {
                let session = connection.open_session().await?;
                let shared = Arc::new(tokio::sync::Mutex::new(Some(session)));
                (
                    Self::Session {
                        id: Uuid::new_v4(),
                        shared,
                    },
                    true,
                )
            }
            Self::Session { .. } => {
                let Some((_, transaction_open, usable)) = self.session_state().await else {
                    return Ok(None);
                };
                if transaction_open || !usable {
                    return Ok(None);
                }
                (self.clone(), false)
            }
            Self::Retired { .. } => return Err(retired_session_error()),
        };
        let begin = target
            .query("BEGIN READ ONLY ISOLATION LEVEL REPEATABLE READ", &[], control)
            .await;
        if let Err(error) = begin {
            Self::release_cursor_session(&target, owned_session).await;
            return Err(error);
        }
        let cursor_id = match &target {
            Self::Session { shared, .. } => {
                let mut session = shared.lock().await;
                match session.as_mut() {
                    Some(session) => session.open_query_cursor_controlled(sql, params, control).await,
                    None => Err(DriverError::Unsupported("the cursor session was closed".into())),
                }
            }
            Self::Pool(_) | Self::Retired { .. } => Err(DriverError::Internal("cursor target is not a session".into())),
        };
        match cursor_id {
            Ok(id) => Ok(Some(StatementCursor {
                target,
                id,
                owned_session,
            })),
            Err(error) => {
                Self::release_cursor_session(&target, owned_session).await;
                if matches!(error, DriverError::Unsupported(_)) {
                    Ok(None)
                } else {
                    Err(error)
                }
            }
        }
    }

    async fn release_cursor_session(target: &StatementTarget, owned_session: bool) {
        let rollback_control = OperationControl::with_timeout(std::time::Duration::from_secs(10));
        if let Err(error) = target.query("ROLLBACK", &[], &rollback_control).await {
            crate::services::driver_diagnostics::warn_driver_cleanup(&error, "setup_rollback");
        }
        if owned_session
            && let Self::Session { shared, .. } = target
            && let Err(error) = close_for_teardown(shared.clone()).await
        {
            crate::services::driver_diagnostics::warn_driver_cleanup(&error, "setup_close");
        }
    }

    pub(crate) async fn query(
        &self,
        sql: &str,
        params: &[Value],
        control: &OperationControl,
    ) -> Result<QueryResultBatch, DriverError> {
        match self {
            Self::Pool(connection) => connection.query_result_sets_controlled(sql, params, control).await,
            Self::Session { shared, .. } => match shared.lock().await.as_mut() {
                Some(session) if session.is_usable() => {
                    session.query_result_sets_params_controlled(sql, params, control).await
                }
                Some(_) => Err(retired_session_error()),
                None => Err(DriverError::Unsupported("the session was closed".into())),
            },
            Self::Retired { .. } => Err(retired_session_error()),
        }
    }

    pub(crate) async fn lexical_settings(
        &self,
        control: &OperationControl,
    ) -> Result<Option<tablepro_core::sql_syntax::script::LexicalSettings>, DriverError> {
        match self {
            Self::Pool(connection) => connection.lexical_settings_controlled(control).await,
            Self::Session { shared, .. } => match shared.lock().await.as_mut() {
                Some(session) if session.is_usable() => session.lexical_settings_controlled(control).await,
                Some(_) => Err(retired_session_error()),
                None => Err(DriverError::Unsupported("the session was closed".into())),
            },
            Self::Retired { .. } => Err(retired_session_error()),
        }
    }

    pub(crate) async fn session_state(&self) -> Option<(Uuid, bool, bool)> {
        match self {
            Self::Pool(_) => None,
            Self::Retired { id } => Some((*id, false, false)),
            Self::Session { id, shared } => {
                let session = shared.lock().await;
                Some(match session.as_ref() {
                    Some(session) => (*id, session.transaction_open(), session.is_usable()),
                    None => (*id, false, false),
                })
            }
        }
    }
}

fn retired_session_error() -> DriverError {
    DriverError::Unsupported("the editor session was retired; reopen Session before running more SQL".into())
}

fn retired_connection_matches(retired: Option<(Uuid, Uuid)>, active: Option<Uuid>) -> bool {
    active.is_some_and(|active| retired.is_some_and(|(connection, _)| connection == active))
}

pub(crate) struct EditorSession {
    pub(super) id: Uuid,
    pub(super) shared: SharedSession,
    connection_id: Uuid,
    connection_identity: Option<ConnectionIdentity>,
    transaction_open: bool,
}

pub(super) fn session_callback_matches(callback_id: Uuid, current_id: Option<Uuid>) -> bool {
    current_id == Some(callback_id)
}

fn open_callback_matches(
    callback_id: Uuid,
    pending_id: Option<Uuid>,
    callback_connection_id: Uuid,
    current_connection_id: Option<Uuid>,
) -> bool {
    session_callback_matches(callback_id, pending_id) && Some(callback_connection_id) == current_connection_id
}

fn commit_callback_matches(callback_id: Uuid, current_id: Option<Uuid>, ending_id: Option<Uuid>) -> bool {
    session_callback_matches(callback_id, current_id) && Some(callback_id) == ending_id
}

fn apply_transaction_state(session: &mut EditorSession, callback_id: Uuid, transaction_open: bool) -> bool {
    if !session_callback_matches(callback_id, Some(session.id)) {
        return false;
    }
    session.transaction_open = transaction_open;
    true
}

fn can_start_session_close(
    teardown_active: bool,
    close_running: bool,
    open_running: bool,
    query_running: bool,
) -> bool {
    teardown_active && !close_running && !open_running && !query_running
}

fn session_end_dialog(button: &gtk::ToggleButton, on_end: impl Fn(bool) + 'static) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("End the session with an open transaction?")),
        Some(&crate::tr!(
            "Changes made since BEGIN are kept only if you commit them."
        )),
    );
    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("rollback", &crate::tr!("Roll Back"));
    dialog.add_response("commit", &crate::tr!("Commit"));
    dialog.set_response_appearance("rollback", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");
    let button = button.clone();
    dialog.connect_response(None, move |_, response| match response {
        "commit" => on_end(true),
        "rollback" => on_end(false),
        _ => button.set_active(true),
    });
    dialog
}

impl SqlEditor {
    pub(super) fn statement_target(&self, pooled: Arc<dyn Connection>) -> StatementTarget {
        match &self.session {
            Some(session)
                if Some(session.connection_id) == self.connection_id
                    && session.connection_identity.as_ref().is_some_and(|identity| {
                        self.database.identity(session.connection_id).as_ref() == Some(identity)
                    }) =>
            {
                StatementTarget::Session {
                    id: session.id,
                    shared: session.shared.clone(),
                }
            }
            Some(session) if Some(session.connection_id) == self.connection_id => {
                StatementTarget::Retired { id: session.id }
            }
            _ if retired_connection_matches(self.retired_session_connection_id, self.connection_id) => {
                StatementTarget::Retired {
                    id: self
                        .retired_session_connection_id
                        .map_or(Uuid::nil(), |(_, session)| session),
                }
            }
            _ => StatementTarget::Pool(pooled),
        }
    }

    pub(crate) fn session_transaction_open(&self) -> bool {
        self.session.as_ref().is_some_and(|session| session.transaction_open)
    }

    pub(super) fn on_session_toggled(&mut self, enabled: bool, sender: &ComponentSender<Self>) {
        if self.session_teardown_active {
            return;
        }
        if self.session_ending() {
            return;
        }
        match (enabled, &self.session) {
            (true, None) => self.open_session(sender),
            (false, None) => self.opening_session_id = None,
            (false, Some(session)) if session.transaction_open => self.confirm_session_end(sender),
            (false, Some(_)) => self.end_session(sender),
            _ => {}
        }
    }

    fn open_session(&mut self, sender: &ComponentSender<Self>) {
        let (Some(connection_id), Some((connection, connection_identity))) = (
            self.connection_id,
            self.connection_id.and_then(|id| self.database.get_with_identity(id)),
        ) else {
            self.opening_session_id = None;
            self.session_button.set_active(false);
            self.status.set_label(&crate::tr!("no active connection"));
            return;
        };
        let session_id = Uuid::new_v4();
        self.opening_session_id = Some(session_id);
        self.session_open_in_flight = true;
        self.refresh_run_button();
        let sender = sender.clone();
        relm4::spawn(async move {
            let result = connection
                .open_session()
                .await
                .map(|session| OpenedSession(Arc::new(tokio::sync::Mutex::new(Some(session)))))
                .map_err(|error| session_open_message(&error));
            sender.input(SqlEditorInput::SessionOpened {
                connection_id,
                connection_identity,
                session_id,
                result,
            });
        });
    }

    pub(super) fn on_session_opened(
        &mut self,
        connection_id: Uuid,
        connection_identity: ConnectionIdentity,
        session_id: Uuid,
        result: Result<OpenedSession, String>,
        sender: &ComponentSender<Self>,
    ) {
        self.session_open_in_flight = false;
        let is_current = open_callback_matches(session_id, self.opening_session_id, connection_id, self.connection_id)
            && self.database.identity(connection_id).as_ref() == Some(&connection_identity);
        if !is_current {
            if let Ok(OpenedSession(shared)) = result {
                self.close_session_for_teardown(shared, sender);
            } else {
                self.try_start_session_teardown(sender);
            }
            self.refresh_run_button();
            return;
        }
        self.opening_session_id = None;
        match result {
            Ok(OpenedSession(shared)) if self.session_button.is_active() => {
                self.retired_session_connection_id = None;
                self.session = Some(EditorSession {
                    id: session_id,
                    shared,
                    connection_id,
                    connection_identity: Some(connection_identity),
                    transaction_open: false,
                });
                self.transaction_clock.reset(&self.session_button);
            }
            Ok(OpenedSession(shared)) => self.close_session_for_teardown(shared, sender),
            Err(message) => {
                self.session_button.set_active(false);
                self.status.set_label(&message);
            }
        }
        self.refresh_run_button();
        self.try_start_session_teardown(sender);
    }

    pub(super) fn prepare_for_teardown(
        &mut self,
        reply: tokio::sync::oneshot::Sender<Result<(), String>>,
        sender: &ComponentSender<Self>,
    ) {
        self.session_teardown_waiters.push(reply);
        if !self.session_teardown_active {
            self.session_teardown_active = true;
            self.opening_session_id = None;
            self.session_button.set_sensitive(false);
            self.run_button.set_sensitive(false);
            self.status.set_label(&crate::tr!("Rolling back and closing session…"));
            if let Some(token) = self.cancel_token.take() {
                token.cancel();
            }
        }
        self.try_start_session_teardown(sender);
    }

    pub(super) fn try_start_session_teardown(&mut self, sender: &ComponentSender<Self>) {
        if !can_start_session_close(
            self.session_teardown_active,
            self.session_teardown_running,
            self.session_open_in_flight,
            !self.run_generation.active.is_empty(),
        ) {
            return;
        }
        if let Some(session) = self.session.take() {
            self.close_session_for_teardown(session.shared, sender);
        } else {
            self.finish_session_teardown(Ok(()));
        }
    }

    fn close_session_for_teardown(&mut self, shared: SharedSession, sender: &ComponentSender<Self>) {
        self.session_teardown_active = true;
        self.session_teardown_running = true;
        self.session_button.set_sensitive(false);
        self.run_button.set_sensitive(false);
        self.status.set_label(&crate::tr!("Closing session…"));
        self.transaction_clock.reset(&self.session_button);
        self.session_button.remove_css_class("warning");
        if self.session_button.is_active() {
            self.session_button.set_active(false);
        }
        let sender = sender.clone();
        relm4::spawn(async move {
            let result = close_for_teardown(shared)
                .await
                .map_err(|error| crate::services::error_text::driver_message(&error));
            sender.input(super::SqlEditorInput::SessionTeardownFinished(result));
        });
    }

    pub(super) fn finish_session_teardown(&mut self, result: Result<(), String>) {
        self.session_teardown_active = false;
        self.session_teardown_running = false;
        self.session_button.set_sensitive(true);
        self.refresh_run_button();
        if let Err(message) = &result {
            self.status.set_label(message);
        }
        for reply in self.session_teardown_waiters.drain(..) {
            let _ = reply.send(result.clone());
        }
    }

    pub(super) fn on_connection_identity_changed(&mut self, sender: &ComponentSender<Self>) {
        let Some((session_id, connection_id, connection_identity)) = self
            .session
            .as_ref()
            .map(|session| (session.id, session.connection_id, session.connection_identity.clone()))
        else {
            return;
        };
        if connection_identity
            .as_ref()
            .is_some_and(|identity| self.database.identity(connection_id).as_ref() == Some(identity))
        {
            return;
        }
        self.on_session_state(session_id, false, false, sender);
    }

    pub(super) fn on_session_state(
        &mut self,
        session_id: Uuid,
        transaction_open: bool,
        usable: bool,
        sender: &ComponentSender<Self>,
    ) {
        if self.ending_session_id == Some(session_id) {
            return;
        }
        let Some(session) = self.session.as_mut() else {
            return;
        };
        if !apply_transaction_state(session, session_id, transaction_open) {
            return;
        }
        if !usable {
            let Some(session) = self.session.take() else {
                return;
            };
            self.retired_session_connection_id = Some((session.connection_id, session.id));
            self.close_session_for_teardown(session.shared, sender);
            self.status.set_label(&crate::tr!(
                "This editor session was retired after a connection failure. Reopen Session before running more SQL."
            ));
            return;
        }
        self.transaction_clock
            .set_open(transaction_open, std::time::Instant::now());
        self.transaction_clock.show(&self.session_button);
        if transaction_open {
            self.session_button.add_css_class("warning");
        } else {
            self.session_button.remove_css_class("warning");
        }
    }

    pub(super) fn end_session(&mut self, sender: &ComponentSender<Self>) {
        self.opening_session_id = None;
        self.transaction_clock.reset(&self.session_button);
        self.session_button.remove_css_class("warning");
        if let Some(session) = self.session.take() {
            if self.ending_session_id == Some(session.id) {
                self.ending_session_id = None;
            }
            self.close_session_for_teardown(session.shared, sender);
        } else if self.session_button.is_active() {
            self.session_button.set_active(false);
        }
    }

    pub(super) fn rollback_and_end(&mut self, session_id: Uuid, sender: &ComponentSender<Self>) {
        let Some(session) = self
            .session
            .as_ref()
            .filter(|session| session_callback_matches(session_id, Some(session.id)))
        else {
            return;
        };
        if self.ending_session_id == Some(session_id) {
            return;
        }
        self.ending_session_id = Some(session_id);
        self.session_teardown_active = true;
        self.session_teardown_running = true;
        self.session_button.set_sensitive(false);
        self.run_button.set_sensitive(false);
        self.status.set_label(&crate::tr!("Rolling back and closing session…"));
        let shared = session.shared.clone();
        let sender = sender.clone();
        relm4::spawn(async move {
            let result = rollback_and_close(&shared)
                .await
                .map_err(|error| crate::services::error_text::driver_message(&error));
            sender.input(super::SqlEditorInput::SessionRollbackFinished { session_id, result });
        });
    }

    pub(super) fn on_session_rollback_finished(&mut self, session_id: Uuid, result: Result<(), String>) {
        if !commit_callback_matches(
            session_id,
            self.session.as_ref().map(|session| session.id),
            self.ending_session_id,
        ) {
            return;
        }
        if let Some(session) = self.session.take()
            && result.is_err()
        {
            self.retired_session_connection_id = Some((session.connection_id, session.id));
        }
        self.ending_session_id = None;
        self.transaction_clock.reset(&self.session_button);
        self.session_button.remove_css_class("warning");
        if self.session_button.is_active() {
            self.session_button.set_active(false);
        }
        if result.is_ok() {
            self.clear_run_marks();
            self.status.set_label(&crate::tr!("Session rolled back"));
        }
        self.finish_session_teardown(result);
    }

    pub(super) fn session_ending(&self) -> bool {
        self.session
            .as_ref()
            .is_some_and(|session| self.ending_session_id == Some(session.id))
    }

    pub(super) fn commit_and_end(&mut self, session_id: Uuid, sender: &ComponentSender<Self>) {
        let Some(session) = self
            .session
            .as_ref()
            .filter(|session| session_callback_matches(session_id, Some(session.id)))
        else {
            return;
        };
        if self.ending_session_id == Some(session_id) {
            return;
        }
        self.ending_session_id = Some(session_id);
        self.session_button.set_sensitive(false);
        self.status.set_label(&crate::tr!("Committing session…"));
        let shared = session.shared.clone();
        let sender = sender.clone();
        relm4::spawn(async move {
            let result = commit_session(&shared)
                .await
                .map_err(|error| crate::services::error_text::driver_message(&error));
            sender.input(SqlEditorInput::SessionCommitFinished { session_id, result });
        });
    }

    pub(super) fn on_session_commit_finished(
        &mut self,
        session_id: Uuid,
        result: Result<SessionCommitOutcome, String>,
        sender: &ComponentSender<Self>,
    ) {
        if !commit_callback_matches(
            session_id,
            self.session.as_ref().map(|session| session.id),
            self.ending_session_id,
        ) {
            return;
        }
        self.ending_session_id = None;
        self.session_button.set_sensitive(true);
        match result {
            Ok(outcome) => {
                self.end_session(sender);
                let message = match outcome {
                    SessionCommitOutcome::Committed => crate::tr!("Session committed"),
                    SessionCommitOutcome::RolledBack => {
                        self.clear_run_marks();
                        crate::tr!("Session rolled back")
                    }
                };
                self.status.set_label(&message);
            }
            Err(message) => {
                self.session_button.set_active(true);
                self.status.set_label(&message);
            }
        }
    }

    fn confirm_session_end(&self, sender: &ComponentSender<Self>) {
        let Some(session_id) = self.session.as_ref().map(|session| session.id) else {
            return;
        };
        self.session_button.set_active(true);
        let sender = sender.clone();
        let dialog = session_end_dialog(&self.session_button, move |commit| {
            sender.input(SqlEditorInput::SessionEnd { session_id, commit })
        });
        let parent = self.source_view.root().and_downcast::<gtk::Window>();
        dialog.present(parent.as_ref());
    }
}

async fn commit_session(shared: &SharedSession) -> Result<SessionCommitOutcome, DriverError> {
    let mut guard = shared.lock().await;
    let session = guard
        .as_mut()
        .ok_or_else(|| DriverError::Unsupported("the session was closed".into()))?;
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    session.commit_controlled(&control).await
}

async fn rollback_and_close(shared: &SharedSession) -> Result<(), DriverError> {
    let Some(mut session) = shared.lock().await.take() else {
        return Err(DriverError::Unsupported("the session was closed".into()));
    };
    if !session.is_usable() {
        return session.close().await;
    }
    let control = OperationControl::with_timeout(std::time::Duration::from_secs(30));
    let rollback = session.query_params_controlled("ROLLBACK", &[], &control).await;
    let close = session.close().await;
    match (rollback, close) {
        (Err(error), _) => Err(error),
        (Ok(_), result) => result,
    }
}

pub(crate) fn close_detached(shared: SharedSession) {
    relm4::spawn(close_detached_session(shared));
}

async fn close_detached_session(shared: SharedSession) {
    let Some(session) = shared.lock().await.take() else {
        return;
    };
    if let Err(error) = session.close().await {
        crate::services::driver_diagnostics::warn_driver_cleanup(&error, "session_close");
    }
}

fn session_open_message(error: &DriverError) -> String {
    match error {
        DriverError::Unsupported(_) => crate::tr!("This engine does not offer dedicated sessions yet"),
        other => crate::services::error_text::driver_message(other),
    }
}

#[cfg(test)]
#[path = "session_mode/tests.rs"]
mod tests;
