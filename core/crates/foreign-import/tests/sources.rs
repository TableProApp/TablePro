#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::fs;
use std::path::Path;
use std::sync::Arc;

use serde::Deserialize;
use tablepro_foreign_import::{
    ForeignApp, ForeignAppDirs, ForeignCredentialManager, ForeignHost, ForeignPlatform, ForeignSource, Inventory,
    KeychainRead, PasswordOffer, PlainHost, ScanDepth, SourceAvailability, UnreadableReason, preselect,
    sources_blocking,
};

const SOURCE_LIST: &str = include_str!("fixtures/source_list.json");

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SourceList {
    schema_version: u32,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    name: String,
    // The platform the case was written for; the rule itself does not read it.
    platform: String,
    rows: Vec<Row>,
    ticked: Vec<String>,
    preselected: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Row {
    app: String,
    availability: String,
    connections: usize,
    picks_file: bool,
}

impl Row {
    fn source(&self, case: &str) -> ForeignSource {
        let app = ForeignApp::from_id(&self.app).unwrap_or_else(|| panic!("{case}: no app {}", self.app));
        let availability = match self.availability.as_str() {
            "available" => SourceAvailability::Available,
            "notFound" => SourceAvailability::NotFound,
            "unreadable" => SourceAvailability::Unreadable(UnreadableReason {
                code: "foreign_import.unreadable",
                detail: String::new(),
            }),
            other => panic!("{case}: no availability {other}"),
        };
        ForeignSource {
            app,
            availability,
            inventory: Inventory {
                connections: self.connections,
                saved_queries: 0,
            },
            password_offer: app.password_offer(&PlainHost),
            offers_saved_queries: false,
        }
    }
}

struct CredentialManagerHost;

struct NoCredentials;

impl ForeignCredentialManager for NoCredentials {
    fn read_generic(&self, _target: &str) -> KeychainRead {
        KeychainRead::NotFound
    }
}

impl ForeignHost for CredentialManagerHost {
    fn credential_manager(&self) -> Option<Arc<dyn ForeignCredentialManager>> {
        Some(Arc::new(NoCredentials))
    }
}

fn mac(home: &Path) -> ForeignAppDirs {
    ForeignAppDirs::conventional(ForeignPlatform::MacOs, home)
}

fn write(path: &Path, contents: &[u8]) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("a folder");
    }
    fs::write(path, contents).expect("a file");
}

fn dbeaver_project(home: &Path, project: &str) -> std::path::PathBuf {
    home.join("Library/DBeaverData/workspace6")
        .join(project)
        .join(".dbeaver/data-sources.json")
}

fn write_dbeaver(home: &Path, project: &str, ids: &[&str]) {
    let connections: Vec<String> = ids
        .iter()
        .map(|id| format!(r#""{id}": {{"provider": "postgresql", "name": "{id}", "configuration": {{"host": "h"}}}}"#))
        .collect();
    write(
        &dbeaver_project(home, project),
        format!(r#"{{"connections": {{{}}}}}"#, connections.join(", ")).as_bytes(),
    );
}

fn find(sources: &[ForeignSource], app: ForeignApp) -> &ForeignSource {
    sources
        .iter()
        .find(|source| source.app == app)
        .unwrap_or_else(|| panic!("{app:?} is not listed"))
}

fn unreadable_code(source: &ForeignSource) -> &'static str {
    match &source.availability {
        SourceAvailability::Unreadable(reason) => reason.code,
        other => panic!("{:?} reads as {other:?}", source.app),
    }
}

// The same cases run through the macOS app's scanner rule, so the two stay one rule.
#[test]
fn every_shared_case_ticks_and_preselects_as_listed() {
    let list: SourceList = serde_json::from_str(SOURCE_LIST).expect("the shared source list");
    assert_eq!(list.schema_version, 1);
    assert!(list.cases.len() >= 6);
    for case in &list.cases {
        assert!(
            ["macos", "linux", "windows"].contains(&case.platform.as_str()),
            "{}",
            case.name
        );
        let sources: Vec<ForeignSource> = case.rows.iter().map(|row| row.source(&case.name)).collect();
        for (row, source) in case.rows.iter().zip(&sources) {
            assert_eq!(source.picks_file(), row.picks_file, "{}: {}", case.name, row.app);
        }
        let ticked: Vec<&str> = sources
            .iter()
            .filter(|source| source.starts_ticked())
            .map(|source| source.app.id())
            .collect();
        assert_eq!(ticked, case.ticked, "{}", case.name);
        assert_eq!(
            preselect(&sources).map(ForeignApp::id),
            case.preselected.as_deref(),
            "{}",
            case.name
        );
    }
}

#[test]
fn every_app_the_platform_has_is_listed_in_one_order() {
    let home = tempfile::tempdir().expect("a home");
    let listed = |platform| -> Vec<ForeignApp> {
        sources_blocking(
            &ForeignAppDirs::conventional(platform, home.path()),
            Arc::new(PlainHost),
            ScanDepth::Inventory,
        )
        .into_iter()
        .map(|source| source.app)
        .collect()
    };
    assert_eq!(listed(ForeignPlatform::MacOs), ForeignApp::ALL);
    for platform in [ForeignPlatform::Linux, ForeignPlatform::Windows] {
        let expected: Vec<ForeignApp> = ForeignApp::ALL
            .into_iter()
            .filter(|app| *app != ForeignApp::SequelAce)
            .collect();
        assert_eq!(listed(platform), expected, "{platform:?}");
    }
}

#[test]
fn an_empty_home_lists_only_the_picked_file_app_as_available() {
    let home = tempfile::tempdir().expect("a home");
    let sources = sources_blocking(&mac(home.path()), Arc::new(PlainHost), ScanDepth::Inventory);
    for source in &sources {
        let expected = if source.picks_file() {
            SourceAvailability::Available
        } else {
            SourceAvailability::NotFound
        };
        assert_eq!(source.availability, expected, "{:?}", source.app);
        assert_eq!(source.inventory, Inventory::default(), "{:?}", source.app);
        assert!(!source.starts_ticked(), "{:?}", source.app);
    }
    assert_eq!(preselect(&sources), Some(ForeignApp::Navicat));
}

#[test]
fn presence_reads_no_count_and_inventory_counts_every_dbeaver_project() {
    let home = tempfile::tempdir().expect("a home");
    write_dbeaver(home.path(), "General", &["a", "b"]);
    write_dbeaver(home.path(), "Production", &["c", "d", "e"]);

    let present = sources_blocking(&mac(home.path()), Arc::new(PlainHost), ScanDepth::Presence);
    let counted = sources_blocking(&mac(home.path()), Arc::new(PlainHost), ScanDepth::Inventory);

    let probe = find(&present, ForeignApp::DBeaver);
    assert_eq!(probe.availability, SourceAvailability::Available);
    assert_eq!(probe.inventory, Inventory::default());
    assert!(!probe.starts_ticked());
    let dbeaver = find(&counted, ForeignApp::DBeaver);
    assert_eq!(dbeaver.availability, SourceAvailability::Available);
    assert_eq!(dbeaver.inventory.connections, 5);
    assert!(dbeaver.starts_ticked());
    assert_eq!(preselect(&counted), Some(ForeignApp::DBeaver));
}

#[test]
fn data_that_cannot_be_parsed_reads_as_unreadable_never_as_empty() {
    let home = tempfile::tempdir().expect("a home");
    let support = home.path().join("Library/Application Support");
    write(
        &support.join("com.tinyapp.TablePlus/Data/Connections.plist"),
        b"not a plist",
    );
    write(
        &home
            .path()
            .join("Library/Containers/com.sequel-ace.sequel-ace/Data/Library/Application Support")
            .join("Sequel Ace/Data/Favorites.plist"),
        b"not a plist",
    );
    write(&dbeaver_project(home.path(), "General"), b"{ not json");
    write(&support.join("beekeeper-studio/app.db"), b"not a database file at all");
    write(&support.join("com.dbx.app/dbx.db"), b"not a database file at all");

    let sources = sources_blocking(&mac(home.path()), Arc::new(PlainHost), ScanDepth::Inventory);

    assert_eq!(
        unreadable_code(find(&sources, ForeignApp::TablePlus)),
        "foreign_import.unsupported_format"
    );
    assert_eq!(
        unreadable_code(find(&sources, ForeignApp::SequelAce)),
        "foreign_import.parse"
    );
    assert_eq!(
        unreadable_code(find(&sources, ForeignApp::DBeaver)),
        "foreign_import.parse"
    );
    for app in [ForeignApp::BeekeeperStudio, ForeignApp::Dbx] {
        let source = find(&sources, app);
        assert!(unreadable_code(source).starts_with("foreign_import."), "{app:?}");
        assert_eq!(source.inventory, Inventory::default(), "{app:?}");
        assert!(!source.starts_ticked(), "{app:?}");
    }
    assert_eq!(preselect(&sources), Some(ForeignApp::Navicat));
}

#[cfg(unix)]
#[test]
fn a_file_the_user_cannot_open_reads_as_unreadable() {
    use std::os::unix::fs::PermissionsExt;

    let home = tempfile::tempdir().expect("a home");
    let dbeaver = dbeaver_project(home.path(), "General");
    write_dbeaver(home.path(), "General", &["a"]);
    let datagrip = home
        .path()
        .join("Library/Application Support/JetBrains/DataGrip2026.1/options/dataSources.xml");
    write(&datagrip, b"<application/>");
    for file in [&dbeaver, &datagrip] {
        fs::set_permissions(file, fs::Permissions::from_mode(0o000)).expect("permissions");
    }
    // A superuser opens any file, so there is nothing to check.
    if fs::File::open(&dbeaver).is_ok() {
        return;
    }

    let sources = sources_blocking(&mac(home.path()), Arc::new(PlainHost), ScanDepth::Inventory);

    for app in [ForeignApp::DBeaver, ForeignApp::DataGrip] {
        assert_eq!(
            unreadable_code(find(&sources, app)),
            "foreign_import.unreadable",
            "{app:?}"
        );
    }
}

#[test]
fn passwords_are_offered_unless_a_store_this_platform_cannot_read_holds_them() {
    let offers = |host: &dyn ForeignHost| -> Vec<(ForeignApp, PasswordOffer)> {
        ForeignApp::ALL
            .into_iter()
            .map(|app| (app, app.password_offer(host)))
            .collect()
    };
    assert_eq!(
        offers(&PlainHost),
        [
            (ForeignApp::TablePlus, PasswordOffer::SystemStore),
            (ForeignApp::SequelAce, PasswordOffer::SystemStore),
            (ForeignApp::DBeaver, PasswordOffer::DecryptedWhileReading),
            (ForeignApp::DataGrip, PasswordOffer::PasswordFile),
            (ForeignApp::BeekeeperStudio, PasswordOffer::DecryptedWhileReading),
            (ForeignApp::Navicat, PasswordOffer::DecryptedWhileReading),
            (ForeignApp::Dbx, PasswordOffer::SystemStore),
        ]
    );
    assert_eq!(
        ForeignApp::Dbx.password_offer(&CredentialManagerHost),
        PasswordOffer::KeyInCredentialManager
    );
    assert!(!PasswordOffer::SystemStore.offered());
    for offer in [
        PasswordOffer::DecryptedWhileReading,
        PasswordOffer::PasswordFile,
        PasswordOffer::KeyInCredentialManager,
    ] {
        assert!(offer.offered(), "{offer:?}");
    }
}

#[test]
fn saved_queries_are_offered_where_they_land_with_their_connection() {
    let home = tempfile::tempdir().expect("a home");
    let sources = sources_blocking(&mac(home.path()), Arc::new(CredentialManagerHost), ScanDepth::Presence);
    let offered: Vec<ForeignApp> = sources
        .iter()
        .filter(|source| source.offers_saved_queries)
        .map(|source| source.app)
        .collect();
    assert_eq!(offered, [ForeignApp::DBeaver, ForeignApp::DataGrip, ForeignApp::Dbx]);
    assert_eq!(
        find(&sources, ForeignApp::Dbx).password_offer,
        PasswordOffer::KeyInCredentialManager
    );
}
