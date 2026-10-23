use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures::future::Either;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_core::dialect::SqlDialect;
use tablepro_mcp::{McpHost, OpenOutcome, WriteApproval};
use tablepro_session::{Session, SessionKey};
use tablepro_storage::SavedConnection;
use tablepro_storage::query_history::NewEntry;
use tokio::sync::oneshot;
use uuid::Uuid;

use super::{AppServices, TableProApplication, WindowLaunch};
use crate::runtime::{InputSender, input_queue, pump_inputs};
use crate::services::history_service::HistoryService;
use crate::ui::write_confirmation::{WriteConfirmation, confirm_until};
use crate::ui::{SessionWindow, SessionWindowInput};

// Long enough for a saved password to be read and the server to answer,
// short enough that a client does not give up first.
const OPEN_WAIT: Duration = Duration::from_secs(10);
const OPEN_POLL: Duration = Duration::from_millis(200);

/// What the server asks of the application, answered on the GTK thread,
/// which owns the windows and the session registry.
pub(crate) enum McpRequest {
    Session {
        id: Uuid,
        reply: oneshot::Sender<Option<Arc<Session>>>,
    },
    OpenConnections {
        reply: oneshot::Sender<Vec<Uuid>>,
    },
    Open {
        connection: Box<SavedConnection>,
        reply: oneshot::Sender<OpenOutcome>,
    },
    Approve {
        approval: WriteApproval,
        reply: oneshot::Sender<bool>,
    },
}

pub(crate) struct GtkMcpHost {
    requests: InputSender<McpRequest>,
    history: HistoryService,
}

impl GtkMcpHost {
    /// `None` once the application stopped answering.
    async fn ask<T>(&self, request: impl FnOnce(oneshot::Sender<T>) -> McpRequest) -> Option<T> {
        let (reply, answer) = oneshot::channel();
        self.requests.send(request(reply)).ok()?;
        answer.await.ok()
    }
}

#[async_trait]
impl McpHost for GtkMcpHost {
    async fn session(&self, id: Uuid) -> Option<Arc<Session>> {
        self.ask(|reply| McpRequest::Session { id, reply }).await.flatten()
    }

    async fn open_connections(&self) -> Vec<Uuid> {
        self.ask(|reply| McpRequest::OpenConnections { reply })
            .await
            .unwrap_or_default()
    }

    async fn open(&self, connection: SavedConnection) -> OpenOutcome {
        let connection = Box::new(connection);
        self.ask(|reply| McpRequest::Open { connection, reply })
            .await
            .unwrap_or(OpenOutcome::Closed)
    }

    async fn approve(&self, approval: WriteApproval) -> bool {
        self.ask(|reply| McpRequest::Approve { approval, reply })
            .await
            .unwrap_or(false)
    }

    async fn record(&self, entry: NewEntry, dialect: Arc<dyn SqlDialect>) {
        self.history.record(entry, Some(dialect)).await;
    }
}

impl TableProApplication {
    /// Answer the MCP server for as long as the application runs. Only
    /// the primary instance has windows to answer from.
    pub(super) fn start_mcp(&self) {
        let Some(services) = self.services() else {
            return;
        };
        services.start_mcp(self.answer_mcp(&services));
    }

    /// The host the server asks, answered here until the application
    /// stops.
    pub(super) fn answer_mcp(&self, services: &AppServices) -> Arc<GtkMcpHost> {
        let (requests, receiver) = input_queue();
        let pump = pump_inputs(self, receiver, answer);
        if let Some(previous) = self.imp().mcp_requests.replace(Some(pump)) {
            previous.abort();
        }
        Arc::new(GtkMcpHost {
            requests,
            history: services.history(),
        })
    }

    pub(super) fn stop_mcp(&self) {
        if let Some(services) = self.services() {
            services.stop_mcp();
        }
        if let Some(pump) = self.imp().mcp_requests.take() {
            pump.abort();
        }
    }
}

fn answer(app: &TableProApplication, request: McpRequest) {
    let Some(services) = app.services() else {
        return;
    };
    match request {
        McpRequest::Session { id, reply } => {
            let _ = reply.send(services.sessions.session(&SessionKey::Saved(id)));
        }
        McpRequest::OpenConnections { reply } => {
            let open = services
                .sessions
                .attached_sessions()
                .into_iter()
                .filter_map(|(key, _)| match key {
                    SessionKey::Saved(id) => Some(id),
                    SessionKey::File(_) => None,
                })
                .collect();
            let _ = reply.send(open);
        }
        McpRequest::Open { connection, reply } => open(app, &services, *connection, reply),
        McpRequest::Approve { approval, reply } => approve(app, &services, approval, reply),
    }
}

/// Open the connection the way the picker does: in the window that has
/// it, in the active window while it only shows the picker, or in a new
/// window. Every prompt the connect needs shows there.
fn open(app: &TableProApplication, services: &AppServices, connection: SavedConnection, reply: oneshot::Sender<OpenOutcome>) {
    let key = SessionKey::Saved(connection.id);
    if let Some(session) = services.sessions.session(&key) {
        let _ = reply.send(OpenOutcome::Open(session));
        return;
    }
    if services.sessions.window_for(&key).is_none() {
        let idle = app
            .active_window()
            .and_downcast::<SessionWindow>()
            .filter(SessionWindow::is_idle);
        match idle {
            Some(window) => {
                window.send(SessionWindowInput::OpenSaved(Box::new(connection)));
                window.present();
            }
            None => {
                app.open_window(WindowLaunch::Connect(Box::new(connection)));
            }
        }
    }
    let sessions = services.sessions.clone();
    glib::spawn_future_local(async move {
        let deadline = Instant::now() + OPEN_WAIT;
        // The window claims the connection once it reads its input, so
        // no claim yet is not a closed connect.
        let mut claimed = false;
        let outcome = loop {
            if let Some(session) = sessions.session(&key) {
                break OpenOutcome::Open(session);
            }
            match sessions.window_for(&key) {
                Some(_) => claimed = true,
                None if claimed => break OpenOutcome::Closed,
                None => {}
            }
            if reply.is_closed() {
                return;
            }
            if Instant::now() >= deadline {
                break match claimed {
                    true => OpenOutcome::Connecting,
                    false => OpenOutcome::Closed,
                };
            }
            glib::timeout_future(OPEN_POLL).await;
        };
        let _ = reply.send(outcome);
    });
}

/// Ask in the window that has the connection open, with Safe Mode's
/// dialog. The question goes away unanswered when the client does.
fn approve(app: &TableProApplication, services: &AppServices, approval: WriteApproval, mut reply: oneshot::Sender<bool>) {
    let window = services
        .sessions
        .window_for(&SessionKey::Saved(approval.connection_id))
        .and_then(|id| app.window_by_id(id));
    let Some(window) = window else {
        let _ = reply.send(false);
        return;
    };
    let confirmation = WriteConfirmation::external(&approval.connection_name, &approval.sql, approval.destructive);
    window.present();
    glib::spawn_future_local(async move {
        let asked = approval.cancel.child_token();
        let parent: gtk4::Widget = window.upcast();
        let question = Box::pin(confirm_until(&parent, &confirmation, &asked));
        let gone = Box::pin(reply.closed());
        let approved = match futures::future::select(question, gone).await {
            Either::Left((approved, _)) => approved,
            Either::Right(((), question)) => {
                asked.cancel();
                question.await
            }
        };
        let _ = reply.send(approved);
    });
}
