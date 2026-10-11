use relm4::adw::prelude::*;
use relm4::{adw, gtk};

use tablepro_storage::{ImportDisposition, ImportItem, SavedConnection};
use uuid::Uuid;

mod export;
mod import;

pub(crate) use export::{ExportChoice, present_export_dialog};
pub(crate) use import::{ImportChoice, present_import_passphrase_dialog, present_import_plan_dialog};

pub(crate) const BUNDLE_EXTENSION: &str = "bookie-connections";
pub(crate) const BUNDLE_MIME_TYPE: &str = "application/json";

/// Suggested file name for an exported bundle. Dated so a user who
/// exports twice does not silently overwrite the first file.
pub(crate) fn suggested_bundle_name(today: &str) -> String {
    format!("bookie-connections-{today}.{BUNDLE_EXTENSION}")
}

pub(crate) fn bundle_file_filter() -> gtk::FileFilter {
    let filter = gtk::FileFilter::new();
    filter.set_name(Some(&crate::tr!("Connection bundles")));
    filter.add_suffix(BUNDLE_EXTENSION);
    filter.add_mime_type(BUNDLE_MIME_TYPE);
    filter
}

pub(crate) fn bundle_file_filters(filter: &gtk::FileFilter) -> relm4::gtk::gio::ListStore {
    let filters = relm4::gtk::gio::ListStore::new::<gtk::FileFilter>();
    filters.append(filter);
    filters
}

fn boxed_list() -> gtk::ListBox {
    gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .css_classes(["boxed-list"])
        .build()
}

/// What the import preview says will happen to one entry. The wording
/// names the outcome rather than the internal disposition, because the
/// user is deciding whether to let it happen.
pub(crate) fn disposition_title(item: &ImportItem) -> String {
    match item.disposition {
        ImportDisposition::New => crate::tr!("Add"),
        ImportDisposition::UpdateInPlace => crate::tr!("Update"),
        ImportDisposition::Remapped => crate::tr!("Add as a new connection"),
    }
}

pub(crate) fn disposition_detail(item: &ImportItem) -> String {
    match item.disposition {
        ImportDisposition::New => crate::tr!("Not on this device yet."),
        ImportDisposition::UpdateInPlace => {
            crate::tr!("Updates the matching connection. Read-only, environment and TLS are never relaxed.")
        }
        ImportDisposition::Remapped => {
            crate::tr!("A different server already uses this entry's identifier here, so the import keeps both.")
        }
    }
}

/// The line shown after an import finishes. A partial import has to say
/// so plainly, because the user has to know which half landed.
pub(crate) fn import_outcome_message(imported: usize, planned: usize) -> String {
    if imported == planned {
        return crate::tr!("Imported {n} connections.").replace("{n}", &imported.to_string());
    }
    crate::tr!("Imported {n} of {total} connections, then stopped.")
        .replace("{n}", &imported.to_string())
        .replace("{total}", &planned.to_string())
}

/// Connections the user ticked, in the order the list showed them.
pub(crate) fn selected_connections(connections: &[SavedConnection], picked: &[Uuid]) -> Vec<SavedConnection> {
    connections
        .iter()
        .filter(|connection| picked.contains(&connection.id))
        .cloned()
        .collect()
}

fn checkbox_row(title: &str, subtitle: &str, active: bool) -> (adw::ActionRow, gtk::CheckButton) {
    let check = gtk::CheckButton::builder()
        .active(active)
        .valign(gtk::Align::Center)
        .build();
    let row = adw::ActionRow::builder().title(title).subtitle(subtitle).build();
    row.add_prefix(&check);
    row.set_activatable_widget(Some(&check));
    (row, check)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tablepro_core::{AuthMode, Environment, TlsMode};

    fn saved(name: &str) -> SavedConnection {
        SavedConnection {
            id: Uuid::new_v4(),
            name: name.into(),
            driver_id: "postgres".into(),
            host: "localhost".into(),
            port: 5432,
            socket_dir: None,
            database: "app".into(),
            username: "app".into(),
            use_tls: false,
            tls_mode: Some(TlsMode::Disabled),
            tls_root_cert: None,
            tls_client_cert: None,
            tls_client_key: None,
            read_only: false,
            auth_mode: AuthMode::Password,
            environment: Environment::Local,
            ssh: None,
            last_opened_at: None,
            connect_timeout_secs: None,
            query_timeout_secs: None,
        }
    }

    fn item(disposition: ImportDisposition) -> ImportItem {
        ImportItem {
            disposition,
            source_id: Uuid::new_v4(),
            connection: saved("incoming"),
            previous: None,
            organization: None,
        }
    }

    #[test]
    fn the_suggested_file_name_is_dated_and_carries_the_bundle_extension() {
        let name = suggested_bundle_name("2026-09-19");
        assert!(name.starts_with("bookie-connections-2026-09-19"));
        assert!(name.ends_with(".bookie-connections"));
    }

    #[test]
    fn every_disposition_has_its_own_wording() {
        let titles = [
            disposition_title(&item(ImportDisposition::New)),
            disposition_title(&item(ImportDisposition::UpdateInPlace)),
            disposition_title(&item(ImportDisposition::Remapped)),
        ];
        assert_eq!(titles.iter().collect::<std::collections::HashSet<_>>().len(), 3);
        for disposition in [
            ImportDisposition::New,
            ImportDisposition::UpdateInPlace,
            ImportDisposition::Remapped,
        ] {
            assert!(!disposition_detail(&item(disposition)).is_empty());
        }
    }

    #[test]
    fn a_remapped_entry_says_both_connections_are_kept() {
        let detail = disposition_detail(&item(ImportDisposition::Remapped));
        assert!(detail.contains("keeps both"));
    }

    #[test]
    fn a_partial_import_says_how_far_it_got() {
        assert_eq!(import_outcome_message(3, 3), "Imported 3 connections.");
        assert_eq!(
            import_outcome_message(1, 4),
            "Imported 1 of 4 connections, then stopped."
        );
    }

    #[test]
    fn only_ticked_connections_are_exported() {
        let first = saved("a");
        let second = saved("b");
        let third = saved("c");
        let all = vec![first.clone(), second.clone(), third.clone()];

        let picked = selected_connections(&all, &[third.id, first.id]);

        assert_eq!(
            picked.iter().map(|c| c.id).collect::<Vec<_>>(),
            vec![first.id, third.id]
        );
    }

    #[test]
    fn nothing_ticked_exports_nothing() {
        assert!(selected_connections(&[saved("a")], &[]).is_empty());
    }
}
