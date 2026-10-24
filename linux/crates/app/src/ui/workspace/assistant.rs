//! The assistant's column beside the tabs: the header's toggle, the
//! `win.show-assistant` action, and the pane's view of the tabs.

use std::rc::Rc;

use gtk4 as gtk;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use libadwaita as adw;
use tablepro_core::AiPolicy;
use tablepro_session::SessionKey;
use tablepro_storage::settings::keys;

use super::tab_index::TabIndex;
use super::workspace_persistence::WorkspaceTabs;
use super::{Workspace, WorkspaceInput, WorkspaceModel, WorkspaceSender, WorkspaceTab, WorkspaceTabParts};
use crate::application::AppServices;
use crate::runtime::DeliverInput;
use crate::services::active_session::ActiveSession;
use crate::ui::assistant::{AssistantAccess, AssistantRequest, Availability, PaneHooks};
use crate::ui::handler_guard::HandlerGuard;

pub(super) const SHOW_ASSISTANT: &str = "show-assistant";

pub(super) struct AssistantShell {
    access: Rc<AssistantAccess>,
    action: gio::SimpleAction,
    split: adw::OverlaySplitView,
    pane: crate::ui::assistant::AssistantPane,
    toggle: gtk::ToggleButton,
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
        SessionKey::Saved(id) => saved.get(*id).map_or_else(AiPolicy::default, |saved| saved.ai_policy),
        SessionKey::File(_) => AiPolicy::default(),
    })
}

pub(super) fn install(
    workspace: &Workspace,
    window: &adw::ApplicationWindow,
    parts: &WorkspaceTabParts,
    input: &WorkspaceSender,
) -> AssistantShell {
    let access = parts.assistant.clone();
    let (tabs, index) = (parts.workspace_tabs.clone(), parts.index.clone());
    let imp = workspace.imp();
    let split = imp.assistant_split.get();
    let action = gio::SimpleAction::new_stateful(SHOW_ASSISTANT, None, &false.to_variant());
    let shown = split.downgrade();
    let pane = imp.assistant_pane.get();
    let focus = pane.downgrade();
    action.connect_change_state(move |action, state| {
        let Some(show) = state.and_then(|state| state.get::<bool>()) else {
            return;
        };
        action.set_state(&show.to_variant());
        if let Some(split) = shown.upgrade() {
            split.set_show_sidebar(show);
        }
        if show && let Some(pane) = focus.upgrade() {
            pane.focus_composer();
        }
    });
    let followed = action.downgrade();
    split.connect_show_sidebar_notify(move |split| {
        if let Some(action) = followed.upgrade() {
            action.set_state(&split.shows_sidebar().to_variant());
        }
    });
    window.add_action(&action);

    let view = imp.tab_view.downgrade();
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
    let toggle = imp.assistant_toggle.get();
    let shell = AssistantShell {
        access,
        action,
        split,
        pane,
        toggle,
        _watches: watches,
    };
    shell.refresh_controls();
    shell
}

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

impl AssistantShell {
    /// With no provider the column and its toggle go, and the key does
    /// nothing; under Never the pane says why it is off.
    fn refresh_controls(&self) {
        let available = self.access.availability() != Availability::Off;
        self.toggle.set_visible(available);
        self.action.set_enabled(available);
        if !available {
            self.split.set_show_sidebar(false);
        }
        self.pane.refresh();
    }

    pub(super) fn shutdown(&self) {
        self.pane.shutdown();
    }
}

impl WorkspaceModel {
    /// The provider, a preference or the connection's policy changed.
    pub(super) fn refresh_assistant(&self) {
        self.assistant.refresh_controls();
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(slot) = tab {
                slot.editor.refresh_assistant();
            }
        }
    }

    pub(super) fn on_ask_assistant(&self, request: AssistantRequest) {
        if self.assistant.access.availability() != Availability::Ready {
            return;
        }
        self.assistant.split.set_show_sidebar(true);
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
