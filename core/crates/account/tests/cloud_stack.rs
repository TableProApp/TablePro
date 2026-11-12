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
    Account, AccountError, AccountSettings, AccountStatus, BrowserLauncher, CallbackPage, DeviceDescription,
    EntitlementKeys, EntitlementProblem, FeatureAccess, MachineId, RefreshTokenVault, SignedIn,
};
use tablepro_core::credentials::SecretError;
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

// Fails when the browser step does, not 10 minutes later when the sign-in times out.
async fn sign_in(account: &Account, browser: &Browser) -> Result<(), AccountError> {
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
