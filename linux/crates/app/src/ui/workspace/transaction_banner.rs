//! The banner that names an editor tab still holding a transaction, on
//! every other tab of the window. The owning tab says so above its
//! results, where Commit and Roll Back are, since the transaction lives
//! on that tab's own session.

use libadwaita as adw;
use uuid::Uuid;

use super::{WorkspaceInput, WorkspaceModel, WorkspaceSender, WorkspaceTab};
use crate::runtime::DeliverInput;
use crate::ui::editor::OpenTransaction;

#[derive(Debug, Clone)]
struct HeldTransaction {
    id: Uuid,
    title: String,
    transaction: OpenTransaction,
    selected: bool,
}

#[derive(Debug, PartialEq, Eq)]
struct TransactionBanner {
    title: String,
    /// The tab Show brings to the front.
    target: Uuid,
}

/// `held` is in tab bar order, and Show goes to the first of them.
fn transaction_banner(held: &[HeldTransaction]) -> Option<TransactionBanner> {
    let others: Vec<&HeldTransaction> = held.iter().filter(|tab| !tab.selected).collect();
    let first = others.first()?;
    let title = match others.as_slice() {
        [only] => {
            let tab = [("tab", only.title.as_str())];
            match only.transaction {
                OpenTransaction::Open => crate::i18n::gettext_f("“{tab}” has an open transaction", &tab),
                OpenTransaction::Failed => crate::i18n::gettext_f("“{tab}” has a failed transaction", &tab),
            }
        }
        several => crate::i18n::ngettext_f(
            "{n} editor tab has an open transaction",
            "{n} editor tabs have open transactions",
            u32::try_from(several.len()).unwrap_or(u32::MAX),
            &[("n", &several.len().to_string())],
        ),
    };
    Some(TransactionBanner {
        title,
        target: first.id,
    })
}

pub(super) fn connect_show(banner: &adw::Banner, input: &WorkspaceSender) {
    let input = input.clone();
    banner.connect_button_clicked(move |_| input.deliver(WorkspaceInput::ShowTransactionTab));
}

impl WorkspaceModel {
    pub(super) fn refresh_transaction_banner(&self) {
        match transaction_banner(&self.held_transactions()) {
            Some(banner) => {
                self.transaction_banner.set_title(&banner.title);
                self.transaction_banner.set_revealed(true);
            }
            None => self.transaction_banner.set_revealed(false),
        }
    }

    pub(super) fn show_transaction_tab(&self) {
        if let Some(banner) = transaction_banner(&self.held_transactions()) {
            self.focus_tab(banner.target);
        }
    }

    fn held_transactions(&self) -> Vec<HeldTransaction> {
        let selected = self.tab_view.selected_page();
        let tabs = self.workspace_tabs.borrow();
        (0..self.tab_view.n_pages())
            .map(|position| self.tab_view.nth_page(position))
            .filter_map(|page| {
                let id = self.index.id_of(&page)?;
                let WorkspaceTab::Editor(slot) = tabs.get(&id)? else {
                    return None;
                };
                Some(HeldTransaction {
                    id,
                    title: page.title().to_string(),
                    transaction: slot.editor.open_transaction()?,
                    selected: selected.as_ref() == Some(&page),
                })
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn held(title: &str, transaction: OpenTransaction, selected: bool) -> HeldTransaction {
        HeldTransaction {
            id: Uuid::new_v4(),
            title: title.to_owned(),
            transaction,
            selected,
        }
    }

    #[test]
    fn no_banner_without_a_transaction_on_another_tab() {
        assert_eq!(transaction_banner(&[]), None);
        assert_eq!(
            transaction_banner(&[held("Query 1", OpenTransaction::Open, true)]),
            None,
            "the tab in front names its own transaction"
        );
    }

    #[test]
    fn one_other_tab_is_named_and_shown() {
        let open = held("Query 2", OpenTransaction::Open, false);
        let failed = held("Query 3", OpenTransaction::Failed, false);

        assert_eq!(
            transaction_banner(std::slice::from_ref(&open)),
            Some(TransactionBanner {
                title: "“Query 2” has an open transaction".to_owned(),
                target: open.id,
            })
        );
        assert_eq!(
            transaction_banner(std::slice::from_ref(&failed)),
            Some(TransactionBanner {
                title: "“Query 3” has a failed transaction".to_owned(),
                target: failed.id,
            })
        );
    }

    #[test]
    fn the_tab_in_front_is_left_out_of_the_count() {
        let front = held("Query 1", OpenTransaction::Open, true);
        let other = held("Query 2", OpenTransaction::Failed, false);

        let banner = transaction_banner(&[front, other.clone()]).expect("a banner");

        assert_eq!(banner.title, "“Query 2” has a failed transaction");
        assert_eq!(banner.target, other.id);
    }

    #[test]
    fn several_tabs_are_counted_and_show_goes_to_the_first() {
        let first = held("Query 2", OpenTransaction::Failed, false);
        let tabs = [
            held("Query 1", OpenTransaction::Open, true),
            first.clone(),
            held("Query 3", OpenTransaction::Open, false),
        ];

        let banner = transaction_banner(&tabs).expect("a banner");

        assert_eq!(banner.title, "2 editor tabs have open transactions");
        assert_eq!(banner.target, first.id);
    }
}
