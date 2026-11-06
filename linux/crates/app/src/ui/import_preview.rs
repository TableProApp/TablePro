use gtk4 as gtk;
use gtk4::{gio, glib};
use libadwaita as adw;
use libadwaita::prelude::*;
use tablepro_core::{AiPolicy, DriverCapabilities, DriverRegistry, ExternalAccess, TlsMode};
use tablepro_storage::{ImportChange, ImportEntry, ImportPreview, SavedSshConfig};

use crate::services::saved_connection_object::subtitle_for;
use crate::ui::connect_dialog::ConnectForm;

pub(crate) const IMPORT: &str = "import";
const CANCEL: &str = "cancel";

/// The list a file can bring is long only when the user exported a long
/// one, so it scrolls past this height rather than growing the dialog.
const MAX_LIST_HEIGHT: i32 = 320;

/// The question before an import writes anything. Each connection shows
/// where it connects, so a name that matches a saved one but points at
/// another host is seen before it is saved.
pub(crate) fn import_preview_dialog(preview: &ImportPreview, drivers: &DriverRegistry) -> adw::AlertDialog {
    let count = preview.entries().len();
    let dialog = adw::AlertDialog::new(
        Some(&crate::i18n::ngettext_f(
            "Import {n} Connection?",
            "Import {n} Connections?",
            count,
            &[("n", &count.to_string())],
        )),
        Some(&crate::i18n::gettext(
            "Check where each one connects. A file you did not export yourself can point anywhere.",
        )),
    );
    let rows = gio::ListStore::new::<glib::BoxedAnyObject>();
    for entry in preview.entries() {
        rows.append(&glib::BoxedAnyObject::new(entry_text(entry, drivers)));
    }
    // A list view builds only the rows on screen, so a file of thousands of connections opens as fast as three.
    // boxed-list styles a GtkListBox only; a card with separators draws the same box.
    let list = gtk::ListView::builder()
        .model(&gtk::NoSelection::new(Some(rows)))
        .factory(&row_factory())
        .show_separators(true)
        .css_classes(["rich-list", "card"])
        .overflow(gtk::Overflow::Hidden)
        .build();
    let scrolled = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(MAX_LIST_HEIGHT)
        .child(&list)
        .build();
    dialog.set_extra_child(Some(&scrolled));
    dialog.add_response(CANCEL, &crate::i18n::gettext("Cancel"));
    dialog.add_response(IMPORT, &crate::i18n::gettext("Import"));
    dialog.set_response_appearance(IMPORT, adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some(CANCEL));
    dialog.set_close_response(CANCEL);
    dialog
}

/// What one row shows.
struct EntryText {
    title: String,
    subtitle: String,
}

fn entry_text(entry: &ImportEntry, drivers: &DriverRegistry) -> EntryText {
    let saved = &entry.connection;
    let caps = drivers.get(&saved.driver_id).map(|driver| driver.capabilities());
    let file_based = caps.is_some_and(DriverCapabilities::is_file_based);
    let change = match entry.change {
        ImportChange::Added => crate::i18n::gettext("New"),
        ImportChange::Updated { .. } => crate::i18n::gettext("Updated"),
    };
    let mut lines = vec![format!("{change} · {}", subtitle_for(saved, file_based, None))];
    match &entry.change {
        ImportChange::Added => {
            if !file_based {
                lines.extend(saved.ssh.as_ref().map(ssh_hop));
            }
            if let Some(caps) = caps {
                let new_connection = ConnectForm::new(&saved.driver_id, caps).tls.mode;
                lines.extend(looser_tls(saved.tls.mode, new_connection));
            }
            lines.extend(looser_settings(saved.external_access, saved.ai_policy));
        }
        // An updated entry keeps its own settings; only the list's labels
        // come from the file.
        ImportChange::Updated { renamed_from } => {
            if let Some(name) = renamed_from.as_deref() {
                lines.push(crate::i18n::gettext_f("Renamed from “{name}”", &[("name", name)]));
            }
        }
    }
    EntryText {
        title: saved.name.clone(),
        subtitle: lines.join("\n"),
    }
}

fn row_factory() -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(|_, object| {
        if let Some(item) = object.downcast_ref::<gtk::ListItem>() {
            item.set_activatable(false);
            item.set_child(Some(&EntryRow::new().root));
        }
    });
    factory.connect_bind(|_, object| {
        let Some(item) = object.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let (Some(row), Some(text)) = (
            item.child().and_then(|child| EntryRow::of(&child)),
            item.item().and_downcast::<glib::BoxedAnyObject>(),
        ) else {
            return;
        };
        let text = text.borrow::<EntryText>();
        row.title.set_label(&text.title);
        row.subtitle.set_label(&text.subtitle);
        // The row is labels only, so the item carries what a screen reader says.
        item.set_accessible_label(&text.title);
        item.set_accessible_description(&text.subtitle);
    });
    factory
}

// A list item's child is a plain widget: a GtkListBoxRow such as AdwActionRow belongs in a GtkListBox only.
struct EntryRow {
    root: gtk::Box,
    title: gtk::Label,
    subtitle: gtk::Label,
}

impl EntryRow {
    fn new() -> Self {
        // The file's names and hosts stay text: a GtkLabel reads markup only when told to.
        let title = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .build();
        let subtitle = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(gtk::pango::WrapMode::WordChar)
            .css_classes(["dim-label", "caption"])
            .build();
        let text = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(2)
            .hexpand(true)
            .valign(gtk::Align::Center)
            .build();
        text.append(&title);
        text.append(&subtitle);
        // rich-list spaces the children of a row's box, so the labels sit one box further in.
        let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        root.append(&text);
        Self { root, title, subtitle }
    }

    fn of(child: &gtk::Widget) -> Option<Self> {
        let root = child.clone().downcast::<gtk::Box>().ok()?;
        let text = root.first_child()?;
        let title = text.first_child().and_downcast::<gtk::Label>()?;
        let subtitle = title.next_sibling().and_downcast::<gtk::Label>()?;
        Some(Self { root, title, subtitle })
    }
}

/// The SSH server the connection goes through, after any jump hosts.
fn ssh_hop(ssh: &SavedSshConfig) -> String {
    let host = match ssh.port {
        Some(port) => format!("{}:{port}", ssh.host),
        None => ssh.host.clone(),
    };
    let target = match ssh.username.as_deref().filter(|user| !user.is_empty()) {
        Some(user) => format!("{user}@{host}"),
        None => host,
    };
    if ssh.jump_hosts.is_empty() {
        crate::i18n::gettext_f("Through SSH to {target}", &[("target", &target)])
    } else {
        crate::i18n::gettext_f(
            "Through SSH to {target} via {jumps}",
            &[("target", &target), ("jumps", &ssh.jump_hosts.join(", "))],
        )
    }
}

/// What the file's TLS mode skips that a new connection of the same
/// driver checks.
fn looser_tls(mode: TlsMode, new_connection: TlsMode) -> Option<String> {
    if new_connection.encrypts() && !mode.encrypts() {
        return Some(crate::i18n::gettext("Connects without TLS"));
    }
    if new_connection.verifies_certificate() && !mode.verifies_certificate() {
        return Some(crate::i18n::gettext(
            "Connects over TLS without checking the certificate",
        ));
    }
    if new_connection == TlsMode::Strict && mode != TlsMode::Strict {
        return Some(crate::i18n::gettext("Connects without strict encryption"));
    }
    None
}

/// What the file allows beyond what a new connection starts with.
fn looser_settings(access: ExternalAccess, policy: AiPolicy) -> Vec<String> {
    let mut lines = Vec::new();
    if access == ExternalAccess::ReadWrite {
        lines.push(crate::i18n::gettext("MCP clients can ask to write"));
    }
    if policy == AiPolicy::Allow {
        lines.push(crate::i18n::gettext("The AI assistant reads without asking"));
    }
    lines
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use tablepro_core::{AuthMode, SafeModeLevel, TlsConfig};
    use tablepro_storage::{SavedConnection, SavedSshAuth};
    use tablepro_test_support::{ConnectionScript, FakeDriver};
    use uuid::Uuid;

    use super::*;

    #[test]
    fn only_settings_looser_than_a_new_connections_are_called_out() {
        assert!(looser_settings(ExternalAccess::ReadOnly, AiPolicy::Ask).is_empty());
        assert!(looser_settings(ExternalAccess::Blocked, AiPolicy::Never).is_empty());
        assert_eq!(looser_settings(ExternalAccess::ReadWrite, AiPolicy::Allow).len(), 2);
    }

    #[test]
    fn only_tls_looser_than_a_new_connections_is_called_out() {
        assert_eq!(
            looser_tls(TlsMode::Disable, TlsMode::VerifyFull).as_deref(),
            Some("Connects without TLS")
        );
        assert_eq!(
            looser_tls(TlsMode::Require, TlsMode::VerifyFull).as_deref(),
            Some("Connects over TLS without checking the certificate")
        );
        assert_eq!(
            looser_tls(TlsMode::Disable, TlsMode::Require).as_deref(),
            Some("Connects without TLS")
        );
        assert_eq!(looser_tls(TlsMode::VerifyFull, TlsMode::VerifyFull), None);
        assert_eq!(looser_tls(TlsMode::Require, TlsMode::Require), None);
        // A driver without TLS starts a new connection with none.
        assert_eq!(looser_tls(TlsMode::Disable, TlsMode::Disable), None);
    }

    #[test]
    fn strict_checks_the_certificate_and_also_encrypts_the_prelogin_exchange() {
        for default in [TlsMode::Disable, TlsMode::Require, TlsMode::VerifyFull, TlsMode::Strict] {
            assert_eq!(looser_tls(TlsMode::Strict, default), None);
        }
        assert_eq!(
            looser_tls(TlsMode::VerifyFull, TlsMode::Strict).as_deref(),
            Some("Connects without strict encryption")
        );
        assert_eq!(
            looser_tls(TlsMode::Require, TlsMode::Strict).as_deref(),
            Some("Connects over TLS without checking the certificate")
        );
        assert_eq!(
            looser_tls(TlsMode::Disable, TlsMode::Strict).as_deref(),
            Some("Connects without TLS")
        );
    }

    fn tunnel(port: Option<u16>, username: Option<&str>, jump_hosts: &[&str]) -> SavedSshConfig {
        SavedSshConfig {
            host: "bastion.example".to_owned(),
            port,
            username: username.map(str::to_owned),
            jump_hosts: jump_hosts.iter().copied().map(str::to_owned).collect(),
            auth: SavedSshAuth::Agent,
        }
    }

    #[test]
    fn an_ssh_hop_names_the_server_and_the_jump_hosts_before_it() {
        assert_eq!(
            ssh_hop(&tunnel(None, Some("deploy"), &[])),
            "Through SSH to deploy@bastion.example"
        );
        assert_eq!(ssh_hop(&tunnel(None, None, &[])), "Through SSH to bastion.example");
        assert_eq!(
            ssh_hop(&tunnel(Some(2222), Some("deploy"), &["edge.example", "gate.example"])),
            "Through SSH to deploy@bastion.example:2222 via edge.example, gate.example"
        );
    }

    fn drivers() -> DriverRegistry {
        let mut drivers = DriverRegistry::new();
        drivers.register(Arc::new(FakeDriver::connecting(
            &FakeDriver::NETWORK_CAPABILITIES,
            ConnectionScript::default(),
        )));
        drivers
    }

    fn entry(change: ImportChange, tls: TlsConfig, ssh: Option<SavedSshConfig>) -> ImportEntry {
        ImportEntry {
            connection: SavedConnection {
                id: Uuid::new_v4(),
                name: "orders".to_owned(),
                driver_id: "fake".to_owned(),
                host: "db.internal".to_owned(),
                port: 5432,
                database: "orders".to_owned(),
                username: "app".to_owned(),
                tls,
                safe_mode: SafeModeLevel::Off,
                external_access: ExternalAccess::ReadOnly,
                ai_policy: AiPolicy::Ask,
                query_timeout_secs: None,
                auth_mode: AuthMode::Password,
                ssh,
                last_opened_at: None,
                color: None,
                group_id: None,
                order: 0,
                tags: Vec::new(),
                icon: None,
                options: Default::default(),
            },
            change,
        }
    }

    fn lines(entry: &ImportEntry) -> Vec<String> {
        entry_text(entry, &drivers())
            .subtitle
            .lines()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn an_added_entry_says_how_it_connects_beyond_its_host() {
        let tunnelled = entry(
            ImportChange::Added,
            TlsConfig::disabled(),
            Some(tunnel(None, Some("deploy"), &[])),
        );
        assert_eq!(
            lines(&tunnelled),
            [
                "New · fake · app@db.internal:5432",
                "Through SSH to deploy@bastion.example",
                "Connects without TLS",
            ]
        );

        let checked = entry(ImportChange::Added, TlsConfig::verify_full(), None);
        assert_eq!(lines(&checked), ["New · fake · app@db.internal:5432"]);
    }

    #[gtk4::test]
    fn the_rows_present_without_a_warning_and_name_each_connection() {
        let root = tempfile::tempdir().expect("tempdir");
        let at = |dir: &str| {
            tablepro_storage::StoragePaths::under(&root.path().join(dir), "tablepro", "app.tablepro.TablePro")
        };
        let source = tablepro_storage::ConnectionStore::new(&at("source"));
        source
            .upsert_blocking(entry(ImportChange::Added, TlsConfig::disabled(), None).connection)
            .expect("save");
        let exported = source.export_blocking().expect("export");
        let preview = tablepro_storage::ConnectionStore::new(&at("target"))
            .preview_import_blocking(std::path::Path::new("/tmp/connections.json"), &exported)
            .expect("preview");
        let window = adw::Window::builder().default_width(800).default_height(600).build();
        let dialog = import_preview_dialog(&preview, &drivers());

        let previous = glib::log_set_always_fatal(glib::LogLevels::LEVEL_WARNING | glib::LogLevels::LEVEL_CRITICAL);
        window.present();
        dialog.present(Some(&window));
        crate::test_support::after_next_frame(&dialog);
        crate::test_support::drain_main_context();
        glib::log_set_always_fatal(previous);

        let list = crate::test_support::first_descendant_of_type::<gtk::ListView>(&dialog).expect("the list");
        let item = list.first_child().expect("a row");
        let child = item.first_child().expect("the row's child");
        assert!(!child.is::<gtk::ListBoxRow>(), "{}", child.type_().name());
        let labels: Vec<String> = crate::test_support::descendants(&item)
            .iter()
            .filter_map(|widget| {
                widget
                    .downcast_ref::<gtk::Label>()
                    .map(|label| label.label().to_string())
            })
            .collect();
        assert_eq!(
            labels,
            ["orders", "New · fake · app@db.internal:5432\nConnects without TLS"]
        );
        if crate::test_support::test_backend_records_properties() {
            assert!(gtk::test_accessible_has_property(&item, gtk::AccessibleProperty::Label));
            assert!(gtk::test_accessible_has_property(
                &item,
                gtk::AccessibleProperty::Description
            ));
        }
        dialog.force_close();
        window.close();
    }

    #[test]
    fn an_updated_entry_says_what_it_was_called() {
        let renamed = entry(
            ImportChange::Updated {
                renamed_from: Some("production".to_owned()),
            },
            TlsConfig::disabled(),
            None,
        );
        assert_eq!(
            lines(&renamed),
            ["Updated · fake · app@db.internal:5432", "Renamed from “production”"]
        );

        let kept = entry(
            ImportChange::Updated { renamed_from: None },
            TlsConfig::verify_full(),
            None,
        );
        assert_eq!(lines(&kept), ["Updated · fake · app@db.internal:5432"]);
    }
}
