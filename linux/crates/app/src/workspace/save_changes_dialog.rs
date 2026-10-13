use gtk4 as gtk;
use libadwaita as adw;
use libadwaita::prelude::*;
use uuid::Uuid;

use super::DirtyTab;
use super::dialog_response::respond;

const CANCEL: &str = "cancel";
const DISCARD: &str = "discard";
const SAVE: &str = "save";

/// What the user chose for tabs with unsaved changes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SaveChoice {
    Cancel,
    /// Save the tabs that stayed checked and drop the rest.
    Proceed {
        save: Vec<Uuid>,
        discard: Vec<Uuid>,
    },
}

/// Ask which of `tabs` to save, as GNOME Text Editor does: every tab
/// listed with a check box, all checked.
pub(crate) async fn ask_save_changes(parent: &gtk::Widget, tabs: &[DirtyTab]) -> SaveChoice {
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::gettext("Save Changes?")),
        Some(&crate::i18n::gettext(
            "Changes that are not saved are permanently lost.",
        )),
    );
    let group = adw::PreferencesGroup::new();
    let checks: Vec<(Uuid, gtk::CheckButton)> = tabs
        .iter()
        .map(|tab| {
            let check = gtk::CheckButton::builder()
                .active(true)
                .valign(gtk::Align::Center)
                .build();
            let row = adw::ActionRow::builder().title(&tab.title).use_markup(false).build();
            row.add_prefix(&check);
            row.set_activatable_widget(Some(&check));
            let label: &gtk::Widget = row.upcast_ref();
            check.update_relation(&[gtk::accessible::Relation::LabelledBy(&[label.upcast_ref()])]);
            group.add(&row);
            (tab.id, check)
        })
        .collect();
    dialog.set_extra_child(Some(&group));
    dialog.set_prefer_wide_layout(tabs.len() > 1);
    let discard_label = match tabs.len() {
        1 => crate::i18n::gettext("_Discard"),
        _ => crate::i18n::gettext("_Discard All"),
    };
    dialog.add_response(CANCEL, &crate::i18n::gettext("_Cancel"));
    dialog.add_response(DISCARD, &discard_label);
    dialog.add_response(SAVE, &crate::i18n::gettext("_Save"));
    dialog.set_response_appearance(DISCARD, adw::ResponseAppearance::Destructive);
    dialog.set_response_appearance(SAVE, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    match respond(&dialog, parent).await.as_str() {
        SAVE => {
            let (save, discard): (Vec<_>, Vec<_>) = checks.iter().partition(|(_, check)| check.is_active());
            SaveChoice::Proceed {
                save: save.into_iter().map(|(id, _)| *id).collect(),
                discard: discard.into_iter().map(|(id, _)| *id).collect(),
            }
        }
        DISCARD => SaveChoice::Proceed {
            save: Vec::new(),
            discard: tabs.iter().map(|tab| tab.id).collect(),
        },
        _ => SaveChoice::Cancel,
    }
}
