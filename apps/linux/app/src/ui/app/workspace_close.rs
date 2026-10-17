use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw};
use uuid::Uuid;

use super::types::read_workspace_tab_id;
use super::{App, AppMsg, SessionTeardownAction, WorkspaceTab};

fn close_other_page_indexes(page_ids: &[Option<Uuid>], keep_id: Uuid) -> Vec<usize> {
    page_ids
        .iter()
        .enumerate()
        .filter_map(|(index, id)| (*id != Some(keep_id)).then_some(index))
        .collect()
}

fn close_page_indexes_to_right(page_ids: &[Option<Uuid>], anchor_id: Uuid) -> Vec<usize> {
    let Some(anchor) = page_ids.iter().position(|id| *id == Some(anchor_id)) else {
        return Vec::new();
    };
    ((anchor + 1)..page_ids.len()).collect()
}

impl App {
    pub(super) fn confirm_session_teardown(
        &self,
        sender: ComponentSender<Self>,
        action: SessionTeardownAction,
        heading: &str,
        body: &str,
        accept_label: &str,
    ) -> bool {
        let has_open_transaction = self.workspace_tabs.borrow().values().any(|tab| match tab {
            WorkspaceTab::Editor(slot) => {
                relm4::ComponentController::model(&slot.controller).session_transaction_open()
            }
            _ => false,
        });
        if !has_open_transaction {
            return false;
        }

        let dialog = adw::AlertDialog::new(Some(heading), Some(body));
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("confirm", accept_label);
        dialog.set_response_appearance("confirm", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let sender = sender.clone();
        dialog.connect_response(None, move |_, response| {
            let message = if response == "confirm" {
                AppMsg::ConfirmSessionTeardown(action)
            } else {
                AppMsg::CancelSessionTeardown(action)
            };
            sender.input(message);
        });
        dialog.present(Some(&self.window));
        true
    }

    pub(super) fn prepare_window_close(&mut self, sender: ComponentSender<Self>) {
        if !self.confirm_session_teardown(
            sender.clone(),
            SessionTeardownAction::WindowClose,
            &crate::tr!("Close with open session transactions?"),
            &crate::tr!("Open transactions will be rolled back before the window closes."),
            &crate::tr!("Roll Back and Close"),
        ) {
            self.prepare_editor_sessions(SessionTeardownAction::WindowClose, sender);
        }
    }

    pub(super) fn request_workspace_tab_close(&self, id: Uuid) {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            return;
        };
        let page = self.workspace_tabs.borrow().get(&id).map(|tab| match tab {
            WorkspaceTab::Editor(slot) => slot.page.clone(),
            WorkspaceTab::Structure(slot) => slot.page.clone(),
            WorkspaceTab::Table(slot) => slot.page.clone(),
        });
        if let Some(page) = page {
            tab_view.close_page(&page);
        }
    }

    pub(super) fn close_active_workspace_tab(&mut self, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.as_ref() else {
            self.window.close();
            return;
        };
        let Some(page) = tab_view.selected_page() else {
            self.window.close();
            return;
        };
        tab_view.close_page(&page);
        let _ = sender;
    }

    pub(super) fn close_other_workspace_tabs(&mut self, keep_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut page_ids = Vec::with_capacity(pages.n_items() as usize);
        let mut tab_pages = Vec::with_capacity(pages.n_items() as usize);
        for index in 0..pages.n_items() {
            let page = pages.item(index).and_downcast::<adw::TabPage>();
            page_ids.push(page.as_ref().and_then(read_workspace_tab_id));
            tab_pages.push(page);
        }
        for index in close_other_page_indexes(&page_ids, keep_id) {
            if let Some(page) = tab_pages.get(index).and_then(Option::as_ref) {
                tab_view.close_page(page);
            }
        }
    }

    pub(super) fn close_workspace_tabs_to_right(&mut self, anchor_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let mut page_ids = Vec::with_capacity(pages.n_items() as usize);
        let mut tab_pages = Vec::with_capacity(pages.n_items() as usize);
        for index in 0..pages.n_items() {
            let page = pages.item(index).and_downcast::<adw::TabPage>();
            page_ids.push(page.as_ref().and_then(read_workspace_tab_id));
            tab_pages.push(page);
        }
        for index in close_page_indexes_to_right(&page_ids, anchor_id) {
            if let Some(page) = tab_pages.get(index).and_then(Option::as_ref) {
                tab_view.close_page(page);
            }
        }
    }

    pub(super) fn confirm_close_with_open_transaction(
        &self,
        id: Uuid,
        tab_view: &adw::TabView,
        sender: ComponentSender<Self>,
    ) -> bool {
        let page = match self.workspace_tabs.borrow().get(&id) {
            Some(WorkspaceTab::Editor(slot))
                if relm4::ComponentController::model(&slot.controller).session_transaction_open() =>
            {
                slot.page.clone()
            }
            _ => return false,
        };
        let dialog = adw::AlertDialog::new(
            Some(&crate::tr!("Close with an open transaction?")),
            Some(&crate::tr!("The transaction is rolled back when the tab closes.")),
        );
        dialog.add_response("cancel", &crate::tr!("Cancel"));
        dialog.add_response("close", &crate::tr!("Roll Back and Close"));
        dialog.set_response_appearance("close", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let tab_view = tab_view.clone();
        dialog.connect_response(None, move |_, response| match response {
            "close" => sender.input(AppMsg::FinishCloseWorkspaceTab(id)),
            _ => tab_view.close_page_finish(&page, false),
        });
        dialog.present(Some(&self.window));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn close_other_targets_leave_the_selected_page_open() {
        let left = Uuid::new_v4();
        let keep = Uuid::new_v4();
        let right = Uuid::new_v4();
        let page_ids = [Some(left), Some(keep), Some(right)];

        assert_eq!(close_other_page_indexes(&page_ids, keep), vec![0, 2]);
    }

    #[test]
    fn close_right_targets_only_pages_after_the_anchor_in_current_order() {
        let left = Uuid::new_v4();
        let anchor = Uuid::new_v4();
        let right = Uuid::new_v4();
        let page_ids = [Some(left), Some(anchor), None, Some(right)];

        assert_eq!(close_page_indexes_to_right(&page_ids, anchor), vec![2, 3]);
    }

    #[test]
    fn a_missing_close_right_anchor_does_not_target_any_page() {
        let page_ids = [Some(Uuid::new_v4()), Some(Uuid::new_v4())];

        assert!(close_page_indexes_to_right(&page_ids, Uuid::new_v4()).is_empty());
    }
}
