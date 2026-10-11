use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw};
use uuid::Uuid;

use super::types::read_workspace_tab_id;
use super::{App, AppMsg, SessionTeardownAction, WorkspaceTab};

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
        let mut targets = Vec::with_capacity(pages.n_items() as usize);
        for index in 0..pages.n_items() {
            let Some(page) = pages.item(index).and_downcast::<adw::TabPage>() else {
                continue;
            };
            if read_workspace_tab_id(&page) != Some(keep_id) {
                targets.push(page);
            }
        }
        for page in targets {
            tab_view.close_page(&page);
        }
    }

    pub(super) fn close_workspace_tabs_to_right(&mut self, anchor_id: Uuid, _sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let pages = tab_view.pages();
        let Some(anchor_index) = (0..pages.n_items()).find(|&index| {
            pages
                .item(index)
                .and_downcast::<adw::TabPage>()
                .is_some_and(|page| read_workspace_tab_id(&page) == Some(anchor_id))
        }) else {
            return;
        };
        let mut targets = Vec::new();
        for index in (anchor_index + 1)..pages.n_items() {
            if let Some(page) = pages.item(index).and_downcast::<adw::TabPage>() {
                targets.push(page);
            }
        }
        for page in targets {
            tab_view.close_page(&page);
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
