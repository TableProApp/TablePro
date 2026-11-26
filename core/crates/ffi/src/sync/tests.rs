use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use secrecy::{ExposeSecret as _, SecretString};
use tablepro_keys::encoding::{AccountId, Origin, TeamId, Version};
use tablepro_session::runtime::Tasks;
use tablepro_sync::SyncError;
use tablepro_sync::api::key_flows::{MemberKeyStatus, MemberKeys, ReviewedMember, TeamKeys};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::KeyVersionState;
use tablepro_sync::api::{DeviceRowId, ScopeName, StateFiles};
use tablepro_sync::state::SqliteStateFiles;
use tablepro_sync_testing::{FakeCloudKit, FakeDeviceStore, FakeServer};
use uuid::Uuid;

use super::engines::{ServiceLink, ServiceSlot};
use super::keys::{GenesisOutcomeTag, KeyStateInfo, reviewed_member_info, team_keys_info};
use super::names::{Names, Person};
use super::open::OpenParts;
use super::service::{
    PassReasonTag, SyncCategoriesArg, SyncConfig, SyncListener, SyncPhaseTag, SyncPlatformTag, SyncService,
};
use crate::account::SyncProviderTag;
use crate::error::CoreError;
use crate::runtime;

// Counts the signals, and can hold the thread of its first call until the test lets go, saying when it is held.
#[derive(Default)]
struct Listener {
    status: AtomicUsize,
    keys: AtomicUsize,
    returned: AtomicUsize,
    held: Mutex<Option<(std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>)>>,
}

impl SyncListener for Listener {
    fn status_changed(&self) {
        self.status.fetch_add(1, Ordering::SeqCst);
        let held = self.held.lock().unwrap().take();
        if let Some((entered, release)) = held {
            let _ = entered.send(());
            let _ = release.recv();
        }
        self.returned.fetch_add(1, Ordering::SeqCst);
    }

    fn keys_changed(&self) {
        self.keys.fetch_add(1, Ordering::SeqCst);
    }
}

fn config(provider: SyncProviderTag) -> SyncConfig {
    SyncConfig {
        platform: SyncPlatformTag::Macos,
        provider,
        categories: SyncCategoriesArg::default(),
        icloud_account: None,
        service_account: None,
        route_publisher: None,
    }
}

struct Opened {
    service: Arc<SyncService>,
    _dir: tempfile::TempDir,
}

async fn open(tasks: &Tasks, parts: impl FnOnce(OpenParts) -> OpenParts) -> Opened {
    let dir = tempfile::tempdir().unwrap();
    let device_store = Arc::new(FakeDeviceStore::new());
    let files = Arc::new(SqliteStateFiles::at(dir.path().join("sync"), device_store.clone()));
    let parts = parts(OpenParts {
        config: config(SyncProviderTag::Off),
        account: None,
        files: Some(files as Arc<dyn StateFiles>),
        connections: None,
        cloudkit: None,
        settings: None,
        device_store: Some(device_store as Arc<dyn tablepro_sync::api::HostDeviceStore>),
        legacy_mirror: None,
        library: None,
        history: None,
        link: Err(tablepro_sync::api::TransportError::SignedOut.into()),
        session: None,
        listener: Arc::new(Listener::default()),
    });
    let opener = tasks.clone();
    let service = tasks
        .spawn_task(async move { SyncService::open(opener, parts).await })
        .await
        .unwrap();
    Opened { service, _dir: dir }
}

fn link(server: &Arc<FakeServer>, account: AccountId) -> ServiceLink {
    let device_row = DeviceRowId("dev_01k8d6wpggfd68tbhz818p4ww4".to_owned());
    ServiceLink {
        origin: Origin::parse("https://sync.example.com").unwrap(),
        sign_in: "sync.example.com".to_owned(),
        account,
        device_row: device_row.clone(),
        transport: Arc::new(server.client(account, device_row)),
        binding: None,
    }
}

fn code(error: &CoreError) -> &str {
    error.code()
}

#[tokio::test]
async fn without_an_account_tablepro_sync_reports_unavailable_and_its_calls_say_signed_out() {
    let tasks = runtime::tasks().unwrap();
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        ..parts
    })
    .await;

    let status = opened.service.status();
    let keys = opened.service.key_state().await.unwrap_err();
    let pass = opened.service.sync_now(PassReasonTag::Person).await.unwrap_err();

    assert_eq!(status.phase, SyncPhaseTag::Unavailable);
    assert_eq!(status.provider, Some(SyncProviderTag::TableproSync));
    assert_eq!(status.problem.as_deref(), Some("sync.signed_out"));
    assert_eq!(code(&keys), "sync.signed_out");
    assert_eq!(code(&pass), "sync.signed_out");
}

#[tokio::test]
async fn with_sync_off_and_no_sign_in_the_status_is_off_and_nothing_runs() {
    let tasks = runtime::tasks().unwrap();
    let opened = open(&tasks, |parts| parts).await;

    let status = opened.service.status();
    let pass = opened.service.sync_now(PassReasonTag::Person).await;
    let approvals = opened.service.approvals().await.unwrap();
    let conflicts = opened.service.conflicts().await.unwrap();

    assert_eq!(status.phase, SyncPhaseTag::Off);
    assert_eq!(status.provider, Some(SyncProviderTag::Off));
    assert!(pass.is_ok(), "{pass:?}");
    assert!(approvals.is_empty());
    assert!(conflicts.is_empty());
    assert!(opened.service.scope_statuses().is_empty());
}

// Team scopes and the key objects use TablePro Sync whatever the personal provider is (core ADR 0054, Providers).
#[tokio::test]
async fn with_sync_off_a_sign_in_still_syncs_teams_and_its_keys() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let account = AccountId(Uuid::new_v4());
    let team = TeamId(Uuid::new_v4());
    server.add_team(team, &[(account, Role::Owner)]);
    let opened = open(&tasks, |parts| OpenParts {
        link: Ok(link(&server, account)),
        ..parts
    })
    .await;

    opened.service.sync_now(PassReasonTag::Launch).await.unwrap();
    let keys = opened.service.key_state().await.unwrap();
    let scopes = opened.service.scope_statuses();
    let team_keys = opened.service.team_keys(ScopeName::Team(team).wire()).await.unwrap();
    let conflicts = opened.service.conflicts().await.unwrap();
    let personal_approval = opened
        .service
        .decide_approval(
            super::service::SyncRecordRef {
                scope: "personal".to_owned(),
                kind: "connection".to_owned(),
                record_id: "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned(),
            },
            "host".to_owned(),
            "00".repeat(32),
            true,
        )
        .await
        .unwrap_err();

    assert_eq!(opened.service.status().phase, SyncPhaseTag::Off);
    assert_eq!(keys, KeyStateInfo::NoKeys);
    assert!(
        scopes.iter().any(|scope| scope.scope == ScopeName::Team(team).wire()),
        "{scopes:?}"
    );
    assert_eq!(team_keys.members.len(), 1, "{team_keys:?}");
    assert!(conflicts.is_empty());
    assert_eq!(
        code(&personal_approval),
        "sync.not_allowed",
        "personal data has no engine while sync is off"
    );
}

#[tokio::test]
async fn icloud_runs_without_an_account_and_gives_back_the_account_it_synced() {
    let tasks = runtime::tasks().unwrap();
    let cloudkit = Arc::new(FakeCloudKit::signed_in("_a"));
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::Icloud),
        cloudkit: Some(cloudkit.clone() as Arc<dyn tablepro_sync::api::CloudKitTransport>),
        ..parts
    })
    .await;

    opened.service.sync_now(PassReasonTag::Launch).await.unwrap();
    let status = opened.service.status();

    assert_eq!(status.provider, Some(SyncProviderTag::Icloud));
    assert_eq!(status.phase, SyncPhaseTag::Idle);
    assert_eq!(status.problem, None);
    assert!(status.last_pass_ms.is_some());
    assert_eq!(opened.service.icloud_account().as_deref(), Some("_a"));
    assert_eq!(
        code(&opened.service.key_state().await.unwrap_err()),
        "sync.signed_out",
        "with no sign-in the teams and the keys have no engine"
    );
}

#[tokio::test]
async fn icloud_without_its_transport_is_unavailable_and_keeps_the_account_the_app_gave() {
    let tasks = runtime::tasks().unwrap();
    let opened = open(&tasks, |parts| OpenParts {
        config: SyncConfig {
            icloud_account: Some("_kept".to_owned()),
            ..config(SyncProviderTag::Icloud)
        },
        ..parts
    })
    .await;

    let status = opened.service.status();

    assert_eq!(status.phase, SyncPhaseTag::Unavailable);
    assert_eq!(status.problem.as_deref(), Some("sync.not_allowed"));
    assert_eq!(opened.service.icloud_account().as_deref(), Some("_kept"));
}

// A listener that does not return holds back no pass: the engine signals into a task of the service's own.
#[tokio::test]
async fn a_pass_finishes_while_the_listener_is_still_running() {
    let tasks = runtime::tasks().unwrap();
    let (entered_tx, entered) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let listener = Arc::new(Listener {
        held: Mutex::new(Some((entered_tx, release_rx))),
        ..Listener::default()
    });
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::Icloud),
        cloudkit: Some(Arc::new(FakeCloudKit::signed_in("_a")) as Arc<dyn tablepro_sync::api::CloudKitTransport>),
        listener: listener.clone(),
        ..parts
    })
    .await;
    let service = Arc::clone(&opened.service);
    let pass = tasks.spawn_task(async move { service.sync_now(PassReasonTag::Person).await });

    let held = tasks
        .spawn_blocking_task(move || entered.recv_timeout(Duration::from_secs(30)))
        .await
        .unwrap();
    let passed = tokio::time::timeout(Duration::from_secs(30), pass).await;
    let returned_meanwhile = listener.returned.load(Ordering::SeqCst);
    release.send(()).unwrap();

    assert!(held.is_ok(), "the listener was never called");
    assert!(matches!(passed, Ok(Ok(Ok(())))), "{passed:?}");
    assert_eq!(returned_meanwhile, 0, "the pass ended only once the listener returned");
}

#[tokio::test]
async fn genesis_runs_through_the_service_over_the_engine_s_key_flows() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let account = AccountId(Uuid::new_v4());
    let listener = Arc::new(Listener::default());
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        link: Ok(link(&server, account)),
        listener: listener.clone(),
        ..parts
    })
    .await;

    opened.service.sync_now(PassReasonTag::Launch).await.unwrap();
    let before = opened.service.key_state().await.unwrap();
    let draft = opened.service.begin_genesis().await.unwrap();
    let groups: Vec<String> = draft.text.expose_secret().split('-').map(str::to_lowercase).collect();
    let typed = draft
        .check
        .iter()
        .map(|index| SecretString::from(groups[usize::from(*index)].clone()))
        .collect();
    let wrong = opened
        .service
        .finish_genesis(draft.draft.clone(), vec![SecretString::from("x")])
        .await
        .unwrap_err();
    let outcome = opened.service.finish_genesis(draft.draft, typed).await.unwrap();
    let after = opened.service.key_state().await.unwrap();

    assert_eq!(before, KeyStateInfo::NoKeys);
    assert_eq!(code(&wrong), "sync.malformed");
    assert_eq!(outcome, GenesisOutcomeTag::Created);
    assert!(matches!(after, KeyStateInfo::Approved { av: 1, .. }), "{after:?}");
    assert_eq!(opened.service.status().problem, None);
}

fn typed(draft: &super::keys::RecoveryKeyDraftInfo) -> Vec<SecretString> {
    let groups: Vec<String> = draft.text.expose_secret().split('-').map(str::to_lowercase).collect();
    draft
        .check
        .iter()
        .map(|index| SecretString::from(groups[usize::from(*index)].clone()))
        .collect()
}

// A closed Replace sheet leaves no draft, so the current recovery key it held is dropped, and its zeroizing bytes
// with it; the draft cannot be finished afterwards, and discarding it again is no error.
#[tokio::test]
async fn a_discarded_replace_draft_is_gone_with_the_recovery_key_it_held() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        ..parts
    })
    .await;
    opened.service.sync_now(PassReasonTag::Launch).await.unwrap();
    let genesis = opened.service.begin_genesis().await.unwrap();
    opened
        .service
        .finish_genesis(genesis.draft.clone(), typed(&genesis))
        .await
        .unwrap();
    let replace = opened
        .service
        .begin_replace_recovery_key(genesis.text.clone())
        .await
        .unwrap();

    opened
        .service
        .discard_key_draft(replace.recovery.draft.clone())
        .unwrap();
    let again = opened.service.discard_key_draft(replace.recovery.draft.clone());
    let finished = opened
        .service
        .finish_replace_recovery_key(replace.recovery.draft.clone(), typed(&replace.recovery), Vec::new())
        .await
        .unwrap_err();
    let malformed = opened.service.discard_key_draft("not a draft".to_owned()).unwrap_err();
    let reset = opened.service.resume_reset("not a reset".to_owned()).await.unwrap_err();

    assert!(again.is_ok());
    assert_eq!(code(&finished), "sync.unknown");
    assert_eq!(code(&malformed), "sync.malformed");
    assert_eq!(code(&reset), "sync.malformed");
}

#[tokio::test]
async fn an_argument_the_engine_cannot_read_is_refused_before_any_call() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        ..parts
    })
    .await;

    let team = opened.service.team_keys("personal".to_owned()).await.unwrap_err();
    let account = opened
        .service
        .confirm_member("team_01k8d6wk00f8xsr79e7x052rkk".to_owned(), "acct_01".to_owned())
        .await
        .unwrap_err();
    let kind = opened
        .service
        .record_host_changes("not a kind".to_owned(), Vec::new(), Vec::new())
        .await
        .unwrap_err();
    let unknown = opened
        .service
        .record_host_changes("x_future_kind".to_owned(), Vec::new(), Vec::new())
        .await
        .unwrap_err();

    let record = super::service::SyncRecordRef {
        scope: "personal".to_owned(),
        kind: "connection".to_owned(),
        record_id: "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned(),
    };
    let short = opened
        .service
        .decide_approval(record.clone(), "host".to_owned(), "ab".to_owned(), true)
        .await
        .unwrap_err();
    let upper = opened
        .service
        .resolve_conflict(record, "AB".repeat(32), super::service::ConflictChoiceTag::KeepMine)
        .await
        .unwrap_err();

    assert_eq!(code(&short), "sync.malformed");
    assert_eq!(code(&upper), "sync.malformed");
    assert_eq!(code(&team), "sync.malformed");
    assert_eq!(code(&account), "sync.malformed");
    assert_eq!(code(&kind), "sync.malformed");
    assert_eq!(code(&unknown), "sync.unknown");
}

fn names(team: TeamId, member: AccountId) -> Names {
    let mut names = Names::default();
    names.insert_team(team, "Acme");
    names.insert_person(
        team,
        member,
        Person {
            name: Some("Ana".to_owned()),
            email: Some("ana@example.com".to_owned()),
        },
    );
    names
}

#[test]
fn a_team_s_rows_carry_the_names_the_account_could_read_and_none_for_the_rest() {
    let team = TeamId(Uuid::from_u128(7));
    let (ana, bo) = (AccountId(Uuid::from_u128(1)), AccountId(Uuid::from_u128(2)));
    let keys = TeamKeys {
        team,
        version: Some(Version::new(2).unwrap()),
        state: KeyVersionState::Ok,
        stopped_cause: None,
        rotation_due: false,
        holder: true,
        members: vec![
            MemberKeys {
                account: ana,
                role: Role::Owner,
                status: MemberKeyStatus::Holder,
            },
            MemberKeys {
                account: bo,
                role: Role::Member,
                status: MemberKeyStatus::AwaitingConfirmation,
            },
        ],
        stopped: Vec::new(),
    };

    let info = team_keys_info(keys, &names(team, ana), bo);

    assert_eq!(info.team, ScopeName::Team(team).wire());
    assert_eq!(info.team_name.as_deref(), Some("Acme"));
    assert_eq!(info.members[0].name.as_deref(), Some("Ana"));
    assert_eq!(info.members[0].email.as_deref(), Some("ana@example.com"));
    assert_eq!(
        (info.members[1].name.clone(), info.members[1].email.clone()),
        (None, None)
    );
}

#[test]
fn a_reviewed_member_names_its_team_and_reads_back_as_the_engine_s() {
    let team = TeamId(Uuid::from_u128(7));
    let ana = AccountId(Uuid::from_u128(1));
    let member = ReviewedMember {
        team,
        account: ana,
        confirmed_under_av: Version::new(3).unwrap(),
    };

    let info = reviewed_member_info(member, &names(team, ana), ana);
    let back = super::keys::reviewed_member_arg(&info).unwrap();

    assert_eq!(info.team_name.as_deref(), Some("Acme"));
    assert_eq!(info.name.as_deref(), Some("Ana"));
    assert!(info.is_self);
    assert_eq!(back, member);
    assert_eq!(
        super::keys::reviewed_member_arg(&super::keys::ReviewedMemberInfo {
            confirmed_under_av: 0,
            ..info
        }),
        Err(SyncError::Malformed { what: "version" })
    );
}

#[tokio::test]
async fn a_start_that_failed_for_a_reason_that_stays_is_not_tried_again() {
    let slot = ServiceSlot::new(
        Err(tablepro_sync::api::TransportError::SignedOut.into()),
        None,
        tablepro_sync::api::control::SyncCategories::default(),
    );

    let first = slot.engine().await.err().map(|error| error.code());
    let again = slot.engine().await.err().map(|error| error.code());

    assert_eq!(first, Some("sync.signed_out"));
    assert_eq!(again, Some("sync.signed_out"));
}

#[test]
fn a_credential_to_rotate_names_its_connection_while_the_store_holds_it() {
    use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};

    let kept = Uuid::from_u128(5);
    let gone = Uuid::from_u128(6);
    let names = std::collections::HashMap::from([(kept, ("Prod".to_owned(), "postgresql".to_owned()))]);
    let id = |connection: Uuid, kind| {
        EnvelopeId::new(
            ParentKind::Connection,
            &tablepro_keys::encoding::uuid_to_wire(connection),
            kind,
        )
        .unwrap()
    };
    let profile = EnvelopeId::new(
        ParentKind::SshProfile,
        &tablepro_keys::encoding::uuid_to_wire(kept),
        SecretKind::SshPassword,
    )
    .unwrap();

    let named = super::keys::credential_info(&id(kept, SecretKind::Password), &names);
    let missing = super::keys::credential_info(&id(gone, SecretKind::Plugin("token".to_owned())), &names);
    let other = super::keys::credential_info(&profile, &names);

    assert_eq!(named.connection_name.as_deref(), Some("Prod"));
    assert_eq!(named.connection_driver.as_deref(), Some("postgresql"));
    assert_eq!(named.field, "password");
    assert_eq!(named.connection, Some(tablepro_keys::encoding::uuid_to_wire(kept)));
    assert_eq!(
        (missing.connection_name.clone(), missing.connection_driver.clone()),
        (None, None)
    );
    assert_eq!(missing.field, "plugin.token");
    assert_eq!((other.connection.clone(), other.connection_name.clone()), (None, None));
    assert_eq!(other.parent_kind, "ssh_profile");
}

// An edit the app reported just before it quits reaches the Swift metadata before the quit goes on, and a mark the app
// still refuses when the quit sends it again is the quit call's failure.
#[tokio::test]
async fn the_quit_call_waits_for_the_downgrade_marks_and_says_when_one_failed() {
    let tasks = runtime::tasks().unwrap();
    let mirror = Arc::new(tablepro_sync_testing::FakeLegacyMirror::new());
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::Icloud),
        cloudkit: Some(Arc::new(FakeCloudKit::signed_in("_a")) as Arc<dyn tablepro_sync::api::CloudKitTransport>),
        legacy_mirror: Some(mirror.clone() as Arc<dyn tablepro_sync::api::LegacyMirror>),
        ..parts
    })
    .await;
    let id = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned();

    opened
        .service
        .record_host_changes("connection".to_owned(), vec![id.clone()], Vec::new())
        .await
        .unwrap();
    opened.service.flush_legacy_marks().await.unwrap();
    let marked = mirror.marks();
    // The mark the write sent and the one the quit sends again are both refused.
    mirror.fail_marks(2);
    opened
        .service
        .record_host_changes("connection".to_owned(), Vec::new(), vec![id])
        .await
        .unwrap();
    let refused = opened.service.flush_legacy_marks().await;
    let later = opened.service.flush_legacy_marks().await;

    assert!(marked >= 1, "no mark reached the Swift metadata");
    assert!(refused.is_err(), "{refused:?}");
    assert!(later.is_ok(), "{later:?}");
}

// Off to TablePro Sync is the first upload; the move back needs the count the person confirmed; a zone this device never
// used is not one to delete.
#[tokio::test]
async fn a_provider_change_runs_its_own_move_and_refuses_the_ones_that_need_the_person() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let off = open(&tasks, |parts| OpenParts {
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        ..parts
    })
    .await;
    let on = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        cloudkit: Some(Arc::new(FakeCloudKit::signed_in("_a")) as Arc<dyn tablepro_sync::api::CloudKitTransport>),
        ..parts
    })
    .await;

    let first = off.service.choose_provider(SyncProviderTag::TableproSync).await;
    let back = on.service.choose_provider(SyncProviderTag::Icloud).await.unwrap_err();
    let zone = on.service.delete_icloud_zone().await.unwrap_err();
    let same = on.service.choose_provider(SyncProviderTag::TableproSync).await;

    assert!(first.is_ok(), "{first:?}");
    assert_eq!(code(&back), "sync.not_allowed");
    assert_eq!(code(&zone), "sync.not_allowed");
    assert!(same.is_ok(), "{same:?}");
}

// The previous stable marks every write whatever the switch says, so a deletion with iCloud off still reaches the Swift
// metadata by the time the quit returns.
#[tokio::test]
async fn with_icloud_off_a_deletion_still_marks_the_swift_metadata_by_the_quit() {
    let tasks = runtime::tasks().unwrap();
    let mirror = Arc::new(tablepro_sync_testing::FakeLegacyMirror::new());
    let opened = open(&tasks, |parts| OpenParts {
        legacy_mirror: Some(mirror.clone() as Arc<dyn tablepro_sync::api::LegacyMirror>),
        ..parts
    })
    .await;
    let id = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44".to_owned();

    opened
        .service
        .record_host_changes("connection".to_owned(), Vec::new(), vec![id.clone()])
        .await
        .unwrap();
    opened.service.flush_legacy_marks().await.unwrap();

    let tombstones = mirror.metadata().tombstones;
    assert!(
        tombstones.iter().any(|tombstone| tombstone.record.id == id),
        "{tombstones:?}"
    );
}

// The previous stable marks every write, and the core's own stores are written by the app too, so a saved query
// written there with iCloud off reaches the Swift metadata by the time the quit returns.
#[tokio::test]
async fn with_icloud_off_a_core_store_write_marks_the_swift_metadata_by_the_quit() {
    let tasks = runtime::tasks().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let paths = tablepro_storage::StoragePaths::under(dir.path(), "tablepro", "app.tablepro.TablePro");
    let history = tablepro_storage::QueryHistory::open(&paths).await.unwrap();
    let mirror = Arc::new(tablepro_sync_testing::FakeLegacyMirror::new());
    let opened = open(&tasks, |parts| OpenParts {
        legacy_mirror: Some(mirror.clone() as Arc<dyn tablepro_sync::api::LegacyMirror>),
        history: Some(history.clone()),
        ..parts
    })
    .await;
    let id = Uuid::new_v4();

    history
        .saved_queries()
        .write(&tablepro_storage::SavedQueryWrite {
            queries: vec![tablepro_storage::saved_queries::SavedQuery {
                id,
                name: "Daily".to_owned(),
                query: "SELECT 1".to_owned(),
                connection_id: None,
                connection_name: String::new(),
                keyword: None,
                folder_id: None,
                order: 0,
                created_at: std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1),
                updated_at: std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1),
            }],
            ..tablepro_storage::SavedQueryWrite::default()
        })
        .await
        .unwrap();
    opened.service.flush_legacy_marks().await.unwrap();

    let dirty = mirror.metadata().dirty;
    let wire = id.hyphenated().to_string().to_uppercase();
    assert!(
        dirty
            .iter()
            .any(|record| record.record_type == "SQLFavorite" && record.id == wire),
        "{dirty:?}"
    );
}

// A profile that forces iCloud on a device already on TablePro Sync stops its personal sync there at once, at open and
// when the values change while the app runs, while its teams and key objects go on, until the person confirms the move
// back (core ADR 0055, Leaving a provider).
#[tokio::test]
async fn a_profile_that_forces_icloud_rests_personal_data_on_tablepro_sync_at_once() {
    use crate::account::AccountService;
    use crate::account::{ManagedPolicyArg, ManagedPolicyValues};
    use tablepro_sync::service::ServiceMode;

    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let (held_dir, free_dir) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let forced = ManagedPolicyValues {
        personal_sync_provider: Some(vec!["icloud".to_owned()]),
        ..ManagedPolicyValues::default()
    };
    let held = AccountService::holding(forced.clone(), tasks.clone(), held_dir.path());
    let free = AccountService::holding(ManagedPolicyValues::default(), tasks.clone(), free_dir.path());
    let at_open = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        account: Some(held),
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        ..parts
    })
    .await;
    let running = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        account: Some(Arc::clone(&free)),
        link: Ok(link(&server, AccountId(Uuid::new_v4()))),
        ..parts
    })
    .await;
    let before = running.service.service.now().unwrap().sync.mode();

    free.apply_policy(ManagedPolicyArg::Read { values: forced });
    let mut after = running.service.service.now().unwrap().sync.mode();
    for _ in 0..100 {
        if after == ServiceMode::TeamsOnly {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
        after = running.service.service.now().unwrap().sync.mode();
    }

    assert_eq!(
        at_open.service.service.now().unwrap().sync.mode(),
        ServiceMode::TeamsOnly
    );
    assert_eq!(before, ServiceMode::Personal);
    assert_eq!(after, ServiceMode::TeamsOnly);
}

// A sign-in to another account than the one whose file this device used last pushes nothing personal until the person
// picks Move my data or Start empty; a new sign-in of the same account is no switch (core ADR 0054, Another account or
// server).
#[tokio::test]
async fn another_account_on_tablepro_sync_waits_for_move_my_data_or_start_empty() {
    let tasks = runtime::tasks().unwrap();
    let server = FakeServer::new();
    let (first_account, other_account) = (AccountId(Uuid::new_v4()), AccountId(Uuid::new_v4()));
    let first = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::TableproSync),
        link: Ok(link(&server, first_account)),
        ..parts
    })
    .await;
    let kept = first.service.service_account().unwrap();
    let following = || SyncConfig {
        service_account: Some(kept.clone()),
        ..config(SyncProviderTag::TableproSync)
    };
    let other = open(&tasks, |parts| OpenParts {
        config: following(),
        link: Ok(link(&server, other_account)),
        ..parts
    })
    .await;
    let same = open(&tasks, |parts| OpenParts {
        config: following(),
        link: Ok(link(&server, first_account)),
        ..parts
    })
    .await;

    // The wait is in the new file before any pass, so a quit right after the open asks again.
    let plan = other.service.plan_new_identity().await.unwrap();
    let _ = same.service.sync_now(PassReasonTag::Person).await;
    let none = same.service.plan_new_identity().await.unwrap_err();

    assert!(plan.account.ends_with(&other_account.to_wire()), "{plan:?}");
    assert_eq!(code(&none), "sync.not_allowed");
}
