use std::cell::Cell;
use std::collections::HashSet;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{ComponentSender, adw, gtk};
use uuid::Uuid;

use super::workspace_persistence::{WorkspacePersistence, WorkspaceTabs};
use super::{App, AppMsg, WorkspaceTab, connection};
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
    ///
    /// The tabs go first: each editor tab closes its own connection,
    /// which outlives the window's, and every read on the window's
    /// session stops. Only then does the session itself close. Every
    /// close holds the process until it ends, so quitting does not cut
    /// a connection off mid-close.
    pub(super) fn run(&self, window: Option<&adw::ApplicationWindow>) {
        if self.done.replace(true) {
            return;
        }
        let parts = &self.parts;
        if let Some(window) = window {
            crate::ui::window_geometry::persist(window, &parts.settings);
        }
        self.flush();
        for tab in parts.tabs.borrow().values() {
            match tab {
                WorkspaceTab::Editor(slot) => slot.editor.shutdown(),
                WorkspaceTab::Structure(slot) => slot.structure.shutdown(),
                WorkspaceTab::Table(slot) => slot.browse.shutdown(),
            }
        }
        connection::close_window_session(&parts.context.active, &*parts.context.hold, &parts.connect_attempts);
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
