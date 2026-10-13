use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;

use super::dialog_response::respond;
use super::{DirtyKind, DirtyTab, UnknownCause};

const KEEP: &str = "cancel";
const RELOAD: &str = "reload";
const DISCARD: &str = "discard";

/// What the user chose for saves that may have landed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UnknownChoice {
    KeepOpen,
    /// Read the tables again to see what is there, and stay open.
    Reload,
    /// Drop the changes and go on closing.
    Discard,
}

pub(crate) async fn resolve_unknown_outcome(parent: &gtk::Widget, tabs: &[DirtyTab]) -> UnknownChoice {
    let dialog = adw::AlertDialog::new(Some(&crate::i18n::gettext("Save Result Unknown")), Some(&body(tabs)));
    dialog.add_response(KEEP, &crate::i18n::gettext("_Keep Open"));
    dialog.add_response(RELOAD, &crate::i18n::gettext("_Reload Table"));
    dialog.add_response(DISCARD, &crate::i18n::gettext("_Discard Changes"));
    dialog.set_response_appearance(DISCARD, adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some(RELOAD));
    dialog.set_close_response(KEEP);
    match respond(&dialog, parent).await.as_str() {
        RELOAD => UnknownChoice::Reload,
        DISCARD => UnknownChoice::Discard,
        _ => UnknownChoice::KeepOpen,
    }
}

/// One sentence for each cause the user is told apart, naming the tabs
/// it happened to.
fn body(tabs: &[DirtyTab]) -> String {
    let mut groups: Vec<(&UnknownCause, Vec<DirtyTab>)> = Vec::new();
    for tab in tabs {
        let DirtyKind::OutcomeUnknown(cause) = &tab.kind else {
            continue;
        };
        match groups.iter_mut().find(|(seen, _)| seen.reads_as(cause)) {
            Some((_, members)) => members.push(tab.clone()),
            None => groups.push((cause, vec![tab.clone()])),
        }
    }
    let sentences: Vec<String> = groups
        .iter()
        .map(|(cause, members)| cause.sentence(&DirtyTab::names(members)))
        .collect();
    sentences.join("\n\n")
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    fn tab(title: &str, cause: UnknownCause) -> DirtyTab {
        DirtyTab {
            id: Uuid::new_v4(),
            title: title.to_owned(),
            kind: DirtyKind::OutcomeUnknown(cause),
        }
    }

    #[test]
    fn each_tab_is_told_its_own_cause() {
        let tabs = [
            tab("orders", UnknownCause::Interrupted),
            tab("users", UnknownCause::CommitAckLost { token: None }),
            tab("items", UnknownCause::Closed),
        ];

        assert_eq!(
            body(&tabs),
            "Saving “orders” was stopped before the database confirmed it. The changes may already be in the \
             database.\n\nThe connection was lost while saving “users”, “items”. The changes may already be in the \
             database."
        );
    }
}
