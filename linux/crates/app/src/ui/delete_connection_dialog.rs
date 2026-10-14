//! What a window asks before a saved connection is deleted.

use adw::prelude::*;
use libadwaita as adw;

use crate::services::connection_deletion::DeletionOptions;

pub(crate) const CANCEL: &str = "cancel";
pub(crate) const DELETE: &str = "delete";
pub(crate) const SHOW: &str = "show";

/// Asks to delete a saved connection, and whether the queries run on it
/// go too. The history stays unless the user says otherwise: it is the
/// record of what they ran, and the delete has no undo.
#[derive(Debug, Clone)]
pub(crate) struct DeleteConnectionDialog {
    pub dialog: adw::AlertDialog,
    pub history: adw::SwitchRow,
}

impl DeleteConnectionDialog {
    pub fn new(name: &str) -> Self {
        let dialog = adw::AlertDialog::new(
            Some(&crate::i18n::gettext_f("Delete “{name}”?", &[("name", name)])),
            Some(&crate::i18n::gettext(
                "The connection, its stored passwords and its saved queries will be removed. This cannot be undone.",
            )),
        );
        dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
        dialog.add_response(DELETE, &crate::i18n::gettext("Delete"));
        dialog.set_response_appearance(DELETE, adw::ResponseAppearance::Destructive);
        dialog.set_default_response(Some(CANCEL));
        dialog.set_close_response(CANCEL);
        let history = adw::SwitchRow::builder()
            .title(crate::i18n::gettext("Delete Query History"))
            .active(false)
            .build();
        let group = adw::PreferencesGroup::new();
        group.add(&history);
        dialog.set_extra_child(Some(&group));
        Self { dialog, history }
    }

    /// Say what the switch removes, once the history is counted.
    pub fn show_history_count(&self, count: u64) {
        if count == 0 {
            self.history
                .set_subtitle(&crate::i18n::gettext("No queries were run on this connection"));
            self.history.set_sensitive(false);
            return;
        }
        self.history.set_subtitle(&crate::i18n::ngettext_f(
            "Removes {n} query run on this connection",
            "Removes {n} queries run on this connection",
            u32::try_from(count).unwrap_or(u32::MAX),
            &[("n", &count.to_string())],
        ));
    }

    /// Run `chosen` with what the user picked when they press Delete.
    pub fn connect_delete(&self, chosen: impl Fn(DeletionOptions) + 'static) {
        // The row, not the dialog: the dialog holds this closure.
        let history = self.history.clone();
        self.dialog.connect_response(Some(DELETE), move |_, _| {
            chosen(DeletionOptions {
                delete_history: history.is_active(),
            });
        });
    }
}

/// Says a connection open in a window cannot be deleted from under it,
/// and offers to bring that window forward.
pub(crate) fn is_open_dialog(name: &str) -> adw::AlertDialog {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext_f("“{name}” Is Open", &[("name", name)])),
        Some(&crate::i18n::gettext(
            "Disconnect it or close its window, then delete it.",
        )),
    );
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(SHOW, &crate::i18n::gettext("Show Window"));
    dialog.set_response_appearance(SHOW, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(SHOW));
    dialog.set_close_response(CANCEL);
    dialog
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;

    #[gtk4::test]
    fn delete_dialog_has_history_switch_off_by_default() {
        adw::init().expect("libadwaita initialises under the test backend");

        let asking = DeleteConnectionDialog::new("Prod");

        assert_eq!(asking.dialog.heading().as_deref(), Some("Delete “Prod”?"));
        assert!(!asking.history.is_active(), "the history would go by default");
        assert!(asking.history.is_sensitive());
        assert_eq!(asking.dialog.default_response().as_deref(), Some(CANCEL));
        assert_eq!(asking.dialog.close_response(), CANCEL);
        assert_eq!(
            asking.dialog.response_appearance(DELETE),
            adw::ResponseAppearance::Destructive
        );
    }

    #[gtk4::test]
    fn the_history_switch_says_how_much_it_removes() {
        adw::init().expect("libadwaita initialises under the test backend");
        let asking = DeleteConnectionDialog::new("Prod");

        asking.show_history_count(12);
        assert!(asking.history.subtitle().is_some_and(|text| text.contains("12")));

        asking.show_history_count(0);
        assert!(
            !asking.history.is_sensitive(),
            "a switch that removes nothing is offered"
        );
    }

    #[gtk4::test]
    fn delete_hands_over_the_history_choice() {
        adw::init().expect("libadwaita initialises under the test backend");
        let asking = DeleteConnectionDialog::new("Prod");
        let chosen = Rc::new(Cell::new(None));
        let sink = chosen.clone();
        asking.connect_delete(move |options| sink.set(Some(options)));

        crate::test_support::respond(&asking.dialog, CANCEL);
        assert_eq!(chosen.get(), None, "Cancel deleted");
        asking.history.set_active(true);
        crate::test_support::respond(&asking.dialog, DELETE);

        assert_eq!(chosen.get(), Some(DeletionOptions { delete_history: true }));
    }

    #[gtk4::test]
    fn the_is_open_dialog_offers_the_window() {
        adw::init().expect("libadwaita initialises under the test backend");

        let dialog = is_open_dialog("Prod");

        assert_eq!(dialog.heading().as_deref(), Some("“Prod” Is Open"));
        assert!(dialog.has_response(SHOW));
        assert_eq!(dialog.close_response(), CANCEL);
    }
}
