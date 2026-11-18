//! The account against a running tablepro-cloud: linux/docs/testing.md, tablepro-cloud stack.

#![expect(
    clippy::expect_used,
    clippy::panic,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::Utc;
use secrecy::{ExposeSecret, SecretString};
use tablepro_account::{
    Account, AccountError, AccountSettings, AccountStatus, BrowserLauncher, CallbackPage, CreatedShare,
    DeviceDescription, EntitlementKeys, EntitlementProblem, FeatureAccess, MachineId, RefreshTokenVault, Share,
    ShareExpiry, ShareKind, ShareRequest, SignedIn,
};
use tablepro_core::column::{ColumnType, ResultColumn};
use tablepro_core::credentials::SecretError;
use tablepro_core::export::{ResultExtent, build_snapshot};
use tablepro_core::value::Value;
use tokio::process::{Child, Command};
use url::Url;

const STARTER_FEATURE: &str = "env_var_references";
const TEAM_FEATURE: &str = "team_library";

struct Stack {
    account_url: String,
    api_url: String,
    entitlement_key: String,
    email_domain: String,
}

impl Stack {
    fn from_env() -> Self {
        let read =
            |name: &str| std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set; see linux/docs/testing.md"));
        Self {
            account_url: read("TABLEPRO_CLOUD_ACCOUNT_URL"),
            api_url: read("TABLEPRO_CLOUD_API_URL"),
            entitlement_key: read("TABLEPRO_CLOUD_ENTITLEMENT_KEY"),
            email_domain: read("TABLEPRO_CLOUD_EMAIL_DOMAIN"),
        }
    }
}

struct Machine {
    name: String,
    machine_id: MachineId,
    dir: tempfile::TempDir,
}

impl Machine {
    fn new(label: &str) -> Self {
        let machine_id = MachineId::derive(&format!("{}\n", random_hex(16))).expect("a machine ID");
        Self {
            name: format!("M17 {label} {}", random_hex(2)),
            machine_id,
            dir: tempfile::tempdir().expect("a temporary directory"),
        }
    }

    fn account_file(&self) -> std::path::PathBuf {
        self.dir.path().join("account.json")
    }

    fn account(&self, stack: &Stack, vault: Arc<dyn RefreshTokenVault>, browser: Arc<Browser>) -> Account {
        let settings = AccountSettings {
            client: tablepro_account::AppClient::LINUX,
            endpoints: tablepro_account::Endpoints::new(&stack.account_url, &stack.api_url).expect("the endpoints"),
            device: DeviceDescription {
                name: self.name.clone(),
                app_version: "0.1.0-test".to_owned(),
                os_version: "Ubuntu 26.04".to_owned(),
            },
            machine_id: self.machine_id.clone(),
            keys: EntitlementKeys::from_public_keys([stack.entitlement_key.as_str()]).expect("the stack's key"),
            account_file: self.account_file(),
            callback_page: CallbackPage {
                finished: "You can close this tab.".to_owned(),
                unknown: "This is not TablePro's sign-in.".to_owned(),
            },
        };
        let status = tokio::sync::watch::Sender::new(AccountStatus::SignedOut);
        Account::new(settings, vault, browser, status).expect("an account")
    }
}

// Started and left running, as a desktop hands the URL to a browser.
struct Browser {
    user: Arc<User>,
    machine_name: String,
    grant: bool,
    seed_devices: usize,
    running: Mutex<Option<Child>>,
}

// The profile keeps the portal session: the stack sends 5 sign-in emails an hour per address.
struct User {
    email: String,
    profile: tempfile::TempDir,
}

impl User {
    fn new(stack: &Stack, label: &str) -> Arc<Self> {
        Arc::new(Self {
            email: format!("linux-{label}-{}@{}", random_hex(4), stack.email_domain),
            profile: tempfile::tempdir().expect("a browser profile"),
        })
    }
}

impl Browser {
    fn new(user: &Arc<User>, machine: &Machine, grant: bool) -> Arc<Self> {
        Arc::new(Self {
            user: user.clone(),
            machine_name: machine.name.clone(),
            grant,
            seed_devices: 0,
            running: Mutex::new(None),
        })
    }

    // The account holds the license on `count` other devices before this one asks.
    fn over_the_limit(user: &Arc<User>, machine: &Machine, count: usize) -> Arc<Self> {
        Arc::new(Self {
            user: user.clone(),
            machine_name: machine.name.clone(),
            grant: true,
            seed_devices: count,
            running: Mutex::new(None),
        })
    }

    fn exited(&self) -> Option<std::process::ExitStatus> {
        let mut running = self.running.lock().expect("the browser slot");
        running.as_mut()?.try_wait().expect("the browser's state")
    }

    fn portal(&self, step: &str) -> Command {
        let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/browser/portal.cjs");
        let mut command = Command::new("node");
        command
            .arg(script)
            .arg(step)
            .env("TABLEPRO_CLOUD_EMAIL", &self.user.email)
            .env("TABLEPRO_CLOUD_PROFILE", self.user.profile.path())
            .env("TABLEPRO_CLOUD_MACHINE_NAME", &self.machine_name)
            .env("TABLEPRO_CLOUD_GRANT", if self.grant { "starter" } else { "" })
            .env("TABLEPRO_CLOUD_SEED_DEVICES", self.seed_devices.to_string())
            .kill_on_drop(true);
        command
    }

    // The portal makes the file the way its Devices page does, for a machine that never signs in.
    async fn offline_file(&self, machine: &Machine) -> String {
        let output = machine.dir.path().join("tablepro-offline.jwt");
        let status = self
            .portal("offline-file")
            .env("TABLEPRO_CLOUD_MACHINE_ID", machine.machine_id.as_str())
            .env("TABLEPRO_CLOUD_MACHINE_NAME", &machine.name)
            .env("TABLEPRO_CLOUD_OUTPUT", &output)
            .status()
            .await
            .expect("the browser ran");
        assert!(status.success(), "the portal made no offline file: {status}");
        std::fs::read_to_string(output).expect("the offline file")
    }

    async fn remove_device(&self) {
        let status = self.portal("remove-device").status().await.expect("the browser ran");
        assert!(status.success(), "the device was not removed in the portal: {status}");
    }

    async fn finished(&self) {
        let child = self.running.lock().expect("the browser slot").take();
        let status = child
            .expect("the browser ran")
            .wait()
            .await
            .expect("the browser's exit");
        assert!(status.success(), "the browser step failed: {status}");
    }
}

#[async_trait]
impl BrowserLauncher for Browser {
    async fn open(&self, url: &Url) -> Result<(), String> {
        let child = self
            .portal("approve")
            .arg(url.as_str())
            .spawn()
            .map_err(|error| error.to_string())?;
        *self.running.lock().map_err(|error| error.to_string())? = Some(child);
        Ok(())
    }
}

// Lets a test read the token the account holds.
#[derive(Default)]
struct MemoryKeyring(Mutex<Option<SecretString>>);

#[async_trait]
impl RefreshTokenVault for MemoryKeyring {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        Ok(self.0.lock().expect("the keyring").clone())
    }

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
        *self.0.lock().expect("the keyring") = Some(token.clone());
        Ok(())
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        *self.0.lock().expect("the keyring") = None;
        Ok(())
    }
}

#[derive(Default)]
struct CountingKeyring {
    held: MemoryKeyring,
    opened: std::sync::atomic::AtomicUsize,
}

#[async_trait]
impl RefreshTokenVault for CountingKeyring {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        self.opened.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.held.load_refresh_token().await
    }

    async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
        self.opened.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.held.store_refresh_token(token).await
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        self.opened.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        self.held.delete_refresh_token().await
    }
}

struct NoKeyring;

#[async_trait]
impl RefreshTokenVault for NoKeyring {
    async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
        Err(unavailable())
    }

    async fn store_refresh_token(&self, _: &SecretString) -> Result<(), SecretError> {
        Err(unavailable())
    }

    async fn delete_refresh_token(&self) -> Result<(), SecretError> {
        Err(unavailable())
    }
}

fn unavailable() -> SecretError {
    SecretError::ServiceUnavailable {
        detail: "org.freedesktop.secrets was not provided by any .service files".to_owned(),
    }
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    getrandom::fill(&mut buffer).expect("random bytes");
    buffer.iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn stored_token(keyring: &MemoryKeyring) -> SecretString {
    keyring
        .load_refresh_token()
        .await
        .expect("the keyring")
        .expect("a token")
}

// The token endpoint's answer to a refresh with `token`, outside the account.
async fn refresh_answer(stack: &Stack, token: &SecretString) -> String {
    let answer = reqwest::Client::new()
        .post(format!("{}/oauth/token", stack.account_url))
        .form(&[
            ("grant_type", "refresh_token"),
            ("client_id", tablepro_account::AppClient::LINUX.client_id),
            ("refresh_token", token.expose_secret()),
        ])
        .send()
        .await
        .expect("an answer");
    answer.text().await.expect("the body")
}

fn signed_in(account: &Account) -> SignedIn {
    match &*account.status().borrow() {
        AccountStatus::SignedIn(signed_in) => (**signed_in).clone(),
        other => panic!("the account is not signed in: {other:?}"),
    }
}

// The stack takes 30 token requests a minute per client, which the whole suite passes; a sign-in it refuses for that
// waits out the Retry-After and starts again.
async fn sign_in(account: &Account, browser: &Browser) -> Result<(), AccountError> {
    loop {
        match sign_in_once(account, browser).await {
            Err(AccountError::RateLimited { retry_after }) => {
                tokio::time::sleep(retry_after.unwrap_or(std::time::Duration::from_secs(60))).await;
            }
            answered => return answered,
        }
    }
}

// Fails when the browser step does, not 10 minutes later when the sign-in times out.
async fn sign_in_once(account: &Account, browser: &Browser) -> Result<(), AccountError> {
    let signing_in = account.sign_in(std::future::pending());
    tokio::pin!(signing_in);
    loop {
        tokio::select! {
            result = &mut signing_in => {
                browser.finished().await;
                return result;
            }
            () = tokio::time::sleep(std::time::Duration::from_millis(250)) => {
                if let Some(status) = browser.exited().filter(|status| !status.success()) {
                    panic!("the browser step failed: {status}");
                }
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_licensed_machine_signs_in_keeps_its_entitlement_across_a_restart_and_signs_out() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "starter");
    let machine = Machine::new("Linux");
    let keyring = Arc::new(MemoryKeyring::default());
    let browser = Browser::new(&user, &machine, true);
    let account = machine.account(&stack, keyring.clone(), browser.clone());

    account.restore().await;
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    sign_in(&account, &browser).await.expect("signed in");

    let first = signed_in(&account);
    let entitlement = first.entitlement.clone().expect("an entitlement");
    assert!(first.remembered);
    assert!(first.problem.is_none(), "{:?}", first.problem);
    assert_eq!(entitlement.claims().mid, machine.machine_id.as_str());
    assert_eq!(entitlement.claims().account.email, user.email);
    assert!(entitlement.claims().dev.starts_with("dev_"));
    let status = account.status().borrow().clone();
    assert_eq!(
        status.feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::Available
    );
    assert_eq!(
        status.feature_access(TEAM_FEATURE, Utc::now()),
        FeatureAccess::NotIncluded
    );
    let kept = std::fs::read_to_string(machine.account_file()).expect("the account file");
    assert!(kept.contains(&entitlement.claims().dev) && kept.contains(entitlement.token()));

    let restarted = machine.account(&stack, keyring.clone(), Browser::new(&user, &machine, false));
    restarted.restore().await;
    assert_eq!(signed_in(&restarted).entitlement.as_ref(), Some(&entitlement));
    restarted.refresh_entitlement().await.expect("a refreshed entitlement");
    let refreshed = signed_in(&restarted).entitlement.expect("an entitlement");
    assert_ne!(refreshed.claims().jti, entitlement.claims().jti);
    assert_eq!(refreshed.claims().dev, entitlement.claims().dev);

    let token = stored_token(&keyring).await;
    restarted.sign_out().await.expect("signed out and revoked");
    assert!(matches!(*restarted.status().borrow(), AccountStatus::SignedOut));
    assert!(keyring.load_refresh_token().await.expect("the keyring").is_none());
    assert!(!machine.account_file().exists());
    let answer = refresh_answer(&stack, &token).await;
    assert!(answer.contains("invalid_grant"), "{answer}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_second_sign_in_revokes_the_first_one() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "again");
    let machine = Machine::new("Linux");
    let keyring = Arc::new(MemoryKeyring::default());
    let browser = Browser::new(&user, &machine, false);
    let account = machine.account(&stack, keyring.clone(), browser.clone());
    sign_in(&account, &browser).await.expect("signed in");
    let first = stored_token(&keyring).await;

    sign_in(&account, &browser).await.expect("signed in again");

    let second = stored_token(&keyring).await;
    assert_ne!(first.expose_secret(), second.expose_secret());
    let answer = refresh_answer(&stack, &first).await;
    assert!(answer.contains("invalid_grant"), "{answer}");
    account
        .refresh_entitlement()
        .await
        .expect("a refresh on the second sign-in");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_device_removed_in_the_portal_signs_the_account_out_at_its_next_refresh() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "removed");
    let machine = Machine::new("Linux");
    let keyring = Arc::new(MemoryKeyring::default());
    let browser = Browser::new(&user, &machine, true);
    let account = machine.account(&stack, keyring.clone(), browser.clone());
    sign_in(&account, &browser).await.expect("signed in");
    assert!(machine.account_file().exists());

    browser.remove_device().await;
    let refreshed = account.refresh_entitlement().await;

    assert!(matches!(refreshed, Err(AccountError::DeviceRevoked)), "{refreshed:?}");
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    assert!(keyring.load_refresh_token().await.expect("the keyring").is_none());
    assert!(!machine.account_file().exists());
    let again = account.refresh_entitlement().await;
    assert!(matches!(again, Err(AccountError::SignedOut)), "{again:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn without_a_keyring_a_free_account_signs_in_until_the_app_quits() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "free");
    let machine = Machine::new("Linux");
    let browser = Browser::new(&user, &machine, false);
    let account = machine.account(&stack, Arc::new(NoKeyring), browser.clone());

    sign_in(&account, &browser).await.expect("signed in");

    let held = signed_in(&account);
    assert!(!held.remembered);
    let entitlement = held.entitlement.expect("an entitlement");
    assert!(
        entitlement.claims().features.is_empty(),
        "{:?}",
        entitlement.claims().features
    );
    let status = account.status().borrow().clone();
    assert_eq!(
        status.feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::NotIncluded
    );
    account
        .refresh_entitlement()
        .await
        .expect("a refresh with the token held in memory");

    let next_launch = machine.account(&stack, Arc::new(NoKeyring), Browser::new(&user, &machine, false));
    next_launch.restore().await;
    assert!(matches!(*next_launch.status().borrow(), AccountStatus::SignedOut));
    assert_eq!(
        next_launch
            .status()
            .borrow()
            .feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::SignedOut
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_fourth_machine_is_told_the_device_limit_with_the_three_that_hold_the_license() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "limit");
    let mut holders = Vec::new();
    for (index, label) in ["One", "Two", "Three"].into_iter().enumerate() {
        let machine = Machine::new(label);
        let browser = Browser::new(&user, &machine, index == 0);
        let account = machine.account(&stack, Arc::new(MemoryKeyring::default()), browser.clone());
        sign_in(&account, &browser).await.expect("signed in");
        assert!(signed_in(&account).entitlement.is_some());
        holders.push(machine.name.clone());
    }
    let fourth = Machine::new("Four");
    let browser = Browser::new(&user, &fourth, false);
    let account = fourth.account(&stack, Arc::new(MemoryKeyring::default()), browser.clone());

    let refused = sign_in(&account, &browser).await;

    let Err(AccountError::DeviceLimitReached { devices }) = refused else {
        panic!("not the device limit: {refused:?}");
    };
    let names: Vec<String> = devices.into_iter().map(|device| device.name).collect();
    assert_eq!(names, holders);
    let held = signed_in(&account);
    assert!(held.entitlement.is_none());
    assert!(matches!(held.problem, Some(EntitlementProblem::DeviceLimitReached(ref listed)) if listed.len() == 3));
    assert_eq!(
        account.status().borrow().feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::DeviceLimitReached
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn the_profile_and_devices_name_the_account_and_an_offline_file_unlocks_a_machine_that_never_signed_in() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "profile");
    let machine = Machine::new("Linux");
    let browser = Browser::new(&user, &machine, true);
    let account = machine.account(&stack, Arc::new(MemoryKeyring::default()), browser.clone());
    sign_in(&account, &browser).await.expect("signed in");

    let profile = account.profile().await.expect("the profile");
    let devices = account.devices().await.expect("the devices");

    assert_eq!(profile.email, user.email);
    assert!(profile.id.starts_with("acct_"), "{}", profile.id);
    assert_eq!(profile.licenses.len(), 1);
    assert_eq!(
        (profile.licenses[0].plan.as_str(), profile.licenses[0].status.as_str()),
        ("starter", "active")
    );
    assert!(profile.teams.is_empty());
    assert_eq!(
        signed_in(&account).entitlement.map(|it| it.claims().sub.clone()),
        Some(profile.id)
    );
    let here = devices
        .iter()
        .find(|device| device.machine_id == machine.machine_id.as_str())
        .expect("this machine among the devices");
    assert_eq!(here.name, machine.name);
    assert_eq!(here.platform, "linux");
    assert!(here.licensed_at.is_some());

    let offline = Machine::new("Offline");
    let token = browser.offline_file(&offline).await;
    let keyring = Arc::new(CountingKeyring::default());
    let never_online = offline.account(&stack, keyring.clone(), Browser::new(&user, &offline, false));
    never_online.restore().await;
    never_online.import_offline_file(&token).await.expect("imported");

    let AccountStatus::Offline(entitlement) = never_online.status().borrow().clone() else {
        panic!("not on the offline file");
    };
    assert!(entitlement.claims().offline);
    assert_eq!(entitlement.claims().mid, offline.machine_id.as_str());
    assert_eq!(
        never_online
            .status()
            .borrow()
            .feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::Available
    );
    let restarted = offline.account(&stack, keyring.clone(), Browser::new(&user, &offline, false));
    restarted.restore().await;
    assert!(matches!(*restarted.status().borrow(), AccountStatus::Offline(_)));
    assert_eq!(keyring.opened.load(std::sync::atomic::Ordering::SeqCst), 0);
    let elsewhere = machine.account(
        &stack,
        Arc::new(MemoryKeyring::default()),
        Browser::new(&user, &machine, false),
    );
    let refused = elsewhere.import_offline_file(&token).await;
    assert!(
        matches!(
            refused,
            Err(AccountError::Entitlement(tablepro_account::EntitlementError::Machine))
        ),
        "{refused:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn over_the_device_limit_a_removal_moves_the_license_here_and_an_offline_device_stays() {
    let stack = Stack::from_env();
    let user = User::new(&stack, "limit");
    let machine = Machine::new("Linux");
    let browser = Browser::over_the_limit(&user, &machine, 3);
    let account = machine.account(&stack, Arc::new(MemoryKeyring::default()), browser.clone());

    let signed = sign_in(&account, &browser).await;

    let Err(AccountError::DeviceLimitReached { devices: holding }) = signed else {
        panic!("not over the limit: {signed:?}");
    };
    assert_eq!(holding.len(), 3);
    let held = signed_in(&account);
    assert!(held.entitlement.is_none());
    assert!(matches!(held.problem, Some(EntitlementProblem::DeviceLimitReached(_))));
    let kept = holding
        .iter()
        .find(|device| device.offline_file_active(Utc::now()))
        .expect("device_limit_reached names the device with an offline file and its offline_until");

    let refused = account.remove_device(&kept.id).await;
    let other = holding
        .iter()
        .find(|device| device.id != kept.id)
        .expect("another holder");
    let removed = account.remove_device(&other.id).await;

    assert!(
        matches!(&refused, Err(AccountError::Refused { status: 409, code, .. }) if code == "offline_file_active"),
        "{refused:?}"
    );
    removed.expect("removed, and the license moved here");
    let moved = signed_in(&account);
    assert!(moved.problem.is_none(), "{:?}", moved.problem);
    assert_eq!(
        account.status().borrow().feature_access(STARTER_FEATURE, Utc::now()),
        FeatureAccess::Available
    );
    let after = account.devices().await.expect("the devices");
    assert!(after.iter().all(|device| device.id != other.id));
}

const SHARED_SQL: &str = "SELECT id, label FROM orders";
const PASSWORD: &str = "correct horse";
// Well formed, and no link or team of the stack's.
const UNKNOWN_TOKEN: &str = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";
const UNKNOWN_TEAM: &str = "team_01h2xcejqtf2nbrexx3vqjhp41";

async fn signed_in_as(stack: &Stack, label: &str, licensed: bool) -> (Arc<User>, Machine, Account) {
    let user = User::new(stack, label);
    let machine = Machine::new("Linux");
    let browser = Browser::new(&user, &machine, licensed);
    let account = machine.account(stack, Arc::new(MemoryKeyring::default()), browser.clone());
    sign_in(&account, &browser).await.expect("signed in");
    (user, machine, account)
}

async fn seed(user: &User, step: &str, member: Option<&User>) {
    let script = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/browser/seed.cjs");
    let mut command = Command::new("node");
    command
        .arg(script)
        .arg(step)
        .env("TABLEPRO_CLOUD_EMAIL", &user.email)
        .kill_on_drop(true);
    if let Some(member) = member {
        command.env("TABLEPRO_CLOUD_MEMBER_EMAIL", &member.email);
    }
    let status = command.status().await.expect("node ran");
    assert!(status.success(), "the {step} seed failed: {status}");
}

fn refusal<T: std::fmt::Debug>(answer: Result<T, AccountError>) -> (u16, String) {
    match answer {
        Err(AccountError::Refused { status, code, .. }) => (status, code),
        other => panic!("not refused: {other:?}"),
    }
}

fn refused(status: u16, code: &str) -> (u16, String) {
    (status, code.to_owned())
}

fn token_of(created: &CreatedShare) -> String {
    let token = created.url.rsplit('/').next().unwrap_or_default().to_owned();
    assert!(tablepro_account::is_share_token(&token), "{}", created.url);
    token
}

fn query_share(title: &str) -> ShareRequest {
    ShareRequest {
        kind: ShareKind::Query,
        sql: SHARED_SQL.to_owned(),
        title: Some(title.to_owned()),
        note: None,
        dialect: Some("postgres".to_owned()),
        expiry: None,
        hide_sql: false,
        allow_download: None,
        password: None,
        team_id: None,
        snapshot: None,
    }
}

// `rows` numbered rows of a result of `row_count`, of which the client keeps `kept`.
fn result_share(title: &str, rows: usize, row_count: u64, kept: usize) -> ShareRequest {
    let columns = [
        ResultColumn::new("id", ColumnType::untyped_text("bigint")),
        ResultColumn::new("label", ColumnType::untyped_text("text")),
    ];
    let rows: Vec<Vec<Value>> = (0..rows)
        .map(|row| {
            vec![
                Value::Int(i64::try_from(row).expect("a small row number")),
                Value::Text(format!("row {row}")),
            ]
        })
        .collect();
    ShareRequest {
        kind: ShareKind::Result,
        snapshot: Some(build_snapshot(&columns, &rows, ResultExtent::complete(row_count), kept).expect("a snapshot")),
        ..query_share(title)
    }
}

fn assert_expires_in(share: &Share, days: i64) {
    let expires_at = share.expires_at.expect("an expiry");
    let wanted = Utc::now() + chrono::TimeDelta::days(days);
    assert!(
        (expires_at - wanted).num_seconds().abs() < 300,
        "{expires_at} is not {days} days from now"
    );
}

// The public read as the viewer page makes it, for what the account does not keep: the rows and the headers.
async fn public_read(
    stack: &Stack,
    token: &str,
    password: Option<&str>,
) -> (u16, reqwest::header::HeaderMap, serde_json::Value) {
    let mut request = reqwest::Client::new().get(format!("{}/shared/{token}", stack.api_url));
    if let Some(password) = password {
        request = request.header("X-Share-Password", password);
    }
    let answer = request.send().await.expect("an answer");
    let status = answer.status().as_u16();
    let headers = answer.headers().clone();
    let body = answer.text().await.expect("the body");
    (status, headers, serde_json::from_str(&body).expect("a JSON body"))
}

fn rows(body: &serde_json::Value) -> &[serde_json::Value] {
    body["snapshot"]["rows"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or_default()
}

fn assert_public_headers(headers: &reqwest::header::HeaderMap) {
    for (name, value) in [
        ("x-robots-tag", "noindex, nofollow, noarchive"),
        ("cache-control", "no-store"),
        ("referrer-policy", "no-referrer"),
    ] {
        assert_eq!(headers.get(name).and_then(|it| it.to_str().ok()), Some(value), "{name}");
    }
}

// A Turnstile token the stack's siteverify passes for the share_report action.
fn report_token() -> String {
    std::env::var("TABLEPRO_CLOUD_REPORT_TOKEN").expect("TABLEPRO_CLOUD_REPORT_TOKEN is not set")
}

async fn report(stack: &Stack, token: &str, turnstile_token: Option<&str>) -> (u16, String) {
    let body = match turnstile_token {
        Some(turnstile_token) => format!(
            r#"{{"reason":"spam","turnstile_token":{}}}"#,
            serde_json::to_string(turnstile_token).expect("a JSON string")
        ),
        None => r#"{"reason":"spam"}"#.to_owned(),
    };
    let answer = reqwest::Client::new()
        .post(format!("{}/shared/{token}/report", stack.api_url))
        .header("Content-Type", "application/json")
        .body(body)
        .send()
        .await
        .expect("an answer");
    let status = answer.status().as_u16();
    (status, answer.text().await.expect("the body").trim_end().to_owned())
}

fn pro_only_requests() -> [(&'static str, ShareRequest); 4] {
    [
        (
            "password",
            ShareRequest {
                password: Some(SecretString::from(PASSWORD)),
                ..query_share("Locked")
            },
        ),
        (
            "never",
            ShareRequest {
                expiry: Some(ShareExpiry::Never),
                ..query_share("Forever")
            },
        ),
        (
            "no download",
            ShareRequest {
                allow_download: Some(false),
                ..result_share("Kept", 1, 1, 1)
            },
        ),
        (
            "team",
            ShareRequest {
                team_id: Some(UNKNOWN_TEAM.to_owned()),
                ..query_share("Team")
            },
        ),
    ]
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_free_account_holds_five_links_and_is_refused_a_sixth_and_every_pro_option() {
    let stack = Stack::from_env();
    let (_user, _machine, account) = signed_in_as(&stack, "share-free", false).await;

    let limits = account.share_limits().await.expect("the limits");
    assert_eq!(limits.plan, "free");
    assert_eq!((limits.live, limits.live_limit, limits.max_rows), (0, 5, 1_000));
    assert_eq!(
        limits.expiries,
        [ShareExpiry::OneDay, ShareExpiry::SevenDays, ShareExpiry::ThirtyDays]
    );
    assert_eq!(limits.default_expiry, Some(ShareExpiry::ThirtyDays));
    assert!(!limits.password && !limits.disable_download && !limits.team);
    assert!(limits.email_verified && !limits.sharing_disabled);
    for (option, request) in pro_only_requests() {
        let answer = account.create_share(request).await;
        assert_eq!(refusal(answer), refused(403, "pro_required"), "{option}");
    }

    let mut created = Vec::new();
    for (expiry, days) in [
        (None, 30),
        (Some(ShareExpiry::OneDay), 1),
        (Some(ShareExpiry::SevenDays), 7),
        (Some(ShareExpiry::ThirtyDays), 30),
    ] {
        let share = account
            .create_share(ShareRequest {
                expiry,
                ..query_share("Orders")
            })
            .await
            .expect("created");
        assert_expires_in(&share.share, days);
        assert_eq!(
            (share.share.scope.as_str(), share.share.state.as_str()),
            ("account", "live")
        );
        created.push(share);
    }
    // A client that kept too many rows: the server keeps the plan's 1,000 and the true count.
    let cut = account
        .create_share(result_share("Big", 1_001, 48_210, 1_001))
        .await
        .expect("created");
    assert_eq!((cut.share.row_count, cut.share.truncated), (Some(48_210), Some(true)));
    let opened = account.fetch_shared(&token_of(&cut), None).await.expect("the link");
    assert_eq!((opened.row_count, opened.truncated), (Some(48_210), Some(true)));
    let (status, _, body) = public_read(&stack, &token_of(&cut), None).await;
    assert_eq!((status, rows(&body).len()), (200, 1_000));

    let sixth = account.create_share(query_share("Sixth")).await;
    assert_eq!(refusal(sixth), refused(409, "share_limit_reached"));
    let listed = account.list_shares(true, None, None).await.expect("the list");
    assert_eq!(listed.shares.len(), 5);
    assert!(
        listed
            .shares
            .iter()
            .all(|share| share.url.is_some() && share.sql.is_none()),
        "{listed:?}"
    );
    extend_revoke_and_share_again(&stack, &account, &created).await;
}

// The 1-day link is extended to 30 days; the 7-day one is revoked, which frees a slot for a result without its SQL.
async fn extend_revoke_and_share_again(stack: &Stack, account: &Account, created: &[CreatedShare]) {
    let extended = account
        .extend_share(&created[1].share.id, ShareExpiry::ThirtyDays)
        .await
        .expect("extended");
    assert_expires_in(&extended, 30);
    assert!(extended.is_live());

    let revoked = &created[2];
    account.revoke_share(&revoked.share.id).await.expect("revoked");
    let gone = account.fetch_shared(&token_of(revoked), None).await;
    assert_eq!(refusal(gone), refused(404, "not_found"));
    let again = account.extend_share(&revoked.share.id, ShareExpiry::ThirtyDays).await;
    assert_eq!(refusal(again), refused(409, "share_revoked"));
    assert_eq!(account.share_limits().await.expect("the limits").live, 4);

    let hidden = account
        .create_share(ShareRequest {
            hide_sql: true,
            ..result_share("Hidden", 3, 3, 1_000)
        })
        .await
        .expect("created in the freed slot");
    assert!(hidden.share.hide_sql);
    let opened = account.fetch_shared(&token_of(&hidden), None).await.expect("the link");
    assert_eq!(opened.sql, None);
    assert_eq!((opened.row_count, opened.truncated), (Some(3), Some(false)));
    let (status, _, body) = public_read(stack, &token_of(&hidden), None).await;
    assert_eq!(status, 200);
    assert!(body.get("sql").is_none(), "{body}");
    assert_eq!(rows(&body).len(), 3);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn an_account_whose_email_is_not_verified_is_told_so_and_shares_nothing() {
    let stack = Stack::from_env();
    let (user, _machine, account) = signed_in_as(&stack, "share-unverified", false).await;
    seed(&user, "unverify", None).await;

    let limits = account.share_limits().await.expect("the limits");
    let refusal = refusal(account.create_share(query_share("Orders")).await);

    assert!(!limits.email_verified);
    assert_eq!(refusal, refused(403, "email_unverified"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_pro_link_behind_a_password_opens_with_it_keeps_every_digit_and_takes_a_report() {
    let stack = Stack::from_env();
    let (_user, _machine, account) = signed_in_as(&stack, "share-pro", true).await;
    let limits = account.share_limits().await.expect("the limits");
    assert_eq!(limits.plan, "pro");
    assert_eq!((limits.live_limit, limits.max_rows), (1_000, 10_000));
    assert_eq!(limits.expiries, ShareExpiry::ALL);
    assert_eq!(limits.default_expiry, Some(ShareExpiry::Never));
    assert!(limits.password && limits.disable_download && limits.team);

    let columns = [
        ResultColumn::new("id", ColumnType::untyped_text("bigint")),
        ResultColumn::new("label", ColumnType::untyped_text("text")),
    ];
    let rows_shared = [
        vec![Value::Int(9_007_199_254_740_993), Value::Text("past 2^53".to_owned())],
        vec![Value::Int(42), Value::Text("small".to_owned())],
    ];
    let max_rows = usize::try_from(limits.max_rows).expect("a row count");
    let created = account
        .create_share(ShareRequest {
            kind: ShareKind::Result,
            password: Some(SecretString::from(PASSWORD)),
            allow_download: Some(false),
            snapshot: Some(
                build_snapshot(&columns, &rows_shared, ResultExtent::complete(2), max_rows).expect("a snapshot"),
            ),
            ..query_share("Ledger")
        })
        .await
        .expect("created");
    assert!(created.share.has_password && !created.share.allow_download);
    assert_eq!(created.share.expires_at, None);
    assert_eq!(
        (created.share.row_count, created.share.truncated),
        (Some(2), Some(false))
    );
    let token = token_of(&created);
    assert_password_gate(&stack, &account, &token).await;

    let (status, headers, body) = public_read(&stack, &token, Some(PASSWORD)).await;
    assert_eq!(status, 200);
    assert_public_headers(&headers);
    assert_eq!(rows(&body)[0][0], serde_json::json!("9007199254740993"));
    assert_eq!(rows(&body)[1][0], serde_json::json!(42));
    assert_eq!(body["made_with"], "TablePro");

    assert_eq!(
        report(&stack, &token, Some(&report_token())).await,
        (202, "{}".to_owned())
    );
    assert_eq!(
        report(&stack, UNKNOWN_TOKEN, Some(&report_token())).await,
        (202, "{}".to_owned())
    );
    let (status, problem) = report(&stack, &token, None).await;
    assert!(
        status == 403 && problem.contains("human_check_failed"),
        "{status} {problem}"
    );
    assert_password_guesses_run_out(&account, &token).await;

    account.revoke_share(&created.share.id).await.expect("revoked");
    let gone = account.fetch_shared(&token, None).await;
    assert_eq!(refusal(gone), refused(404, "not_found"));
    let (status, headers, _) = public_read(&stack, &token, None).await;
    assert_eq!(status, 404);
    assert_public_headers(&headers);
}

async fn assert_password_gate(stack: &Stack, account: &Account, token: &str) {
    let required = account.fetch_shared(token, None).await;
    let wrong = account
        .fetch_shared(token, Some(&SecretString::from("battery staple")))
        .await;
    let opened = account
        .fetch_shared(token, Some(&SecretString::from(PASSWORD)))
        .await
        .expect("opened with its password");
    assert_eq!(refusal(required), refused(401, "share_password_required"));
    assert_eq!(refusal(wrong), refused(401, "share_password_wrong"));
    assert_eq!(opened.sql.as_deref(), Some(SHARED_SQL));
    assert!(!opened.allow_download);
    assert_eq!(
        (opened.row_count, opened.truncated, opened.expires_at),
        (Some(2), Some(false), None)
    );
    let (status, headers, problem) = public_read(stack, token, None).await;
    assert_eq!(
        (status, problem["code"].as_str()),
        (401, Some("share_password_required"))
    );
    assert_public_headers(&headers);
}

// 10 guesses per link and client in 15 minutes; the ones before count too.
async fn assert_password_guesses_run_out(account: &Account, token: &str) {
    let guess = SecretString::from("battery staple");
    for _ in 0..10 {
        match account.fetch_shared(token, Some(&guess)).await {
            Err(AccountError::RateLimited { retry_after }) => {
                assert!(retry_after.is_some_and(|wait| wait.as_secs() > 0), "{retry_after:?}");
                return;
            }
            other => assert_eq!(refusal(other), refused(401, "share_password_wrong")),
        }
    }
    panic!("10 more wrong guesses were never limited");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires a tablepro-cloud stack"]
async fn a_seated_member_shares_a_team_link_outside_its_own_limit_until_the_team_turns_public_links_off() {
    let stack = Stack::from_env();
    let (owner, _owner_machine, _owner_account) = signed_in_as(&stack, "share-owner", false).await;
    let (member, _member_machine, account) = signed_in_as(&stack, "share-member", false).await;
    seed(&owner, "team", Some(&member)).await;

    let limits = account.share_limits().await.expect("the limits");
    assert_eq!((limits.plan.as_str(), limits.team), ("pro", true));
    let profile = account.profile().await.expect("the profile");
    let team = profile.teams.first().expect("the team").team.id.clone();
    let created = account
        .create_share(ShareRequest {
            team_id: Some(team.clone()),
            ..query_share("Team orders")
        })
        .await
        .expect("created");
    assert_eq!(created.share.scope, "team");
    assert_eq!(created.share.team_id.as_deref(), Some(team.as_str()));
    let personal = account.list_shares(false, None, None).await.expect("the list");
    assert!(personal.shares.is_empty(), "{personal:?}");
    assert_eq!(account.share_limits().await.expect("the limits").live, 0);
    let token = token_of(&created);
    account.fetch_shared(&token, None).await.expect("the team link");

    seed(&owner, "team-links-off", None).await;
    let another = account
        .create_share(ShareRequest {
            team_id: Some(team),
            ..query_share("Another")
        })
        .await;
    assert_eq!(refusal(another), refused(403, "team_sharing_disabled"));
    let suspended = account.fetch_shared(&token, None).await;
    assert_eq!(refusal(suspended), refused(404, "not_found"));
}
