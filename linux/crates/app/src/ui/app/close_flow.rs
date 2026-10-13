use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{ComponentSender, adw, gtk};
use uuid::Uuid;

use super::workspace_persistence::{WorkspacePersistence, WorkspaceTabs};
use super::{App, AppMsg, WorkspaceTab, connection};
use tablepro_session::runtime::ProcessHold;

use crate::services::active_session::ActiveSession;
use crate::services::session_context::SessionContext;
use crate::workspace::{CloseDecision, CloseGuard, CloseScope, CloseStep, InhibitReason, WorkspaceHandle};

/// Where the window's own close stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WindowClose {
    Open,
    /// The prompts are deciding.
    Asking,
    /// Nothing is left to lose, so the next close request goes through.
    Approved,
}

/// One close prompt at a time per window, so a tab's close and the
/// window's never ask about the same tab at once: a second waits for the
/// first, then reads the workspace as the first left it.
pub(super) struct CloseGuards {
    turn: futures::lock::Mutex<()>,
    window: Cell<WindowClose>,
}

impl CloseGuards {
    pub(super) fn new() -> Rc<Self> {
        Rc::new(Self {
            turn: futures::lock::Mutex::new(()),
            window: Cell::new(WindowClose::Open),
        })
    }

    async fn run(&self, parent: &gtk::Widget, handle: &WorkspaceHandle, scope: CloseScope) -> CloseDecision {
        let _turn = self.turn.lock().await;
        CloseGuard::run(parent, handle, scope).await
    }
}

/// What a window that closes still owes: what it shows written to disk,
/// and its connections closed rather than cut off, in order.
pub(super) struct WindowShutdown {
    done: Cell<bool>,
    parts: WindowShutdownParts,
}

pub(super) struct WindowShutdownParts {
    pub settings: Rc<tablepro_storage::AppSettings>,
    pub storage: crate::storage::SharedStorage,
    pub drafts: Rc<crate::workspace::DraftWriter>,
    pub workspace: Rc<WorkspacePersistence>,
    pub tabs: WorkspaceTabs,
    pub context: Rc<SessionContext>,
    pub connect_attempts: Rc<tablepro_session::ConnectAttempts>,
}

impl WindowShutdown {
    pub(super) fn new(parts: WindowShutdownParts) -> Rc<Self> {
        Rc::new(Self {
            done: Cell::new(false),
            parts,
        })
    }

    /// Runs once, from the close request, or from the component's
    /// shutdown for a window destroyed without one. `window` is the one
    /// still on screen, whose size is kept.
    pub(super) fn run(&self, window: Option<&adw::ApplicationWindow>) {
        if self.done.replace(true) {
            return;
        }
        let parts = &self.parts;
        if let Some(window) = window {
            crate::ui::window_geometry::persist(window, &parts.settings);
        }
        self.flush();
        close_connections(
            &parts.tabs,
            &parts.context.active,
            &*parts.context.hold,
            &parts.connect_attempts,
        );
    }

    /// The last column drag, filter change, editor text and tab list may
    /// still be on their way to disk.
    fn flush(&self) {
        let parts = &self.parts;
        let hold = parts.context.hold.acquire();
        let column_widths = parts.storage.column_widths().flush();
        let filter_settings = parts.storage.filter_settings().flush();
        let editor_drafts = parts.drafts.flush_all();
        let tabs = parts.workspace.detach();
        glib::spawn_future_local(async move {
            column_widths.await;
            filter_settings.await;
            for failure in editor_drafts.await {
                tracing::warn!(failure, "an editor draft was not saved");
            }
            if let Some(tabs) = tabs
                && let Err(error) = tabs.await
            {
                tracing::debug!(%error, "the open tabs were not saved");
            }
            drop(hold);
        });
    }
}

/// The tabs go first: each editor tab closes its own connection, which
/// outlives the window's, and every read on the window's session stops.
/// Only then does the session itself close. Every close holds the
/// process until it ends, so quitting does not cut a connection off
/// mid-close.
fn close_connections(
    tabs: &WorkspaceTabs,
    active: &ActiveSession,
    hold: &dyn ProcessHold,
    attempts: &tablepro_session::ConnectAttempts,
) {
    for tab in tabs.borrow().values() {
        match tab {
            WorkspaceTab::Editor(slot) => slot.editor.shutdown(),
            WorkspaceTab::Structure(slot) => slot.structure.shutdown(),
            WorkspaceTab::Table(slot) => slot.browse.shutdown(),
        }
    }
    connection::close_window_session(active, hold, attempts);
}

/// The window closes only once its prompts approve. A close request
/// while they are deciding is dropped, since their dialog is already
/// on screen.
pub(super) fn connect_window_close(
    window: &adw::ApplicationWindow,
    guards: Rc<CloseGuards>,
    handle: WorkspaceHandle,
    shutdown: Rc<WindowShutdown>,
) {
    window.connect_close_request(move |window| {
        match guards.window.get() {
            WindowClose::Asking => return glib::Propagation::Stop,
            WindowClose::Open if handle.close_step(CloseScope::Window, &HashSet::new()) != CloseStep::Approve => {
                guards.window.set(WindowClose::Asking);
                let (guards, handle, window) = (guards.clone(), handle.clone(), window.clone());
                glib::spawn_future_local(async move {
                    let decision = guards.run(window.upcast_ref(), &handle, CloseScope::Window).await;
                    match decision {
                        CloseDecision::Approved => {
                            guards.window.set(WindowClose::Approved);
                            window.close();
                        }
                        CloseDecision::Cancelled => guards.window.set(WindowClose::Open),
                    }
                });
                return glib::Propagation::Stop;
            }
            WindowClose::Open | WindowClose::Approved => {}
        }
        shutdown.run(Some(window));
        glib::Propagation::Proceed
    });
}

impl App {
    /// A tab asked to close. One with nothing to lose closes now; any
    /// other waits for the prompts.
    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let scope = CloseScope::Tab(id);
        if self.workspace_handle.close_step(scope, &HashSet::new()) == CloseStep::Approve {
            self.finish_close_workspace_tab(id, &tab_view);
            return;
        }
        let (guards, handle, window) = (
            self.close_guards.clone(),
            self.workspace_handle.clone(),
            self.window.clone(),
        );
        glib::spawn_future_local(async move {
            let decision = guards.run(window.upcast_ref(), &handle, scope).await;
            sender.input(AppMsg::TabCloseDecided {
                id,
                approved: decision == CloseDecision::Approved,
            });
        });
    }

    pub(super) fn on_tab_close_decided(&mut self, id: Uuid, approved: bool) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        if approved {
            self.finish_close_workspace_tab(id, &tab_view);
            return;
        }
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| match tab {
            WorkspaceTab::Editor(slot) => slot.page.clone(),
            WorkspaceTab::Structure(slot) => slot.page.clone(),
            WorkspaceTab::Table(slot) => slot.page.clone(),
        });
        if let Some(page) = page {
            tab_view.close_page_finish(&page, false);
        }
    }

    /// Send `proceed` once every tab may close, for a disconnect or a
    /// switch to another connection, which take the tabs with them.
    pub(super) fn close_workspace_then(&self, proceed: AppMsg, sender: ComponentSender<Self>) {
        if self.workspace_handle.close_step(CloseScope::Window, &HashSet::new()) == CloseStep::Approve {
            sender.input(proceed);
            return;
        }
        let (guards, handle, window) = (
            self.close_guards.clone(),
            self.workspace_handle.clone(),
            self.window.clone(),
        );
        glib::spawn_future_local(async move {
            if guards.run(window.upcast_ref(), &handle, CloseScope::Window).await == CloseDecision::Approved {
                sender.input(proceed);
            }
        });
    }

    /// Logout, and suspend while a save runs, wait for the user while
    /// the window holds something they would lose.
    pub(super) fn refresh_inhibitor(&mut self) {
        let dirty = !self.workspace_handle.dirty_tabs().is_empty();
        let saving = self.workspace_handle.ledger().in_flight() > 0;
        self.inhibitor.update(InhibitReason::for_state(dirty, saving));
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::sync::Arc;
    use std::time::Duration;

    use tablepro_core::{EditorSession, TransactionState};
    use tablepro_session::ConnectAttempts;
    use tablepro_session::runtime::CountingHold;
    use tablepro_storage::DraftId;
    use tablepro_test_support::{ConnectionScript, FakeEditorSession, FakeReply, FakeRun, Replies};

    use super::*;
    use crate::test_support::{FakeSession, MemorySettings, wait_until};
    use crate::ui::app::window_tabs::WindowTabs;
    use crate::ui::app::{EditorTabSlot, write_workspace_tab_id};
    use crate::ui::editor::{SqlEditor, SqlEditorInit};
    use crate::workspace::{TabDirectory, TabEntry};

    const WAIT: Duration = Duration::from_secs(10);

    #[gtk4::test]
    fn closing_the_window_names_open_transactions_and_closes_every_connection() {
        adw::init().expect("libadwaita initialises under the test backend");
        crate::register_test_resources();
        let runtime = crate::test_support::test_runtime();
        let settings = MemorySettings::new();
        let mut runs = Replies::default();
        runs.always(FakeRun::completed(Vec::new()).leaving(TransactionState::InTransaction));
        let editor_session = Arc::new(FakeEditorSession::new(runs));
        let mut script = ConnectionScript::default();
        let opened: Arc<dyn EditorSession> = editor_session.clone();
        script.open_editor_session.always(FakeReply::ok(opened));
        script.probe.always(FakeReply::ok(()));
        let fake = FakeSession::start(script, [], runtime.tasks());
        let active = ActiveSession::new();
        active.replace(fake.session.clone());
        let hold = Rc::new(CountingHold::new());
        let editor = SqlEditor::new(SqlEditorInit {
            initial_query: Some("BEGIN; UPDATE t SET a = 1".to_owned()),
            settings: settings.get().clone(),
            history: None,
            tasks: runtime.tasks(),
            session: active.clone(),
            hold: hold.clone(),
            close_timeout: Duration::from_secs(5),
        });
        editor.run();
        wait_until(WAIT, || !editor.is_running()).expect("the run to end");
        let view = adw::TabView::new();
        let page = view.append(&editor);
        page.set_title("• Query 1");
        let id = Uuid::new_v4();
        write_workspace_tab_id(&page, id);
        let tabs: WorkspaceTabs = Rc::new(RefCell::new(HashMap::from([(
            id,
            WorkspaceTab::Editor(EditorTabSlot {
                editor,
                page,
                draft: DraftId::new(),
            }),
        )])));
        let directory = WindowTabs::new(tabs.clone());
        directory.set_view(Some(&view));

        assert_eq!(
            directory.tabs(),
            [TabEntry {
                id,
                title: "Query 1".to_owned(),
                open_transaction: true,
            }]
        );

        close_connections(&tabs, &active, &*hold, &ConnectAttempts::new());

        assert!(!active.is_connected());
        wait_until(WAIT, || {
            editor_session.close_count() == 1 && fake.connection.is_closed() && hold.live() == 0
        })
        .expect("both connections to close under the hold");
        assert!(fake.session.is_shut_down());
        drop(tabs);
        crate::test_support::drain_main_context();
        runtime.shutdown();
    }
}
