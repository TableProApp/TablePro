use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::SavedConnection;
use uuid::Uuid;

use super::{boxed_list, bundle_file_filter, bundle_file_filters, checkbox_row, suggested_bundle_name};

/// What the export dialog collected. The passphrase is the only thing
/// that decides whether credentials travel: blank means a bundle with
/// no credentials at all, not a bundle with weaker protection.
pub(crate) struct ExportChoice {
    pub connections: Vec<Uuid>,
    pub passphrase: String,
    pub path: std::path::PathBuf,
}

impl std::fmt::Debug for ExportChoice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExportChoice")
            .field("connections", &self.connections.len())
            .field("encrypted", &!self.passphrase.is_empty())
            .finish_non_exhaustive()
    }
}

pub(crate) fn present_export_dialog(
    parent: &adw::ApplicationWindow,
    connections: &[SavedConnection],
    today: String,
    on_choice: impl Fn(ExportChoice) + 'static,
) {
    let dialog = adw::AlertDialog::new(
        Some(&crate::tr!("Export connections")),
        Some(&crate::tr!(
            "Choose the connections to put in the file. Without a passphrase the file carries no passwords. With one, saved database and SSH passwords are encrypted into it. MCP tokens are never exported."
        )),
    );

    let list = boxed_list();
    let mut checks: Vec<(Uuid, gtk::CheckButton)> = Vec::with_capacity(connections.len());
    for connection in connections {
        let (row, check) = checkbox_row(&connection.name, &connection.driver_id, true);
        list.append(&row);
        checks.push((connection.id, check));
    }

    let passphrase = adw::PasswordEntryRow::builder()
        .title(crate::tr!("Passphrase (optional)"))
        .build();
    let passphrase_list = boxed_list();
    passphrase_list.append(&passphrase);

    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .build();
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .max_content_height(320)
        .propagate_natural_height(true)
        .child(&list)
        .build();
    body.append(&scroller);
    body.append(&passphrase_list);
    dialog.set_extra_child(Some(&body));

    dialog.add_response("cancel", &crate::tr!("Cancel"));
    dialog.add_response("export", &crate::tr!("Choose File…"));
    dialog.set_response_appearance("export", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("export"));
    dialog.set_close_response("cancel");

    let window = parent.clone();
    let on_choice: Rc<dyn Fn(ExportChoice)> = Rc::new(on_choice);
    dialog.connect_response(None, move |dlg, response| {
        dlg.close();
        if response != "export" {
            return;
        }
        let picked: Vec<Uuid> = checks
            .iter()
            .filter(|(_, check)| check.is_active())
            .map(|(id, _)| *id)
            .collect();
        if picked.is_empty() {
            return;
        }
        choose_destination(&window, picked, passphrase.text().to_string(), &today, &on_choice);
    });
    dialog.present(Some(parent));
}

fn choose_destination(
    parent: &adw::ApplicationWindow,
    connections: Vec<Uuid>,
    passphrase: String,
    today: &str,
    on_choice: &Rc<dyn Fn(ExportChoice)>,
) {
    let filter = bundle_file_filter();
    let file_dialog = gtk::FileDialog::builder()
        .title(crate::tr!("Export connections"))
        .modal(true)
        .initial_name(suggested_bundle_name(today))
        .default_filter(&filter)
        .filters(&bundle_file_filters(&filter))
        .build();

    let on_choice = Rc::clone(on_choice);
    file_dialog.save(Some(parent), relm4::gtk::gio::Cancellable::NONE, move |outcome| {
        let Ok(file) = outcome else {
            return;
        };
        let Some(path) = file.path() else {
            return;
        };
        on_choice(ExportChoice {
            connections: connections.clone(),
            passphrase: passphrase.clone(),
            path,
        });
    });
}
