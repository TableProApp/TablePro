use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::ImportItem;
use uuid::Uuid;

use super::{boxed_list, checkbox_row, disposition_detail, disposition_title};

/// Ask for the passphrase of an encrypted bundle. There is deliberately
/// no "remember this passphrase" affordance: the passphrase protects a
/// file that leaves this machine, and storing it here would undo that.
pub(crate) fn present_import_passphrase_dialog(
    parent: &adw::ApplicationWindow,
    on_passphrase: impl Fn(String) + 'static,
) {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("This file is protected")),
        Some(&crate::tr!("Enter the passphrase it was exported with.")),
    );
    let entry = adw::PasswordEntryRow::builder().title(crate::tr!("Passphrase")).build();
    let list = boxed_list();
    list.append(&entry);
    dialog.set_extra_child(Some(&list));
    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("unlock", &crate::tr!("Unlock"));
    dialog.set_response_appearance("unlock", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("unlock"));
    dialog.set_close_response("cancel");

    dialog.connect_response(None, move |dlg, response| {
        dlg.close();
        if response != "unlock" {
            return;
        }
        on_passphrase(entry.text().to_string());
    });
    dialog.present(Some(parent));
}

fn build_replace_switch(carries_secrets: bool) -> adw::SwitchRow {
    adw::SwitchRow::builder()
        .title(crate::tr!("Replace saved passwords"))
        .subtitle(crate::tr!("Off keeps the passwords already on this device."))
        .active(false)
        .visible(carries_secrets)
        .build()
}

fn build_plan_body(list: &gtk::ListBox, replace: &adw::SwitchRow, carries_secrets: bool) -> gtk::Box {
    let options = boxed_list();
    options.append(replace);
    options.set_visible(carries_secrets);
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(320)
        .propagate_natural_height(true)
        .child(list)
        .build();
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    body.append(&scroller);
    body.append(&options);
    body
}

/// What the user approved in the import preview.
#[derive(Debug)]
pub(crate) struct ImportChoice {
    pub accepted: Vec<Uuid>,
    pub replace_saved_passwords: bool,
}

/// Show every planned change before anything is written. Nothing in the
/// import path deletes a local connection, so the preview only ever
/// offers to add or update.
pub(crate) fn present_import_plan_dialog(
    parent: &adw::ApplicationWindow,
    items: &[ImportItem],
    carries_secrets: bool,
    on_confirm: impl Fn(ImportChoice) + 'static,
) {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("Import connections")),
        Some(&crate::tr!(
            "These changes have not been made yet. Connections already on this device that the file does not mention are left alone."
        )),
    );

    let list = boxed_list();
    let mut checks: Vec<(Uuid, gtk::CheckButton)> = Vec::with_capacity(items.len());
    for item in items {
        let subtitle = format!("{} · {}", disposition_title(item), disposition_detail(item));
        let (row, check) = checkbox_row(&item.connection.name, &subtitle, true);
        list.append(&row);
        checks.push((item.source_id, check));
    }

    let replace = build_replace_switch(carries_secrets);
    dialog.set_extra_child(Some(&build_plan_body(&list, &replace, carries_secrets)));

    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("import", &crate::tr!("Import"));
    dialog.set_response_appearance("import", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("cancel"));
    dialog.set_close_response("cancel");

    let on_confirm: Rc<dyn Fn(ImportChoice)> = Rc::new(on_confirm);
    dialog.connect_response(None, move |dlg, response| {
        dlg.close();
        if response != "import" {
            return;
        }
        let accepted: Vec<Uuid> = checks
            .iter()
            .filter(|(_, check)| check.is_active())
            .map(|(id, _)| *id)
            .collect();
        if accepted.is_empty() {
            return;
        }
        on_confirm(ImportChoice {
            accepted,
            replace_saved_passwords: replace.is_active(),
        });
    });
    dialog.present(Some(parent));
}
