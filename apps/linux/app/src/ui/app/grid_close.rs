use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;
use std::time::Duration;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{ComponentController, ComponentSender, adw};
use tablepro_app_services::preparation::{Preparation, PreparationStatus};
use uuid::Uuid;

use super::{App, AppMsg, OpenMode, WorkspaceTab};

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum GridCloseIntent {
    Tab(Uuid),
    Disconnect,
    Window,
    OpenTable { schema: Option<String>, name: String },
}

impl GridCloseIntent {
    fn message(self) -> AppMsg {
        match self {
            Self::Tab(id) => AppMsg::WorkspaceTabClosed(id),
            Self::Disconnect => AppMsg::Disconnect,
            Self::Window => AppMsg::FlushWindowEdits,
            Self::OpenTable { schema, name } => AppMsg::SelectTable {
                schema,
                name,
                open_mode: OpenMode::SwitchOrAppend,
            },
        }
    }
}

type Owners = Vec<(Uuid, glib::WeakRef<adw::TabPage>)>;
type Queues = Vec<(relm4::Sender<crate::ui::grid::GridMsg>, u64)>;

pub(super) struct GridCloseState {
    preparation: Preparation<GridCloseIntent>,
    owners: HashMap<u64, Owners>,
    sensitivity_before: Option<bool>,
    pub(super) window_ready: Rc<Cell<bool>>,
}

impl GridCloseState {
    pub(super) fn new(window_ready: Rc<Cell<bool>>) -> Self {
        Self {
            preparation: Preparation::default(),
            owners: HashMap::new(),
            sensitivity_before: None,
            window_ready,
        }
    }
}

fn tab_page(tab: &WorkspaceTab) -> &adw::TabPage {
    match tab {
        WorkspaceTab::Editor(slot) => &slot.page,
        WorkspaceTab::Table(slot) => &slot.page,
        WorkspaceTab::Structure(slot) => &slot.page,
    }
}

async fn wait_for_edits(replies: Vec<tokio::sync::oneshot::Receiver<Result<(), String>>>) -> Result<(), String> {
    let finished = async move {
        for reply in replies {
            reply
                .await
                .map_err(|_| crate::tr!("The table closed before its edit was finished."))??;
        }
        Ok(())
    };
    tokio::time::timeout(Duration::from_secs(20), finished)
        .await
        .map_err(|_| crate::tr!("Finishing the cell edit timed out. Try again."))?
}

fn pending_grid_close_owner_is_current(expected: &glib::WeakRef<adw::TabPage>, current: Option<&adw::TabPage>) -> bool {
    let Some(expected) = expected.upgrade() else {
        return false;
    };
    current.is_some_and(|current| current == &expected)
}

impl App {
    fn grid_close_targets(&self, intent: &GridCloseIntent) -> (Owners, Queues) {
        let tabs = self.workspace_tabs.borrow();
        let mut owners = Vec::new();
        let mut queues = Vec::new();
        for (id, tab) in tabs.iter() {
            if matches!(intent, GridCloseIntent::Tab(target) if target != id) {
                continue;
            }
            let WorkspaceTab::Table(slot) = tab else { continue };
            owners.push((*id, slot.page.downgrade()));
            queues.push(slot.browse.model().edit_flush_snapshot());
        }
        (owners, queues)
    }

    fn finish_grid_inputs(&self, intent: &GridCloseIntent) -> bool {
        let GridCloseIntent::Tab(id) = intent else {
            return crate::ui::grid::finish_active_edits(&self.window);
        };
        let root = self.workspace_tabs.borrow().get(id).map(|tab| tab_page(tab).child());
        root.is_none_or(|root| crate::ui::grid::finish_active_edits(&root))
    }

    pub(super) fn defer_for_grid_edits(&mut self, msg: &AppMsg, sender: &ComponentSender<Self>) -> bool {
        let intent = match msg {
            AppMsg::WorkspaceTabClosed(id) => GridCloseIntent::Tab(*id),
            AppMsg::Disconnect => GridCloseIntent::Disconnect,
            AppMsg::FlushWindowEdits => GridCloseIntent::Window,
            AppMsg::SelectTable {
                schema,
                name,
                open_mode: OpenMode::SwitchOrAppend,
            } => GridCloseIntent::OpenTable {
                schema: schema.clone(),
                name: name.clone(),
            },
            _ => return false,
        };
        let ticket = match self.grid_close.preparation.request(intent.clone()) {
            PreparationStatus::Ready => {
                self.restore_after_grid_preparation();
                return false;
            }
            PreparationStatus::Pending => return true,
            PreparationStatus::Started(ticket) => ticket,
        };
        let (owners, queues) = self.grid_close_targets(&intent);
        self.grid_close.owners.insert(ticket, owners);
        if queues.is_empty() {
            self.grid_edits_prepared(intent, ticket, Ok(()), sender.clone());
            return true;
        }
        if !self.finish_grid_inputs(&intent) {
            let message = crate::tr!("Finish or cancel the current cell edit and try again.");
            self.grid_edits_prepared(intent, ticket, Err(message), sender.clone());
            return true;
        }
        if self.grid_close.sensitivity_before.is_none() {
            self.grid_close.sensitivity_before = Some(self.window.is_sensitive());
            self.window.set_sensitive(false);
        }
        let mut replies = Vec::new();
        for (queue, revision) in queues {
            let (reply, receiver) = tokio::sync::oneshot::channel();
            let _ = queue.send(crate::ui::grid::GridMsg::EditsFlushed { revision, reply });
            replies.push(receiver);
        }
        let sender = sender.clone();
        sender.clone().command(move |_, shutdown| {
            shutdown
                .register(async move {
                    let result = wait_for_edits(replies).await;
                    sender.input(AppMsg::GridEditsPrepared { intent, ticket, result });
                })
                .drop_on_shutdown()
        });
        true
    }

    fn restore_after_grid_preparation(&mut self) {
        if self.grid_close.owners.is_empty()
            && let Some(sensitive) = self.grid_close.sensitivity_before.take()
        {
            self.window.set_sensitive(sensitive);
        }
    }

    pub(super) fn grid_edits_prepared(
        &mut self,
        intent: GridCloseIntent,
        ticket: u64,
        result: Result<(), String>,
        sender: ComponentSender<Self>,
    ) {
        let Some(owners) = self.grid_close.owners.remove(&ticket) else {
            return;
        };
        let unchanged = owners.iter().all(|(id, expected)| {
            let tabs = self.workspace_tabs.borrow();
            pending_grid_close_owner_is_current(expected, tabs.get(id).map(tab_page))
        });
        let accepted = unchanged && result.is_ok();
        if !self.grid_close.preparation.complete(intent.clone(), ticket, accepted) {
            return;
        }
        if !unchanged {
            self.restore_after_grid_preparation();
            return;
        }
        if let Err(message) = result {
            self.restore_after_grid_preparation();
            if let GridCloseIntent::Tab(id) = intent {
                let page = self.workspace_tabs.borrow().get(&id).map(|tab| tab_page(tab).clone());
                if let Some(view) = &self.workspace_tab_view
                    && let Some(page) = page
                {
                    view.close_page_finish(&page, false);
                }
            }
            self.show_error_alert(&crate::tr!("Could not finish the cell edit"), &message);
            return;
        }
        sender.input(intent.message());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires isolated GTK display"]
    fn a_pending_grid_flush_matches_only_its_original_tab_page() {
        relm4::adw::init().unwrap();
        let original_view = adw::TabView::new();
        let original_page = original_view.append(&relm4::gtk::Box::new(relm4::gtk::Orientation::Vertical, 0));
        let expected = original_page.downgrade();
        let replacement_view = adw::TabView::new();
        let replacement_page = replacement_view.append(&relm4::gtk::Box::new(relm4::gtk::Orientation::Vertical, 0));

        assert!(pending_grid_close_owner_is_current(&expected, Some(&original_page)));
        assert!(!pending_grid_close_owner_is_current(&expected, Some(&replacement_page)));
        assert!(!pending_grid_close_owner_is_current(&expected, None));
    }
}
