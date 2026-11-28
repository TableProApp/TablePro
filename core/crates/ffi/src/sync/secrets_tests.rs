// A password end to end over the fake `/v2/sync` server (core ADRs 0044, 0051 and 0056): two Macs of one account, each
// with its own Core, connection library, secret store and state file, and the real key flows.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use secrecy::{ExposeSecret, SecretString};
use tablepro_core::credentials::{SecretKind as StoredKind, SecretLookup};
use tablepro_keys::encoding::{AccountId, Origin};
use tablepro_session::runtime::Tasks;
use tablepro_sync::api::{DeviceRowId, HostDeviceStore, StateFiles};
use tablepro_sync_testing::service::{Policies, ScopeOwner};
use tablepro_sync_testing::{FakeDeviceStore, FakeServer, MemoryStateFiles};
use uuid::Uuid;

use super::super::engines::ServiceLink;
use super::super::keys::{KeyStateInfo, SessionPhaseTag};
use super::super::open::OpenParts;
use super::super::service::{
    HeldReasonTag, PassReasonTag, SyncCategoriesArg, SyncConfig, SyncListener, SyncPlatformTag, SyncService,
};
use super::{CoreSecrets, HostSyncedSecrets, SyncedSecretParentTag, SyncedSecretRef};
use crate::account::SyncProviderTag;
use crate::core_handle::Core;
use crate::host::{
    HostConfig, HostSecretError, HostSecrets, ProfileKindTag, SecretDeletionTag, SecretItemTag, SecretKindTag,
};
use crate::library::{ConnectionRecord, ConnectionSecrets, SafeModeTag, TlsModeTag, TlsSettings};
use crate::runtime;

type Kept = Arc<Mutex<HashMap<(String, SecretKindTag), SecretString>>>;

// One Mac's Keychain for its connections.
#[derive(Default, Clone)]
struct Keychain(Kept);

impl Keychain {
    fn password(&self, connection: &str) -> Option<String> {
        self.0
            .lock()
            .unwrap()
            .get(&(connection.to_owned(), SecretKindTag::DatabasePassword))
            .map(|secret| secret.expose_secret().to_owned())
    }
}

impl HostSecrets for Keychain {
    fn load(&self, connection_id: String, kind: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&(connection_id, kind)).cloned())
    }

    fn store(
        &self,
        connection_id: String,
        kind: SecretKindTag,
        secret: SecretString,
        _: String,
    ) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().insert((connection_id, kind), secret);
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, connection_id: String, kind: SecretKindTag) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().remove(&(connection_id, kind));
        Ok(())
    }

    fn delete_connection(&self, connection_id: String) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().retain(|(id, _), _| *id != connection_id);
        Ok(())
    }

    fn delete_profile(&self, _: String, _: ProfileKindTag) -> Result<SecretDeletionTag, HostSecretError> {
        Ok(SecretDeletionTag::NotOwned)
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

// The secrets the Mac keeps for its profiles, which `HostSecrets` does not reach.
#[derive(Default, Clone)]
struct ProfileSecrets(Arc<Mutex<HashMap<(String, String), SecretString>>>);

impl HostSyncedSecrets for ProfileSecrets {
    fn kinds(&self, parent: SyncedSecretParentTag) -> Vec<String> {
        match parent {
            SyncedSecretParentTag::SshProfile => vec!["ssh_password".to_owned()],
            SyncedSecretParentTag::CredentialProfile => vec!["password".to_owned()],
            SyncedSecretParentTag::Connection => Vec::new(),
        }
    }

    fn load(&self, secret: SyncedSecretRef) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&(secret.parent_id, secret.kind)).cloned())
    }

    fn store(&self, secret: SyncedSecretRef, value: SecretString) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().insert((secret.parent_id, secret.kind), value);
        Ok(())
    }

    fn delete(&self, secret: SyncedSecretRef) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().remove(&(secret.parent_id, secret.kind));
        Ok(())
    }
}

struct Quiet;

impl SyncListener for Quiet {
    fn status_changed(&self) {}

    fn keys_changed(&self) {}

    fn approvals_changed(&self) {}
}

struct Mac {
    core: Arc<Core>,
    keychain: Keychain,
    profiles: ProfileSecrets,
    service: Arc<SyncService>,
    row: DeviceRowId,
    _dir: tempfile::TempDir,
}

const ORIGIN: &str = "https://sync.example.com";

fn record(name: &str, host: &str) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: name.to_owned(),
        driver_id: "postgres".to_owned(),
        host: host.to_owned(),
        port: 5432,
        database: "shop".to_owned(),
        username: "app".to_owned(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Disable,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode: SafeModeTag::Silent,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
        ai_policy: None,
        external_access: None,
        project_id: None,
        icon: None,
        order: 0,
    }
}

impl Mac {
    // A Mac signed in to `account` on `row`, with TablePro Sync and its Passwords switch on.
    async fn open(tasks: &Tasks, server: &Arc<FakeServer>, account: AccountId, row: &str) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let keychain = Keychain::default();
        let profiles = ProfileSecrets::default();
        let core = Core::new(
            HostConfig {
                client_version: "test".to_owned(),
                storage_dir: Some(dir.path().join("store").display().to_string()),
            },
            Box::new(keychain.clone()),
        )
        .unwrap();
        let row = DeviceRowId(row.to_owned());
        let store = core.connection_store().unwrap();
        let secrets = Arc::new(CoreSecrets::new(
            core.vault(),
            store.clone(),
            core.writes(),
            Some(Arc::new(profiles.clone()) as Arc<dyn HostSyncedSecrets>),
            tasks.clone(),
        ));
        let parts = OpenParts {
            config: SyncConfig {
                platform: SyncPlatformTag::Macos,
                provider: SyncProviderTag::Off,
                categories: SyncCategoriesArg {
                    off_kinds: Vec::new(),
                    passwords: true,
                },
                icloud_account: None,
                service_account: None,
                route_publisher: None,
            },
            account: None,
            files: Some(Arc::new(MemoryStateFiles::new()) as Arc<dyn StateFiles>),
            connections: Some(store.clone()),
            cloudkit: None,
            settings: None,
            device_store: Some(Arc::new(FakeDeviceStore::new()) as Arc<dyn HostDeviceStore>),
            legacy_mirror: None,
            library: Some(store),
            history: None,
            saved_queries: None,
            link: Ok(ServiceLink {
                origin: Origin::parse(ORIGIN).unwrap(),
                sign_in: "sync.example.com".to_owned(),
                account,
                device_row: row.clone(),
                transport: Arc::new(server.client(account, row.clone())),
                binding: None,
            }),
            session: None,
            listener: Arc::new(Quiet),
            team_library: None,
            secrets: Some(secrets),
        };
        let opener = tasks.clone();
        let service = tasks
            .spawn_task(async move { SyncService::open(opener, parts).await })
            .await
            .unwrap();
        Self {
            core,
            keychain,
            profiles,
            service,
            row,
            _dir: dir,
        }
    }

    async fn pass(&self) {
        self.service.sync_now(PassReasonTag::Person).await.unwrap();
    }

    // The server takes this Mac's device key as approved, as the real one does once the approval change set lands.
    async fn server_approves(&self, server: &FakeServer) {
        let engine = self.service.service.now().unwrap();
        let held = engine.keys.device_keys().await.unwrap();
        let dsk = held.current.unwrap().dsk.public().unwrap().0;
        server.approve(&self.row, dsk);
    }

    async fn save(&self, name: &str, host: &str, password: &str) -> String {
        let saved = self
            .core
            .library()
            .unwrap()
            .save(
                record(name, host),
                ConnectionSecrets {
                    database_password: Some(SecretString::from(password.to_owned())),
                    ssh_password: None,
                    ssh_passphrase: None,
                },
            )
            .await
            .unwrap();
        saved.id.to_uppercase()
    }

    // The first Mac: keys behind a confirmed recovery key, then its personal data onto TablePro Sync.
    async fn first_upload(&self, server: &FakeServer) -> SecretString {
        self.pass().await;
        let draft = self.service.begin_genesis().await.unwrap();
        let recovery = draft.text.clone();
        let typed = typed(&draft.text, &draft.check);
        self.service.finish_genesis(draft.draft, typed).await.unwrap();
        self.server_approves(server).await;
        self.service
            .choose_provider(SyncProviderTag::TableproSync)
            .await
            .unwrap();
        self.pass().await;
        recovery
    }

    // `self` asks, `approver` picks the request, both compare the same words and confirm.
    async fn approved_by(&self, approver: &Mac, server: &FakeServer) {
        self.pass().await;
        let request = self.service.request_approval().await.unwrap();
        approver.pass().await;
        approver.service.choose_approval_request(request.clone()).await.unwrap();
        self.pass().await;
        let words = |phase: SessionPhaseTag| match phase {
            SessionPhaseTag::Compare { words } => words,
            other => panic!("no words to compare: {other:?}"),
        };
        let mine = words(self.service.approval_session(request.clone()).await.unwrap().phase);
        approver.pass().await;
        let theirs = words(approver.service.approval_session(request.clone()).await.unwrap().phase);
        assert_eq!(mine, theirs);
        approver
            .service
            .confirm_approval_session(request.clone())
            .await
            .unwrap();
        self.pass().await;
        let session = self.service.confirm_approval_session(request).await.unwrap();
        assert_eq!(session.phase, SessionPhaseTag::Approved);
        self.server_approves(server).await;
        self.service
            .choose_provider(SyncProviderTag::TableproSync)
            .await
            .unwrap();
        self.pass().await;
    }

    // What waits for the person on this Mac, each record approved whole.
    async fn approve_all(&self) {
        for approval in self.service.approvals().await.unwrap() {
            self.service
                .decide_record_approval(approval.record, approval.digest, true)
                .await
                .unwrap();
        }
        self.pass().await;
    }

    // As a connect that kept the password it logged in with, which writes no record.
    async fn save_password(&self, connection: &str, password: &str) {
        let id = Uuid::parse_str(connection).unwrap();
        self.core
            .vault()
            .store(
                id,
                StoredKind::DatabasePassword,
                &SecretString::from(password.to_owned()),
                "",
            )
            .await
            .unwrap();
    }

    async fn remove_password(&self, connection: &str) {
        let id = Uuid::parse_str(connection).unwrap();
        self.core
            .vault()
            .delete_kind(id, StoredKind::DatabasePassword)
            .await
            .unwrap();
    }

    async fn vault_password(&self, connection: &str) -> Option<String> {
        let id = Uuid::parse_str(connection).unwrap();
        match self.core.vault().load(id, StoredKind::DatabasePassword).await.unwrap() {
            SecretLookup::Found(secret) => Some(secret.expose_secret().to_owned()),
            SecretLookup::NotStored => None,
        }
    }
}

// The fake server at this machine's time: the engine's key flows read the system clock, and an approval session the
// server dated months back would read as expired.
fn server_now() -> Arc<FakeServer> {
    let server = FakeServer::new();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_micros();
    server.advance_clock(i64::try_from(now).unwrap() - server.now_us());
    server
}

fn typed(text: &SecretString, check: &[u8]) -> Vec<SecretString> {
    let groups: Vec<String> = text.expose_secret().split('-').map(str::to_lowercase).collect();
    check
        .iter()
        .map(|index| SecretString::from(groups[usize::from(*index)].clone()))
        .collect()
}

fn envelope_id(connection: &str) -> String {
    format!("connection/{connection}/password")
}

fn stored_envelope(server: &FakeServer, account: AccountId, connection: &str) -> Option<serde_json::Value> {
    server
        .stored(
            ScopeOwner::Personal(account),
            "secret_envelope",
            &envelope_id(connection),
        )
        .filter(|record| record.deleted.is_none())
        .and_then(|record| record.fields)
}

fn kv(fields: &serde_json::Value) -> u64 {
    fields["kv"].as_u64().unwrap()
}

#[tokio::test]
async fn a_password_saved_on_one_mac_opens_on_the_next_one_and_never_reaches_the_server_in_the_clear() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let account = AccountId(Uuid::new_v4());
    let first = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww4").await;
    let connection = first.save("prod", "db.internal", "hunter2").await;
    first.first_upload(&server).await;

    let sealed = stored_envelope(&server, account, &connection).expect("the envelope went up");
    let second = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww5").await;
    second.approved_by(&first, &server).await;
    let before_approval = second.vault_password(&connection).await;
    let held = second.service.held_records().await.unwrap();
    second.approve_all().await;
    let after_approval = second.vault_password(&connection).await;
    second.pass().await;
    let unchanged = stored_envelope(&server, account, &connection);

    assert!(!sealed.to_string().contains("hunter2"), "{sealed}");
    for member in ["suite", "kv", "nonce", "ct"] {
        assert!(sealed.get(member).is_some(), "{member}: {sealed}");
    }
    // A new connection waits for the person, and its password with it.
    assert_eq!(before_approval, None);
    assert!(
        held.iter()
            .any(|held| held.record.kind == "secret_envelope" && held.reason == HeldReasonTag::AwaitingApproval),
        "{held:?}"
    );
    assert_eq!(after_approval.as_deref(), Some("hunter2"));
    assert_eq!(
        second.keychain.password(&connection.to_lowercase()).as_deref(),
        Some("hunter2")
    );
    assert_eq!(
        unchanged,
        Some(sealed),
        "a password that did not change is not sealed again"
    );
}

#[tokio::test]
async fn a_password_changed_on_either_mac_reaches_the_other_and_a_removed_one_is_removed() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let account = AccountId(Uuid::new_v4());
    let first = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww4").await;
    let connection = first.save("prod", "db.internal", "hunter2").await;
    first.first_upload(&server).await;
    let second = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww5").await;
    second.approved_by(&first, &server).await;
    second.approve_all().await;

    second.save_password(&connection, "correct horse").await;
    second.pass().await;
    first.pass().await;
    let changed = first.vault_password(&connection).await;
    first.remove_password(&connection).await;
    first.pass().await;
    second.pass().await;
    let removed = second.vault_password(&connection).await;

    assert_eq!(changed.as_deref(), Some("correct horse"));
    assert_eq!(stored_envelope(&server, account, &connection), None);
    assert_eq!(removed, None);
}

#[tokio::test]
async fn a_new_recovery_key_seals_every_password_again_under_the_new_key_and_both_macs_still_read_it() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let account = AccountId(Uuid::new_v4());
    let first = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww4").await;
    let connection = first.save("prod", "db.internal", "hunter2").await;
    let recovery = first.first_upload(&server).await;
    let second = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww5").await;
    second.approved_by(&first, &server).await;
    second.approve_all().await;
    let before = stored_envelope(&server, account, &connection).unwrap();

    let draft = first.service.begin_replace_recovery_key(recovery).await.unwrap();
    let keep: Vec<String> = draft
        .devices
        .iter()
        .filter(|reviewed| !reviewed.device.this_device)
        .map(|reviewed| reviewed.device.key_device.clone())
        .collect();
    let typed = typed(&draft.recovery.text, &draft.recovery.check);
    first
        .service
        .finish_replace_recovery_key(draft.recovery.draft, typed, keep)
        .await
        .unwrap();
    first.pass().await;
    second.pass().await;
    first.pass().await;
    let after = stored_envelope(&server, account, &connection).unwrap();
    first.save_password(&connection, "after rotation").await;
    first.pass().await;
    second.pass().await;

    assert_eq!(kv(&before), 1);
    assert_eq!(kv(&after), 2, "{after}");
    assert!(matches!(
        second.service.key_state().await.unwrap(),
        KeyStateInfo::Approved { av: 2, .. }
    ));
    assert_eq!(
        second.vault_password(&connection).await.as_deref(),
        Some("after rotation")
    );
}

#[tokio::test]
async fn with_password_sync_off_no_password_goes_up_the_scope_says_why_and_each_mac_keeps_its_own() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let account = AccountId(Uuid::new_v4());
    server.set_policies(Policies {
        password_sync: false,
        ..Policies::default()
    });
    let first = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww4").await;
    let connection = first.save("prod", "db.internal", "hunter2").await;
    first.first_upload(&server).await;
    first.pass().await;
    let policy = first
        .service
        .scope_statuses()
        .into_iter()
        .find(|scope| scope.scope == "personal")
        .and_then(|scope| scope.password_sync);

    server.set_policies(Policies::default());
    first.pass().await;
    let on_again = stored_envelope(&server, account, &connection);
    server.set_policies(Policies {
        password_sync: false,
        ..Policies::default()
    });
    first.pass().await;

    assert_eq!(policy, Some(false));
    assert!(on_again.is_some(), "turned back on, the password goes up");
    assert_eq!(
        stored_envelope(&server, account, &connection),
        None,
        "turned off, the server tombstones it"
    );
    assert_eq!(first.vault_password(&connection).await.as_deref(), Some("hunter2"));
    assert_eq!(first.service.status().problem, None);
}

#[tokio::test]
async fn before_the_recovery_key_is_confirmed_a_password_stays_on_the_mac() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let account = AccountId(Uuid::new_v4());
    let first = Mac::open(&tasks, &server, account, "dev_01k8d6wpggfd68tbhz818p4ww4").await;
    let connection = first.save("prod", "db.internal", "hunter2").await;
    first.pass().await;

    let plan = first.service.plan_move_to_service().await.unwrap();
    let draft = first.service.begin_genesis().await.unwrap();
    first.pass().await;

    assert_eq!(plan.secrets_to_seal, 1, "{plan:?}");
    assert_eq!(stored_envelope(&server, account, &connection), None);
    drop(draft);
}

// A connection's own secrets stay in this Core's store; a profile's go to the app's, under the record's id as the wire
// names it, and only the kinds the app said it keeps.
#[tokio::test]
async fn a_profile_s_secret_goes_through_the_app_and_a_connection_s_through_this_core() {
    use tablepro_records::Kind;
    use tablepro_records::envelope::SecretKind;
    use tablepro_sync::api::secrets::{DeviceSecrets, SecretRef};

    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let mac = Mac::open(
        &tasks,
        &server,
        AccountId(Uuid::new_v4()),
        "dev_01k8d6wpggfd68tbhz818p4ww4",
    )
    .await;
    let secrets = CoreSecrets::new(
        mac.core.vault(),
        mac.core.connection_store().unwrap(),
        mac.core.writes(),
        Some(Arc::new(mac.profiles.clone()) as Arc<dyn HostSyncedSecrets>),
        tasks.clone(),
    );
    let profile = Uuid::new_v4();
    let connection = Uuid::new_v4();
    let of = |parent, parent_id, secret| SecretRef {
        parent,
        parent_id,
        secret,
    };

    secrets
        .store(
            &of(Kind::SshProfile, profile, SecretKind::SshPassword),
            &SecretString::from("tunnel"),
        )
        .await
        .unwrap();
    secrets
        .store(
            &of(Kind::Connection, connection, SecretKind::Password),
            &SecretString::from("hunter2"),
        )
        .await
        .unwrap();
    let unkept = secrets
        .load(&of(Kind::SshProfile, profile, SecretKind::SshTotpSecret))
        .await;

    assert_eq!(
        secrets.kinds(Kind::Connection),
        [
            SecretKind::Password,
            SecretKind::SshPassword,
            SecretKind::SshKeyPassphrase
        ]
    );
    assert_eq!(secrets.kinds(Kind::SshProfile), [SecretKind::SshPassword]);
    assert_eq!(secrets.kinds(Kind::CredentialProfile), [SecretKind::Password]);
    let held = mac.profiles.0.lock().unwrap().clone();
    assert_eq!(
        held.get(&(tablepro_records::record_id::uuid_id(profile), "ssh_password".to_owned()))
            .map(|secret| secret.expose_secret().to_owned())
            .as_deref(),
        Some("tunnel")
    );
    assert_eq!(
        held.len(),
        1,
        "a connection's password never reaches the app's other store"
    );
    assert_eq!(
        mac.keychain.password(&connection.to_string()).as_deref(),
        Some("hunter2")
    );
    assert!(unkept.is_err(), "a kind the app does not keep is never asked for");
}

// A record and its secrets are read as one library write left them: a read waits for a save in flight, so a password
// is never sealed for the destination the save is replacing.
#[tokio::test]
async fn secrets_are_read_between_library_writes_never_during_one() {
    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let mac = Mac::open(
        &tasks,
        &server,
        AccountId(Uuid::new_v4()),
        "dev_01k8d6wpggfd68tbhz818p4ww4",
    )
    .await;
    mac.save("prod", "db.internal", "hunter2").await;
    let saving = Arc::clone(&mac.core.writes()).lock_owned().await;
    let service = Arc::clone(&mac.service);
    let mut plan = tasks.spawn_task(async move { service.plan_move_to_service().await });

    let during = tokio::time::timeout(std::time::Duration::from_millis(300), &mut plan).await;
    drop(saving);
    let after = plan.await.unwrap().unwrap();

    assert!(
        during.is_err(),
        "the read went on while a library write held the library"
    );
    assert_eq!(after.secrets_to_seal, 1);
}

// The Mac's host for every secret it syncs, its connections' own among them.
#[derive(Default, Clone)]
struct EverySecret(Arc<Mutex<HashMap<(String, String), SecretString>>>);

impl HostSyncedSecrets for EverySecret {
    fn kinds(&self, parent: SyncedSecretParentTag) -> Vec<String> {
        match parent {
            SyncedSecretParentTag::Connection => vec!["password".to_owned(), "ssl_key_passphrase".to_owned()],
            SyncedSecretParentTag::SshProfile | SyncedSecretParentTag::CredentialProfile => Vec::new(),
        }
    }

    fn load(&self, secret: SyncedSecretRef) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&(secret.parent_id, secret.kind)).cloned())
    }

    fn store(&self, secret: SyncedSecretRef, value: SecretString) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().insert((secret.parent_id, secret.kind), value);
        Ok(())
    }

    fn delete(&self, secret: SyncedSecretRef) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().remove(&(secret.parent_id, secret.kind));
        Ok(())
    }
}

// A connection's password the app names goes through the app, which keeps a pulled one on the device only, never
// through `HostSecrets`, whose items may follow the app's iCloud Keychain switch; one it leaves out still goes
// through this Core's own store.
#[tokio::test]
async fn a_connection_secret_the_app_names_goes_through_the_app_and_never_this_core_s_store() {
    use tablepro_records::Kind;
    use tablepro_records::envelope::SecretKind;
    use tablepro_sync::api::secrets::{DeviceSecrets, SecretRef};

    let tasks = runtime::tasks().unwrap();
    let server = server_now();
    let mac = Mac::open(
        &tasks,
        &server,
        AccountId(Uuid::new_v4()),
        "dev_01k8d6wpggfd68tbhz818p4ww4",
    )
    .await;
    let host = EverySecret::default();
    let secrets = CoreSecrets::new(
        mac.core.vault(),
        mac.core.connection_store().unwrap(),
        mac.core.writes(),
        Some(Arc::new(host.clone()) as Arc<dyn HostSyncedSecrets>),
        tasks.clone(),
    );
    let connection = Uuid::new_v4();
    let of = |secret| SecretRef {
        parent: Kind::Connection,
        parent_id: connection,
        secret,
    };

    secrets
        .store(&of(SecretKind::Password), &SecretString::from("pulled"))
        .await
        .unwrap();
    secrets
        .store(&of(SecretKind::SshPassword), &SecretString::from("tunnel"))
        .await
        .unwrap();

    assert_eq!(
        secrets.kinds(Kind::Connection),
        [
            SecretKind::Password,
            SecretKind::SslKeyPassphrase,
            SecretKind::SshPassword,
            SecretKind::SshKeyPassphrase
        ]
    );
    let held = host.0.lock().unwrap().clone();
    assert_eq!(
        held.get(&(tablepro_records::record_id::uuid_id(connection), "password".to_owned()))
            .map(|secret| secret.expose_secret().to_owned())
            .as_deref(),
        Some("pulled")
    );
    assert_eq!(mac.keychain.password(&connection.to_string()), None);
    assert_eq!(
        mac.keychain
            .0
            .lock()
            .unwrap()
            .get(&(connection.to_string(), SecretKindTag::SshPassword))
            .map(|secret| secret.expose_secret().to_owned())
            .as_deref(),
        Some("tunnel")
    );
}
