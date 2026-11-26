// A stale file's key tables rebuilt through the key flows and the engine (0054, A stale file; Verification): from the
// server's key objects at or above the anchored checkpoint, with no comparison, handling no secret until the server
// showed every anchored pin and version, and never ending while it shows less.

use std::sync::Arc;

use secrecy::{ExposeSecret, SecretString};
use serde_json::json;
use tablepro_keys::encoding::{AccountId, KeyPurpose, Origin, TeamId, Version, random_uuid, uuid_to_wire};
use tablepro_keys::envelope::{EnvelopeId, ParentKind, SecretKind};
use tablepro_sync::api::control::PassReason;
use tablepro_sync::api::device_store::HostDeviceStore;
use tablepro_sync::api::ids::{DeviceRowId, ScopeName};
use tablepro_sync::api::key_flows::{
    AccountFlows, KeyFlows, KeyHooks, KeyState, RecoveryKeyDraft, TeamFlows, TypedBack,
};
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{
    KeyTrust, KeyVersionRow, KeyVersionState, Row, RowKey, StateIdentity, StateStore, SyncTrust,
};
use tablepro_sync::api::transport::ServiceTransport;
use tablepro_sync::engine::{Adapters, EngineHooks, Journal, StopSignal, SystemClock, Wake};
use tablepro_sync::keys::{Clock, KeyService, KeyServiceParts};
use tablepro_sync::service::{ProofSource, ServiceParts, ServiceSync};
use tablepro_sync_testing::FakeServer;

use super::support::Disk;

fn origin() -> Origin {
    Origin::parse("https://sync.example.com").unwrap()
}

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn typed_back(draft: &RecoveryKeyDraft) -> TypedBack {
    let groups: Vec<String> = draft.text.expose_secret().split('-').map(str::to_owned).collect();
    TypedBack {
        groups: draft
            .check
            .map(|index| SecretString::from(groups[usize::from(index)].to_lowercase())),
    }
}

fn connection() -> EnvelopeId {
    EnvelopeId::new(
        ParentKind::Connection,
        &uuid_to_wire(random_uuid().unwrap()),
        SecretKind::Password,
    )
    .unwrap()
}

fn identity(account: AccountId) -> StateIdentity {
    identity_on(account, "dev_mac")
}

fn identity_on(account: AccountId, row: &str) -> StateIdentity {
    StateIdentity::Service {
        origin: origin(),
        sign_in: "sign-in".to_owned(),
        account,
        device_row: DeviceRowId(row.to_owned()),
    }
}

struct ServerClock(Arc<FakeServer>);

impl Clock for ServerClock {
    fn now_us(&self) -> i64 {
        self.0.now_us()
    }
}

// One launch of the app: the state file on disk, the device store a restart keeps, the key flows and the engine.
struct Device {
    keys: Arc<KeyService>,
    sync: ServiceSync,
    state: Arc<dyn StateStore>,
    server: Arc<FakeServer>,
    row: DeviceRowId,
}

impl Device {
    async fn launch(disk: &Disk, server: &Arc<FakeServer>, account: AccountId) -> Self {
        Self::launch_on(disk, server, account, "dev_mac").await
    }

    async fn launch_on(disk: &Disk, server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        let row = DeviceRowId(row.to_owned());
        let state = disk.open_as(&identity_on(account, &row.0)).await;
        let transport = Arc::new(server.client(account, row.clone()));
        let wake = Wake::new();
        let hooks = Arc::new(EngineHooks::new(wake.clone(), None));
        let keys = Arc::new(KeyService::new(KeyServiceParts {
            origin: origin(),
            account,
            device_row: row.clone(),
            state: Arc::clone(&state),
            device_store: Arc::clone(&disk.store) as Arc<dyn HostDeviceStore>,
            transport: Arc::clone(&transport) as Arc<dyn ServiceTransport>,
            hooks: Arc::clone(&hooks) as Arc<dyn KeyHooks>,
            clock: Arc::new(ServerClock(Arc::clone(server))),
        }));
        let sync = ServiceSync::new(ServiceParts {
            transport,
            state: Arc::clone(&state),
            adapters: Adapters::default(),
            keys: Arc::clone(&keys) as Arc<dyn KeyFlows>,
            hooks,
            proofs: Arc::clone(&keys) as Arc<dyn ProofSource>,
            clock: Arc::new(SystemClock),
            stop: StopSignal::new(),
            journal: Journal::new(wake),
            events: None,
        });
        Self {
            keys,
            sync,
            state,
            server: Arc::clone(server),
            row,
        }
    }

    async fn pass(&self) {
        self.sync.run_pass(PassReason::Person).await.unwrap();
    }

    async fn genesis(&self) -> SecretString {
        self.pass().await;
        let draft = self.keys.begin_genesis().await.unwrap();
        self.keys.finish_genesis(draft.draft, typed_back(&draft)).await.unwrap();
        let device = self.keys.device_keys().await.unwrap().current.unwrap();
        self.server.approve(&self.row, device.dsk.public().unwrap().0);
        draft.text
    }

    async fn replace(&self, recovery_key: SecretString) -> SecretString {
        let draft = self.keys.begin_replace(recovery_key).await.unwrap();
        self.keys
            .finish_replace(draft.recovery.draft, typed_back(&draft.recovery), Vec::new())
            .await
            .unwrap();
        draft.recovery.text
    }

    async fn seal(&self) -> Result<serde_json::Value, &'static str> {
        self.seal_at(connection()).await
    }

    async fn seal_at(&self, envelope: EnvelopeId) -> Result<serde_json::Value, &'static str> {
        self.keys
            .seal_personal_envelope(envelope, SecretString::from("s3cret"), json!({}))
            .await
            .map_err(|error| error.code())
    }

    async fn open(&self, envelope: EnvelopeId, fields: serde_json::Value) -> Result<Version, &'static str> {
        self.keys
            .open_personal_envelope(envelope, fields, None)
            .await
            .map(|opened| opened.kv)
            .map_err(|error| error.code())
    }

    async fn seal_team(&self, team: TeamId) -> Result<serde_json::Value, &'static str> {
        let parent = uuid_to_wire(random_uuid().unwrap()).to_lowercase();
        let envelope = EnvelopeId::new(ParentKind::LibraryConnection, &parent, SecretKind::Password).unwrap();
        self.keys
            .seal_team_envelope(team, envelope, SecretString::from("s3cret"), json!({}))
            .await
            .map_err(|error| error.code())
    }

    async fn team_row(&self, team: TeamId) -> Option<KeyVersionRow> {
        let row = self
            .state
            .begin()
            .await
            .unwrap()
            .get(&RowKey::KeyVersion(ScopeName::Team(team), KeyPurpose::Team))
            .await
            .unwrap();
        match row {
            Some(Row::KeyVersion(row)) => Some(row),
            _ => None,
        }
    }

    async fn own_av(&self, account: AccountId) -> Option<Version> {
        let row = self
            .state
            .begin()
            .await
            .unwrap()
            .get(&RowKey::KeyPin(account))
            .await
            .unwrap();
        match row {
            Some(Row::KeyPin(pin)) => Some(pin.av),
            _ => None,
        }
    }
}

// The account at av 2 after a replace, and a copy of the state file from when it was at av 1.
async fn replaced_after_a_copy(disk: &Disk, server: &Arc<FakeServer>, account: AccountId) -> Vec<u8> {
    let mac = Device::launch(disk, server, account).await;
    let recovery = mac.genesis().await;
    mac.pass().await;
    drop(mac);
    let copy = disk.copy(&identity(account)).await;
    let mac = Device::launch(disk, server, account).await;
    mac.replace(recovery).await;
    mac.pass().await;
    drop(mac);
    copy
}

#[tokio::test]
async fn a_stale_file_rebuilds_from_the_server_with_no_comparison_and_trusts_its_keys_once_shown() {
    let server = FakeServer::new();
    let account = AccountId(random_uuid().unwrap());
    let disk = Disk::new();
    let copy = replaced_after_a_copy(&disk, &server, account).await;

    disk.restore(&identity(account), &copy).await;
    let mac = Device::launch(&disk, &server, account).await;
    let opened = mac.state.opened().clone();
    let before = mac.seal().await;
    mac.pass().await;
    let after = mac.seal().await;
    let state = mac.keys.key_state().await.unwrap();
    let av = mac.own_av(account).await;
    drop(mac);
    let relaunched = Device::launch(&disk, &server, account).await;

    assert_eq!(opened.sync_tables, SyncTrust::Refill);
    assert!(
        matches!(&opened.key_tables, KeyTrust::Rebuild { checkpoint } if checkpoint.pins.iter().any(|pin| pin.av == v(2)))
    );
    assert_eq!(before, Err("sync.not_allowed"));
    assert!(after.is_ok(), "{after:?}");
    assert!(
        matches!(state, KeyState::Approved { av, .. } if av == v(2)),
        "{state:?}"
    );
    assert_eq!(av, Some(v(2)));
    assert_eq!(relaunched.state.opened().key_tables, KeyTrust::Trusted);
    assert!(!relaunched.keys.is_rebuilding());
}

// The server lost the replace (a restore of its own) while the device's file went back too: the anchor's newer `av`
// and versions are never shown, so the rebuild never ends and no secret is written.
#[tokio::test]
async fn a_rebuild_never_ends_while_the_server_shows_less_than_the_anchor_holds() {
    let server = FakeServer::new();
    let account = AccountId(random_uuid().unwrap());
    let disk = Disk::new();
    let mac = Device::launch(&disk, &server, account).await;
    let recovery = mac.genesis().await;
    mac.pass().await;
    drop(mac);
    let copy = disk.copy(&identity(account)).await;
    let backup = server.backup();
    let mac = Device::launch(&disk, &server, account).await;
    mac.replace(recovery).await;
    mac.pass().await;
    drop(mac);

    server.restore(&backup);
    disk.restore(&identity(account), &copy).await;
    let mac = Device::launch(&disk, &server, account).await;
    mac.pass().await;
    mac.pass().await;
    let sealed = mac.seal().await;
    let av = mac.own_av(account).await;
    let rebuilding = mac.keys.is_rebuilding();
    drop(mac);
    let relaunched = Device::launch(&disk, &server, account).await;

    assert!(rebuilding);
    assert_eq!(sealed, Err("sync.not_allowed"));
    assert_eq!(av, Some(v(2)));
    assert!(matches!(relaunched.state.opened().key_tables, KeyTrust::Rebuild { .. }));
}

// The anchored personal and history versions stand in the key tables from the open on, with their record digests, so
// a version record at an anchored version with another digest is never taken.
#[tokio::test]
async fn the_anchored_versions_stand_in_the_key_tables_from_the_open_on() {
    let server = FakeServer::new();
    let account = AccountId(random_uuid().unwrap());
    let disk = Disk::new();
    let copy = replaced_after_a_copy(&disk, &server, account).await;
    let mac = Device::launch(&disk, &server, account).await;
    let anchored = mac
        .state
        .begin()
        .await
        .unwrap()
        .get(&RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
        .unwrap();
    drop(mac);

    disk.restore(&identity(account), &copy).await;
    let mac = Device::launch(&disk, &server, account).await;
    let installed = mac
        .state
        .begin()
        .await
        .unwrap()
        .get(&RowKey::KeyVersion(ScopeName::Personal, KeyPurpose::Personal))
        .await
        .unwrap();

    assert!(matches!(&anchored, Some(Row::KeyVersion(row)) if row.version == v(2)));
    assert_eq!(installed, anchored);
}

// An envelope below its anchored `kv` is refused after the restore, though the copy the file went back to held it.
#[tokio::test]
async fn after_a_restore_an_envelope_below_its_anchored_kv_is_refused() {
    let server = FakeServer::new();
    let account = AccountId(random_uuid().unwrap());
    let disk = Disk::new();
    let envelope = connection();
    let mac = Device::launch(&disk, &server, account).await;
    let recovery = mac.genesis().await;
    mac.pass().await;
    let older = mac.seal_at(envelope.clone()).await.unwrap();
    drop(mac);
    let copy = disk.copy(&identity(account)).await;
    let mac = Device::launch(&disk, &server, account).await;
    mac.replace(recovery).await;
    mac.pass().await;
    let newer = mac.seal_at(envelope.clone()).await.unwrap();
    drop(mac);

    disk.restore(&identity(account), &copy).await;
    let mac = Device::launch(&disk, &server, account).await;
    mac.pass().await;

    assert!(!mac.keys.is_rebuilding());
    assert_eq!(mac.open(envelope.clone(), older).await, Err("keys.stale"));
    assert_eq!(mac.open(envelope, newer).await, Ok(v(2)));
}

// The owner's file goes back to before its own team rotation: the anchored team row stands in with its holders, the
// team's objects come back in its snapshot, and team secrets are written again under the anchored version once shown.
#[tokio::test]
async fn a_team_key_rebuilds_on_its_anchored_version() {
    let server = FakeServer::new();
    let (owner_id, member_id) = (AccountId(random_uuid().unwrap()), AccountId(random_uuid().unwrap()));
    let team = TeamId(random_uuid().unwrap());
    server.add_team(team, &[(owner_id, Role::Owner), (member_id, Role::Member)]);
    let (owner_disk, member_disk) = (Disk::new(), Disk::new());
    let owner = Device::launch_on(&owner_disk, &server, owner_id, "dev_owner").await;
    owner.genesis().await;
    owner.pass().await;
    owner.keys.create_team_keys(team).await.unwrap();
    let member = Device::launch_on(&member_disk, &server, member_id, "dev_member").await;
    member.genesis().await;
    member.pass().await;
    owner.pass().await;
    owner.keys.confirm_member(team, member_id).await.unwrap();
    owner.pass().await;
    drop(owner);
    let copy = owner_disk.copy(&identity_on(owner_id, "dev_owner")).await;
    let owner = Device::launch_on(&owner_disk, &server, owner_id, "dev_owner").await;
    owner.pass().await;
    owner.keys.rotate_team(team, Vec::new()).await.unwrap();
    owner.pass().await;
    let anchored = owner.team_row(team).await.unwrap();
    let sealed = owner.seal_team(team).await;
    drop(owner);

    owner_disk.restore(&identity_on(owner_id, "dev_owner"), &copy).await;
    let owner = Device::launch_on(&owner_disk, &server, owner_id, "dev_owner").await;
    let installed = owner.team_row(team).await;
    let before = owner.seal_team(team).await;
    owner.pass().await;
    let after = owner.seal_team(team).await;

    assert_eq!((anchored.version, anchored.state), (v(2), KeyVersionState::Ok));
    assert!(sealed.is_ok(), "{sealed:?}");
    assert_eq!(installed, Some(anchored.clone()));
    assert_eq!(before, Err("sync.not_allowed"));
    assert!(!owner.keys.is_rebuilding());
    assert_eq!(after.map(|fields| fields["kv"].clone()), Ok(json!(2)));
    assert_eq!(owner.team_row(team).await, Some(anchored));
    drop(member);
}

// A team the device left while its file went back can never be shown: the rebuild ends on what it still reads, and the
// team's anchored row stays as the floor a later copy is held to.
#[tokio::test]
async fn a_team_the_device_left_does_not_hold_the_rebuild_open() {
    let server = FakeServer::new();
    let (owner_id, member_id) = (AccountId(random_uuid().unwrap()), AccountId(random_uuid().unwrap()));
    let team = TeamId(random_uuid().unwrap());
    server.add_team(team, &[(owner_id, Role::Owner), (member_id, Role::Member)]);
    let (owner_disk, member_disk) = (Disk::new(), Disk::new());
    let owner = Device::launch_on(&owner_disk, &server, owner_id, "dev_owner").await;
    owner.genesis().await;
    owner.pass().await;
    owner.keys.create_team_keys(team).await.unwrap();
    let member = Device::launch_on(&member_disk, &server, member_id, "dev_member").await;
    member.genesis().await;
    member.pass().await;
    owner.pass().await;
    owner.keys.confirm_member(team, member_id).await.unwrap();
    member.pass().await;
    drop(member);
    let copy = member_disk.copy(&identity_on(member_id, "dev_member")).await;
    let member = Device::launch_on(&member_disk, &server, member_id, "dev_member").await;
    member.state.begin().await.unwrap().commit().await.unwrap();
    let anchored = member.team_row(team).await.unwrap();
    drop(member);

    server.set_role(team, member_id, None);
    member_disk.restore(&identity_on(member_id, "dev_member"), &copy).await;
    let member = Device::launch_on(&member_disk, &server, member_id, "dev_member").await;
    member.pass().await;

    assert!(!member.keys.is_rebuilding());
    assert!(member.seal().await.is_ok());
    assert_eq!(member.team_row(team).await, Some(anchored));
    drop(owner);
}
