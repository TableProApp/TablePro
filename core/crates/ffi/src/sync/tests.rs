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

use super::engines::ServiceLink;
use super::keys::{GenesisOutcomeTag, KeyStateInfo, reviewed_member_info, team_keys_info};
use super::names::{Names, Person};
use super::open::OpenParts;
use super::service::{
    PassReasonTag, SyncCategoriesArg, SyncConfig, SyncListener, SyncPhaseTag, SyncPlatformTag, SyncService,
};
use crate::account::SyncProviderTag;
use crate::error::CoreError;
use crate::runtime;

// Counts the signals, and can hold the thread that calls it until the test lets go.
#[derive(Default)]
struct Listener {
    status: AtomicUsize,
    keys: AtomicUsize,
    held: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
}

impl SyncListener for Listener {
    fn status_changed(&self) {
        self.status.fetch_add(1, Ordering::SeqCst);
        if let Some(release) = self.held.lock().unwrap().take() {
            let _ = release.recv();
        }
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
        cloudkit: None,
        settings: None,
        device_store: Some(device_store as Arc<dyn tablepro_sync::api::HostDeviceStore>),
        legacy_mirror: None,
        link: Err(tablepro_sync::api::TransportError::SignedOut.into()),
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
async fn with_sync_off_the_status_is_off_and_nothing_runs() {
    let tasks = runtime::tasks().unwrap();
    let opened = open(&tasks, |parts| parts).await;

    let status = opened.service.status();
    let pass = opened.service.sync_now(PassReasonTag::Person).await.unwrap_err();

    assert_eq!(status.phase, SyncPhaseTag::Off);
    assert_eq!(status.provider, Some(SyncProviderTag::Off));
    assert_eq!(code(&pass), "sync.not_allowed");
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
        "sync.unimplemented",
        "the service engine has no team-only pass on iCloud yet"
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
    let (release, held) = std::sync::mpsc::channel();
    let listener = Arc::new(Listener {
        held: Mutex::new(Some(held)),
        ..Listener::default()
    });
    let opened = open(&tasks, |parts| OpenParts {
        config: config(SyncProviderTag::Icloud),
        cloudkit: Some(Arc::new(FakeCloudKit::signed_in("_a")) as Arc<dyn tablepro_sync::api::CloudKitTransport>),
        listener: listener.clone(),
        ..parts
    })
    .await;

    let pass = tokio::time::timeout(Duration::from_secs(30), opened.service.sync_now(PassReasonTag::Person)).await;
    release.send(()).unwrap();

    assert!(matches!(pass, Ok(Ok(()))), "{pass:?}");
    assert!(listener.status.load(Ordering::SeqCst) >= 1);
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

    let info = team_keys_info(keys, &names(team, ana));

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

    let info = reviewed_member_info(member, &names(team, ana));
    let back = super::keys::reviewed_member_arg(&info).unwrap();

    assert_eq!(info.team_name.as_deref(), Some("Acme"));
    assert_eq!(info.name.as_deref(), Some("Ana"));
    assert_eq!(back, member);
    assert_eq!(
        super::keys::reviewed_member_arg(&super::keys::ReviewedMemberInfo {
            confirmed_under_av: 0,
            ..info
        }),
        Err(SyncError::Malformed { what: "version" })
    );
}
