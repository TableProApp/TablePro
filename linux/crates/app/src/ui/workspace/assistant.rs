//! The session's assistant: its own pane, which the shell's column shows
//! while the session is in front, so a reply keeps coming while another
//! session's tab is on screen, and what that pane may send.

use std::rc::Rc;

use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::AiPolicy;
use tablepro_session::SessionKey;
use tablepro_storage::settings::keys;

use super::tab_index::TabIndex;
use super::workspace_persistence::WorkspaceTabs;
use super::{WorkspaceInput, WorkspaceModel, WorkspaceSender, WorkspaceTab, WorkspaceTabParts};
use crate::application::AppServices;
use crate::runtime::DeliverInput;
use crate::services::active_session::ActiveSession;
use crate::ui::assistant::{AssistantAccess, AssistantPane, AssistantRequest, Availability, PaneHooks};
use crate::ui::handler_guard::HandlerGuard;

pub(super) struct AssistantColumn {
    access: Rc<AssistantAccess>,
    pane: AssistantPane,
    _watches: Vec<HandlerGuard>,
}

/// The connection's policy, read from the saved connections each time
/// it is asked, so an edit applies from the next request. A file opened
/// without a saved connection asks.
pub(super) fn access(
    services: &AppServices,
    key: &SessionKey,
    session: ActiveSession,
    engine: String,
) -> Rc<AssistantAccess> {
    let saved = services.saved_connections.clone();
    let key = key.clone();
    AssistantAccess::new(services.ai.clone(), session, engine, move || match &key {
        SessionKey::Saved(id) | SessionKey::SavedIn { id, .. } => {
            saved.get(*id).map_or_else(AiPolicy::default, |saved| saved.ai_policy)
        }
        SessionKey::File(_) => AiPolicy::default(),
    })
}

/// The session's pane, bound once to its tabs and its access.
pub(super) fn install(parts: &WorkspaceTabParts, input: &WorkspaceSender) -> AssistantColumn {
    let access = parts.assistant.clone();
    let (tabs, index, view) = (
        parts.workspace_tabs.clone(),
        parts.index.clone(),
        parts.tab_view.downgrade(),
    );
    let pane: AssistantPane = glib::Object::new();
    pane.bind(PaneHooks {
        access: access.clone(),
        editor_text: Rc::new(move || active_editor_text(&tabs, &index, &view)),
        insert: {
            let input = input.clone();
            Rc::new(move |code| input.deliver(WorkspaceInput::InsertFromAssistant(code)))
        },
        toast: {
            let input = input.clone();
            Rc::new(move |text| input.deliver(WorkspaceInput::ShowToast(text)))
        },
    });
    let settings = access.ai().settings().clone();
    let mut watches = Vec::new();
    for key in [keys::AI_PROVIDER, keys::AI_INLINE_SUGGESTIONS] {
        let changed = input.clone();
        let handler = settings
            .gio()
            .connect_changed(Some(key), move |_, _| changed.deliver(WorkspaceInput::AssistantChanged));
        watches.push(HandlerGuard::new(settings.gio(), handler));
    }
    AssistantColumn {
        access,
        pane,
        _watches: watches,
    }
}

/// The text of this session's editor tab while it is the one on screen.
fn active_editor_text(tabs: &WorkspaceTabs, index: &TabIndex, view: &glib::WeakRef<adw::TabView>) -> Option<String> {
    let id = index.id_of(&view.upgrade()?.selected_page()?)?;
    match tabs.borrow().get(&id) {
        Some(WorkspaceTab::Editor(slot)) => {
            let buffer = slot.editor.buffer();
            let (start, end) = buffer.bounds();
            Some(buffer.text(&start, &end, false).to_string())
        }
        _ => None,
    }
}

impl AssistantColumn {
    pub(super) fn pane(&self) -> AssistantPane {
        self.pane.clone()
    }

    pub(super) fn shutdown(&self) {
        self.pane.shutdown();
    }
}

impl WorkspaceModel {
    /// The provider, a preference or the connection's policy changed.
    /// With no provider the column and its toggle go while the session is
    /// in front, and the key does nothing; under Never the pane says why
    /// it is off.
    pub(super) fn refresh_assistant(&self) {
        let available = self.assistant.access.availability() != Availability::Off;
        if let Some(workspace) = self.this.upgrade()
            && workspace.imp().assistant_available.replace(available) != available
        {
            workspace.notify_assistant_available();
        }
        self.assistant.pane.refresh();
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(slot) = tab {
                slot.editor.refresh_assistant();
            }
        }
    }

    /// An editor tab asked about a statement. It asks this session's own
    /// pane, which comes into view while the session is in front.
    pub(super) fn on_ask_assistant(&self, request: AssistantRequest) {
        if self.assistant.access.availability() != Availability::Ready {
            return;
        }
        if self.is_front()
            && let Some(shell) = self.shell.upgrade()
        {
            shell.reveal_assistant();
        }
        self.assistant.pane.run_action(request);
    }

    /// A code block's Insert: into the editor tab in front, or a new one
    /// when the tab in front is not an editor.
    pub(super) fn on_insert_from_assistant(&mut self, code: String) {
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            slot.editor.insert_from_assistant(&code);
            return;
        }
        self.open_editor_tab(Some(code));
    }
}
