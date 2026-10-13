use std::cell::Cell;

use relm4::adw::prelude::*;
use relm4::{ComponentSender, adw};

use super::{App, AppMsg, WorkspaceTab};

/// What closing the workspace would throw away.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) struct WorkspaceLoss {
    pub(super) unsaved_edits: bool,
    pub(super) open_transactions: bool,
}

impl WorkspaceLoss {
    pub(super) fn is_empty(self) -> bool {
        !self.unsaved_edits && !self.open_transactions
    }

    fn body(self) -> String {
        match (self.unsaved_edits, self.open_transactions) {
            (true, true) => crate::i18n::gettext(
                "Every tab closes. Unsaved row edits and structure changes are lost, and the server rolls back each open editor transaction.",
            ),
            (false, true) => {
                crate::i18n::gettext("Every tab closes, and the server rolls back each open editor transaction.")
            }
            _ => crate::i18n::gettext("Every tab closes, and unsaved row edits and structure changes are lost."),
        }
    }
}

/// Why the workspace is closing, which names the button that confirms it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Teardown {
    Disconnect,
    Switch,
}

impl App {
    pub(super) fn workspace_loss(&self) -> WorkspaceLoss {
        let unsaved_edits = !self.dirty_tabs().is_empty();
        let open_transactions = self
            .workspace_tabs
            .borrow()
            .values()
            .any(|tab| matches!(tab, WorkspaceTab::Editor(slot) if slot.editor.has_open_transaction()));
        WorkspaceLoss {
            unsaved_edits,
            open_transactions,
        }
    }

    /// Send `proceed` once the user agrees to lose what the workspace
    /// holds, or at once when it holds nothing.
    pub(super) fn confirm_teardown(&self, teardown: Teardown, proceed: AppMsg, sender: ComponentSender<Self>) {
        let loss = self.workspace_loss();
        if loss.is_empty() {
            sender.input(proceed);
            return;
        }
        let (heading, confirm) = match teardown {
            Teardown::Disconnect => (
                crate::i18n::gettext("Disconnect and Discard Changes?"),
                crate::i18n::gettext("Discard and Disconnect"),
            ),
            Teardown::Switch => (
                crate::i18n::gettext("Switch Connection and Discard Changes?"),
                crate::i18n::gettext("Discard and Switch"),
            ),
        };
        let dialog = adw::AlertDialog::new(Some(&heading), Some(&loss.body()));
        dialog.add_response("cancel", &crate::i18n::gettext("Cancel"));
        dialog.add_response("discard", &confirm);
        dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some("cancel"));
        dialog.set_close_response("cancel");
        let proceed = Cell::new(Some(proceed));
        dialog.connect_response(None, move |_, response| {
            if response == "discard"
                && let Some(message) = proceed.take()
            {
                sender.input(message);
            }
        });
        dialog.present(Some(&self.window));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_kind_of_loss_has_its_own_explanation() {
        let edits = WorkspaceLoss {
            unsaved_edits: true,
            open_transactions: false,
        };
        let transactions = WorkspaceLoss {
            unsaved_edits: false,
            open_transactions: true,
        };
        let both = WorkspaceLoss {
            unsaved_edits: true,
            open_transactions: true,
        };

        assert!(WorkspaceLoss::default().is_empty());
        assert!(!edits.is_empty() && !transactions.is_empty());
        assert!(edits.body().contains("edits") && !edits.body().contains("transaction"));
        assert!(transactions.body().contains("transaction") && !transactions.body().contains("edits"));
        assert!(both.body().contains("edits") && both.body().contains("transaction"));
    }
}
