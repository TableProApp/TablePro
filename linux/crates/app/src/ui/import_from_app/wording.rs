use tablepro_core::{DriverRegistry, TlsMode};
use tablepro_foreign_import::review::{
    ConnectionRow, QueryAvailability, QueryRow, QueryStatus, Resolution, RowNote, TlsFileReason,
};
use tablepro_foreign_import::{
    ForeignApp, ForeignImportError, ForeignSslMode, Inventory, PasswordOutcome, PasswordSource, SavedQuerySupport,
};
use tablepro_storage::GroupTree;

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::saved_connection_object::subtitle_for;

pub(super) struct OptionText {
    pub offered: bool,
    pub subtitle: String,
}

pub(super) fn source_subtitle(app: ForeignApp, available: bool, inventory: Inventory) -> String {
    if app.picked_file_extensions().is_some() {
        return gettext("Choose an export file to import");
    }
    if !available {
        return gettext("Not found on this computer");
    }
    let connections = ngettext_f(
        "{n} connection found",
        "{n} connections found",
        count(inventory.connections),
        &[("n", &inventory.connections.to_string())],
    );
    if inventory.saved_queries == 0 {
        return connections;
    }
    let queries = ngettext_f(
        "{n} saved query",
        "{n} saved queries",
        count(inventory.saved_queries),
        &[("n", &inventory.saved_queries.to_string())],
    );
    format!("{connections} · {queries}")
}

// What the passwords switch can do for this app on Linux, said before anything is read.
pub(super) fn password_option(app: ForeignApp) -> OptionText {
    match (app.password_source(), app) {
        (PasswordSource::AppFiles, _) => OptionText {
            offered: true,
            subtitle: gettext("Saved passwords are decrypted while reading"),
        },
        // This one can keep them in a KeePass file of its own instead of the keyring.
        (PasswordSource::Keychain, ForeignApp::DataGrip) => OptionText {
            offered: true,
            subtitle: gettext_f(
                "Read from the password file of {app} when it keeps one there",
                &[("app", app.display_name())],
            ),
        },
        (PasswordSource::Keychain, _) => OptionText {
            offered: false,
            subtitle: gettext_f(
                "{app} keeps passwords in the system keyring, which TablePro cannot read",
                &[("app", app.display_name())],
            ),
        },
    }
}

pub(super) fn saved_query_option(app: ForeignApp) -> OptionText {
    match app.saved_query_support() {
        SavedQuerySupport::Scripts => OptionText {
            offered: true,
            subtitle: gettext(
                "Scripts import with the connection they run on. Scripts with a default name start unchecked.",
            ),
        },
        SavedQuerySupport::Consoles => OptionText {
            offered: true,
            subtitle: gettext(
                "Query consoles import with their data source. Consoles with a default name start unchecked.",
            ),
        },
        SavedQuerySupport::GlobalFolder => OptionText {
            offered: false,
            subtitle: gettext_f(
                "{app} keeps saved queries apart from its connections, and TablePro keeps each with a connection",
                &[("app", app.display_name())],
            ),
        },
        SavedQuerySupport::NotInExport => OptionText {
            offered: false,
            subtitle: gettext_f(
                "The {app} export file has no saved queries",
                &[("app", app.display_name())],
            ),
        },
    }
}

pub(super) fn password_banner(app: ForeignApp, outcome: PasswordOutcome) -> Option<String> {
    match outcome {
        PasswordOutcome::LeftInKeychain => Some(gettext_f(
            "Passwords stay in the keyring {app} uses. Enter them when you connect.",
            &[("app", app.display_name())],
        )),
        PasswordOutcome::Stopped => Some(gettext("Some passwords were not read. Enter them when you connect.")),
        PasswordOutcome::NotRequested | PasswordOutcome::Read => None,
    }
}

pub(super) fn collect_failure(app: ForeignApp, error: &ForeignImportError) -> String {
    match error {
        ForeignImportError::FileNotFound { .. } => gettext_f(
            "The files of {app} are not where it keeps them.",
            &[("app", app.display_name())],
        ),
        ForeignImportError::NothingFound => gettext_f(
            "{app} has no saved connections to import.",
            &[("app", app.display_name())],
        ),
        ForeignImportError::Unreadable { .. }
        | ForeignImportError::Parse { .. }
        | ForeignImportError::UnsupportedFormat { .. } => {
            tracing::warn!(code = error.code(), "could not read another app's connections");
            gettext_f(
                "The connections of {app} could not be read. Its files may be from a version TablePro does not know.",
                &[("app", app.display_name())],
            )
        }
        ForeignImportError::Cancelled => gettext("The import was cancelled."),
    }
}

pub(super) fn resolution_title(resolution: Resolution) -> String {
    match resolution {
        Resolution::Add => gettext("Add"),
        Resolution::AddCopy => gettext("Add as Copy"),
        Resolution::Replace(_) => gettext("Replace"),
        Resolution::KeepExisting(_) => gettext("Keep Existing, Add Queries"),
    }
}

fn count(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}

// Where the connection goes, where it lands, what it matches and what it loses, one line each.
pub(super) fn connection_subtitle(row: &ConnectionRow, drivers: &DriverRegistry) -> String {
    let mut lines = Vec::new();
    match &row.connection {
        Some(saved) => {
            let driver = drivers.get(&saved.driver_id);
            let file_based = driver
                .as_ref()
                .is_some_and(|driver| driver.capabilities().is_file_based());
            let shown = subtitle_for(saved, file_based, None);
            let engine = driver
                .as_ref()
                .map_or(saved.driver_id.as_str(), |driver| driver.display_name());
            lines.push(shown.replacen(&saved.driver_id, engine, 1));
        }
        None => lines.push(row.engine.clone()),
    }
    if !row.group_path.is_empty() {
        lines.push(row.group_path.join(GroupTree::PATH_SEPARATOR));
    }
    if let Some(existing) = &row.duplicate {
        lines.push(gettext_f("Matches “{name}”", &[("name", &existing.name)]));
    }
    lines.extend(row.notes.iter().map(note_text));
    lines.join("\n")
}

pub(super) fn note_text(note: &RowNote) -> String {
    match note {
        RowNote::UnsupportedEngine { engine } => {
            gettext_f("TablePro cannot open {engine} connections", &[("engine", engine)])
        }
        RowNote::SshKeyMissing { path } => gettext_f("SSH private key not found: {path}", &[("path", path)]),
        RowNote::JumpHostKeyMissing { path } => gettext_f("Jump host key not found: {path}", &[("path", path)]),
        RowNote::CaCertificateMissing { path } => gettext_f("CA certificate not found: {path}", &[("path", path)]),
        RowNote::ClientCertificateMissing { path } => {
            gettext_f("Client certificate not found: {path}", &[("path", path)])
        }
        RowNote::ClientKeyMissing { path } => gettext_f("Client key not found: {path}", &[("path", path)]),
        RowNote::TlsModeChanged { from, to } => gettext_f(
            "SSL {from} becomes {to}",
            &[("from", &ssl_mode_name(*from)), ("to", &tls_mode_name(*to))],
        ),
        RowNote::TlsSettingsNotRead => gettext("Its TLS settings could not be read, so it would connect without TLS"),
        RowNote::TlsFromDriverDefault { mode } => gettext_f(
            "SSL {mode} is on because the other app encrypts this connection by default",
            &[("mode", &ssl_mode_name(*mode))],
        ),
        RowNote::TlsNotKept { from } => gettext_f(
            "SSL {mode} is not kept: this engine connects without TLS",
            &[("mode", &ssl_mode_name(*from))],
        ),
        RowNote::CaFileNotKept { path, reason } => gettext_f(
            "CA certificate {path} is not kept: {reason}",
            &[("path", path), ("reason", &file_reason(*reason))],
        ),
        RowNote::ClientIdentityNotKept { reason } => gettext_f(
            "The client certificate is not kept: {reason}",
            &[("reason", &file_reason(*reason))],
        ),
        RowNote::SshNotKept => gettext("The SSH tunnel is not kept: a database file opens on this computer"),
        RowNote::SshKeyNotKept { path } => gettext_f("SSH key {path} is not kept", &[("path", path)]),
        RowNote::JumpHostNotKept { host } => gettext_f("Jump host {host} is not kept", &[("host", host)]),
        RowNote::JumpHostPasswordNotKept { host } => gettext_f(
            "Jump host {host} signs in through the SSH agent or the SSH config",
            &[("host", host)],
        ),
        RowNote::JumpHostKeyNotKept { host, path } => gettext_f(
            "The key {path} of jump host {host} is not kept",
            &[("host", host), ("path", path)],
        ),
        RowNote::FieldsNotKept { fields } => gettext_f("Not kept: {fields}", &[("fields", &fields.join(", "))]),
    }
}

fn ssl_mode_name(mode: ForeignSslMode) -> String {
    match mode {
        ForeignSslMode::Disabled => gettext("Disabled"),
        ForeignSslMode::Preferred => gettext("Preferred"),
        ForeignSslMode::Required => gettext("Required"),
        ForeignSslMode::VerifyCa => gettext("Verify CA"),
        ForeignSslMode::VerifyIdentity => gettext("Verify Identity"),
    }
}

fn tls_mode_name(mode: TlsMode) -> String {
    crate::ui::connect_dialog::tls_mode_label(mode)
}

fn file_reason(reason: TlsFileReason) -> String {
    match reason {
        TlsFileReason::EngineLacks => gettext("this engine does not take one"),
        TlsFileReason::ModeLacks => gettext("the SSL mode does not use it"),
        TlsFileReason::RelativePath => gettext("its path is not a full path"),
        TlsFileReason::Incomplete => gettext("a certificate needs its key, and a key its certificate"),
    }
}

pub(super) fn query_subtitle(row: &QueryRow, status: Option<QueryStatus>) -> String {
    let availability = status.map(|status| status.availability);
    match availability {
        Some(QueryAvailability::NoConnection) => {
            gettext("Not imported: TablePro keeps each saved query with a connection")
        }
        Some(QueryAvailability::ConnectionSkipped) => gettext("Not imported: its connection is not imported"),
        Some(QueryAvailability::TooLarge) => gettext("Not imported: larger than a saved query can be"),
        Some(QueryAvailability::NameTooLong) => gettext("Not imported: its name is longer than a saved query's can be"),
        Some(QueryAvailability::AddedByAnotherRow) => {
            gettext("Another query of this name is imported for its connection")
        }
        Some(QueryAvailability::Available) | None => match &row.connection_name {
            Some(name) => gettext_f("On {connection}", &[("connection", name)]),
            None => String::new(),
        },
    }
}
