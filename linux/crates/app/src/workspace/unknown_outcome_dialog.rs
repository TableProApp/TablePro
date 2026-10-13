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
    let cause = tabs
        .iter()
        .find_map(|tab| match &tab.kind {
            DirtyKind::OutcomeUnknown(cause) => Some(cause.clone()),
            _ => None,
        })
        .unwrap_or(UnknownCause::Interrupted);
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Save Result Unknown")),
        Some(&cause.sentence(&DirtyTab::names(tabs))),
    );
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
