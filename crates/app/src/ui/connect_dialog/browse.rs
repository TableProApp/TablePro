use relm4::adw::prelude::*;
use relm4::{adw, gtk};

fn picker_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::builder()
        .icon_name(icon)
        .tooltip_text(tooltip)
        .valign(gtk::Align::Center)
        .build();
    button.add_css_class("flat");
    button
}

fn file_filters(name: &str, patterns: &[&str]) -> gtk::gio::ListStore {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(name));
    for pattern in patterns {
        filter.add_pattern(pattern);
    }
    let filters = gtk::gio::ListStore::new::<gtk::FileFilter>();
    filters.append(&filter);
    filters
}

fn set_entry_from_file(entry: &adw::EntryRow, result: Result<gtk::gio::File, gtk::glib::Error>) {
    if let Ok(file) = result
        && let Some(path) = file.path()
    {
        entry.set_text(&path.to_string_lossy());
    }
}

fn parent_window(button: &gtk::Button) -> Option<gtk::Window> {
    button.root().and_then(|root| root.downcast::<gtk::Window>().ok())
}

pub(super) fn attach_certificate_picker(row: &adw::EntryRow) {
    attach_path_picker(
        row,
        &crate::tr!("Browse for certificate authority file"),
        &crate::tr!("Select certificate authority"),
        &crate::tr!("Certificates"),
        &["*.pem", "*.crt", "*.cer"],
    );
}

pub(super) fn attach_client_certificate_picker(row: &adw::EntryRow) {
    attach_path_picker(
        row,
        &crate::tr!("Browse for client certificate file"),
        &crate::tr!("Select client certificate"),
        &crate::tr!("Certificates"),
        &["*.pem", "*.crt", "*.cer"],
    );
}

pub(super) fn attach_client_key_picker(row: &adw::EntryRow) {
    attach_path_picker(
        row,
        &crate::tr!("Browse for client private key file"),
        &crate::tr!("Select client private key"),
        &crate::tr!("Private keys"),
        &["*.pem", "*.key"],
    );
}

fn attach_path_picker(row: &adw::EntryRow, tooltip: &str, title: &str, filter_name: &str, patterns: &[&str]) {
    let button = picker_button("document-open-symbolic", tooltip);
    let title = title.to_string();
    let filter_name = filter_name.to_string();
    let patterns: Vec<String> = patterns.iter().map(|pattern| (*pattern).to_string()).collect();
    let entry = row.clone();
    button.connect_clicked(move |button| {
        let pattern_refs: Vec<&str> = patterns.iter().map(String::as_str).collect();
        let dialog = gtk::FileDialog::builder()
            .title(&title)
            .modal(true)
            .filters(&file_filters(&filter_name, &pattern_refs))
            .build();
        let entry = entry.clone();
        dialog.open(
            parent_window(button).as_ref(),
            gtk::gio::Cancellable::NONE,
            move |result| set_entry_from_file(&entry, result),
        );
    });
    row.add_suffix(&button);
}

pub(super) fn attach_database_file_picker(row: &adw::EntryRow) -> gtk::Box {
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let open = picker_button(
        "document-open-symbolic",
        &crate::tr!("Choose an existing database file"),
    );
    let entry = row.clone();
    open.connect_clicked(move |button| {
        let dialog = gtk::FileDialog::builder()
            .title(crate::tr!("Choose database file"))
            .modal(true)
            .build();
        let entry = entry.clone();
        dialog.open(
            parent_window(button).as_ref(),
            gtk::gio::Cancellable::NONE,
            move |result| set_entry_from_file(&entry, result),
        );
    });
    let create = picker_button("document-new-symbolic", &crate::tr!("Create a new database file"));
    let entry = row.clone();
    create.connect_clicked(move |button| {
        let dialog = gtk::FileDialog::builder()
            .title(crate::tr!("Create database file"))
            .modal(true)
            .build();
        let entry = entry.clone();
        dialog.save(
            parent_window(button).as_ref(),
            gtk::gio::Cancellable::NONE,
            move |result| set_entry_from_file(&entry, result),
        );
    });
    buttons.append(&open);
    buttons.append(&create);
    row.add_suffix(&buttons);
    buttons
}
