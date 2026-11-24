use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use async_trait::async_trait;
use chrono::{TimeDelta, Utc};
use secrecy::{ExposeSecret as _, SecretString};
use tokio::sync::{Semaphore, watch};
use url::Url;

use super::company_tests::{Items, LICENSED, company, managed, settings};
use super::tests::{
    ACCOUNT, Asked, Keyring, TOKENS, asked, cloud_with_bodies, device_answer, form, keep, machine, signed_in, stored,
    stub_settings,
};
use super::{Account, AccountHosts, SignOutCause};
use crate::account_error::AccountError;
use crate::account_file::{self, AccountFile};
use crate::account_settings::{AccountSettings, AppClient, Endpoints, SignInKey};
use crate::account_status::{AccountStatus, EntitlementProblem};
use crate::browser::{WebAuthenticationError, WebAuthenticator};
use crate::fakes;
use crate::server::ServerError;

const DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4ww4";

// The URL the platform's session comes back with, from the page it opened.
type Answer = fn(&Url) -> Result<Url, WebAuthenticationError>;

// Stands in for ASWebAuthenticationSession: keeps what it was asked and answers with the server's redirect, once the
// test lets it when it holds a gate.
struct Authenticator {
    asked: StdMutex<Vec<(Url, String)>>,
    answer: Answer,
    gate: Option<Arc<Semaphore>>,
}

impl Authenticator {
    fn answering(answer: Answer) -> Arc<Self> {
        Arc::new(Self {
            asked: StdMutex::default(),
            answer,
            gate: None,
        })
    }

    fn asked(&self) -> Vec<(Url, String)> {
        self.asked.lock().expect("the requests").clone()
    }
}

#[async_trait]
impl WebAuthenticator for Authenticator {
    async fn authenticate(&self, url: &Url, callback_scheme: &str) -> Result<Url, WebAuthenticationError> {
        self.asked
            .lock()
            .expect("the requests")
            .push((url.clone(), callback_scheme.to_owned()));
        if let Some(gate) = &self.gate {
            let _ = gate.acquire().await;
        }
        (self.answer)(url)
    }
}

fn query(url: &Url, name: &str) -> Option<String> {
    url.query_pairs()
        .find(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
}

// What the server redirects to once the person approves: the code and the request's own state.
fn approved(url: &Url) -> Result<Url, WebAuthenticationError> {
    let state = query(url, "state").unwrap_or_default();
    Url::parse(&format!("app.tablepro:/oauth/callback?code=mac-code&state={state}"))
        .map_err(|error| WebAuthenticationError::Failed(error.to_string()))
}

fn mac(dir: &Path, endpoints: Endpoints, keyring: Arc<Keyring>, authenticator: Option<Arc<Authenticator>>) -> Account {
    let settings = AccountSettings {
        client: AppClient::MACOS,
        legacy_entitlement_file: Some(dir.join("Account").join("entitlement.jwt")),
        ..stub_settings(dir, endpoints)
    };
    let hosts = AccountHosts {
        vaults: Arc::new(crate::token_vault::SingleVault(keyring)),
        browser: Arc::new(super::tests::NoBrowser),
        web_authenticator: authenticator.map(|it| it as Arc<dyn WebAuthenticator>),
    };
    Account::open(settings, hosts, watch::Sender::new(AccountStatus::SignedOut)).expect("an account")
}

fn entitlement_answer(mid: &str) -> String {
    let mut claims = fakes::claims(Utc::now(), TimeDelta::days(14), &["team_library"]);
    claims.mid = mid.to_owned();
    format!(
        r#"{{"token":"{}","expires_at":"2026-12-01T00:00:00Z","refresh_after":"2026-11-20T00:00:00Z"}}"#,
        fakes::sign(&claims).expect("a token")
    )
}

// tablepro.app as the Mac reaches it, keeping each request's method, path and form.
fn production_stub(requests: Asked) -> Endpoints {
    cloud_with_bodies(move |method, path, body| {
        requests
            .lock()
            .expect("the requests")
            .push(format!("{method} {path} {body}"));
        match (method, path) {
            ("POST", "/oauth/token") if form(body).get("subject_token").is_some_and(|key| key == "refused") => (
                400,
                "",
                r#"{"error":"invalid_grant","error_description":"License key not found."}"#.to_owned(),
            ),
            ("POST", "/oauth/token") => (200, "", TOKENS.to_owned()),
            ("POST", "/oauth/revoke") => (200, "", String::new()),
            ("POST", "/v2/devices") => (200, "", device_answer()),
            ("POST", p) if p == format!("/v2/devices/{DEVICE}/entitlement") => {
                (200, "", entitlement_answer(machine().as_str()))
            }
            _ => (404, "", String::new()),
        }
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_mac_signs_in_through_its_web_authenticator_as_its_own_client() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    let authenticator = Authenticator::answering(approved);
    let keyring = Keyring::holding(None);
    let account = mac(
        dir.path(),
        production_stub(requests.clone()),
        keyring.clone(),
        Some(authenticator.clone()),
    );

    account.sign_in(std::future::pending()).await.expect("signed in");

    let [(url, scheme)] = authenticator.asked().try_into().expect("one page");
    assert_eq!(scheme, "app.tablepro");
    assert_eq!(query(&url, "client_id").as_deref(), Some("tablepro-macos"));
    assert_eq!(
        query(&url, "redirect_uri").as_deref(),
        Some("app.tablepro:/oauth/callback")
    );
    let exchange = asked(&requests)
        .into_iter()
        .find(|request| request.starts_with("POST /oauth/token"))
        .expect("the exchange");
    assert!(
        exchange.contains("code=mac-code") && exchange.contains("redirect_uri=app.tablepro%3A%2Foauth%2Fcallback"),
        "{exchange}"
    );
    assert!(signed_in(&account).entitlement.is_some());
    assert_eq!(
        keyring
            .token
            .lock()
            .await
            .as_ref()
            .map(|token| token.expose_secret().to_owned())
            .as_deref(),
        Some("stub-refresh")
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_web_sign_in_that_is_canceled_or_comes_back_elsewhere_signs_nothing_in() {
    let answers: [(Answer, &str); 4] = [
        (|_| Err(WebAuthenticationError::Canceled), "account.sign_in_canceled"),
        (
            |_| Err(WebAuthenticationError::Failed("no window".to_owned())),
            "account.browser",
        ),
        (
            |_| {
                Url::parse("app.tablepro:/oauth/callback?code=c&state=another")
                    .map_err(|_| WebAuthenticationError::Canceled)
            },
            "account.protocol",
        ),
        (
            |url| {
                let state = query(url, "state").unwrap_or_default();
                Url::parse(&format!("app.tablepro:/elsewhere?code=c&state={state}"))
                    .map_err(|_| WebAuthenticationError::Canceled)
            },
            "account.protocol",
        ),
    ];
    for (answer, code) in answers {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let requests = Asked::default();
        let account = mac(
            dir.path(),
            production_stub(requests.clone()),
            Keyring::holding(None),
            Some(Authenticator::answering(answer)),
        );

        let ended = account.sign_in(std::future::pending()).await.expect_err("no sign-in");

        assert_eq!(ended.code(), code, "{ended}");
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        assert!(asked(&requests).is_empty(), "{:?}", asked(&requests));
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_web_sign_in_a_sign_out_superseded_is_revoked_not_adopted() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    let gate = Arc::new(Semaphore::new(0));
    let authenticator = Arc::new(Authenticator {
        asked: StdMutex::default(),
        answer: approved,
        gate: Some(gate.clone()),
    });
    let keyring = Keyring::holding(None);
    let account = mac(
        dir.path(),
        production_stub(requests.clone()),
        keyring.clone(),
        Some(authenticator.clone()),
    );
    let signing_in = tokio::spawn({
        let account = account.clone();
        async move { account.sign_in(std::future::pending()).await }
    });
    while authenticator.asked().is_empty() {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    account.sign_out().await.expect("signed out");
    gate.add_permits(1);
    let late = signing_in.await.expect("the sign-in task");

    assert!(matches!(late, Err(AccountError::SignInCanceled)), "{late:?}");
    assert!(
        asked(&requests)
            .iter()
            .any(|request| request.starts_with("POST /oauth/revoke") && request.contains("token=stub-refresh"))
    );
    assert!(keyring.token.lock().await.is_none());
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_license_key_signs_the_mac_in_through_the_token_exchange() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    let keyring = Keyring::holding(None);
    let account = mac(dir.path(), production_stub(requests.clone()), keyring.clone(), None);

    account
        .use_license_key(&SecretString::from("TP-KEY-1234"))
        .await
        .expect("signed in");

    let exchange = asked(&requests)
        .into_iter()
        .find(|request| request.starts_with("POST /oauth/token"))
        .expect("the exchange");
    let sent = form(exchange.splitn(3, ' ').nth(2).unwrap_or_default());
    assert_eq!(
        sent.get("grant_type").map(String::as_str),
        Some("urn:ietf:params:oauth:grant-type:token-exchange")
    );
    assert_eq!(
        sent.get("subject_token_type").map(String::as_str),
        Some("https://account.tablepro.app/token-types/license-key")
    );
    assert_eq!(sent.get("subject_token").map(String::as_str), Some("TP-KEY-1234"));
    assert_eq!(sent.get("client_id").map(String::as_str), Some("tablepro-macos"));
    assert_eq!(sent.get("platform").map(String::as_str), Some("macos"));
    assert_eq!(sent.get("machine_id").map(String::as_str), Some(machine().as_str()));
    assert!(
        asked(&requests)
            .iter()
            .any(|request| request.starts_with("POST /v2/devices "))
    );
    assert!(signed_in(&account).entitlement.is_some());
    assert_eq!(stored(dir.path()).await.device_id.as_deref(), Some(DEVICE));
    assert!(keyring.token.lock().await.is_some());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_license_key_leaves_the_mac_signed_out_and_a_company_server_never_sees_one() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let account = mac(
        dir.path(),
        production_stub(Asked::default()),
        Keyring::holding(None),
        None,
    );
    let company_dir = tempfile::tempdir().expect("a temporary directory");
    let sent = Arc::new(AtomicUsize::new(0));
    let base = company(&LICENSED, {
        let sent = sent.clone();
        move |_, method, path, _| {
            if (method, path) == ("POST", "/oauth/token") {
                sent.fetch_add(1, Ordering::SeqCst);
            }
            None
        }
    });
    let items = Arc::new(Items::default());
    let at_company = super::company_tests::open(
        settings(company_dir.path(), AppClient::MACOS, managed(&base, None)),
        &items,
        Arc::default(),
    );

    let refused = account.use_license_key(&SecretString::from("refused")).await;
    let elsewhere = at_company.use_license_key(&SecretString::from("TP-KEY-1234")).await;

    assert!(
        matches!(&refused, Err(AccountError::SignInRefused { error, .. }) if error == "invalid_grant"),
        "{refused:?}"
    );
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    assert!(
        matches!(elsewhere, Err(AccountError::Server(ServerError::Unsupported(_)))),
        "{elsewhere:?}"
    );
    assert_eq!(sent.load(Ordering::SeqCst), 0);
}

async fn legacy(dir: &Path, token: &str) {
    let folder = dir.join("Account");
    tokio::fs::create_dir_all(&folder).await.expect("the folder");
    tokio::fs::write(folder.join("entitlement.jwt"), format!("{token}\n"))
        .await
        .expect("the file");
}

fn legacy_token(issued: chrono::DateTime<Utc>, mid: &str) -> String {
    let mut claims = fakes::claims(issued, TimeDelta::days(14), &["team_library"]);
    claims.mid = mid.to_owned();
    fakes::sign(&claims).expect("a token")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_mac_s_sign_in_is_adopted_with_its_device_and_the_entitlement_file_goes() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    legacy(dir.path(), &legacy_token(Utc::now(), machine().as_str())).await;
    let account = mac(
        dir.path(),
        production_stub(requests.clone()),
        Keyring::holding(Some("kept-refresh")),
        None,
    );

    account.restore().await;
    account.refresh_entitlement().await.expect("refreshed");

    assert!(signed_in(&account).entitlement.is_some());
    let file = stored(dir.path()).await;
    assert_eq!(
        (file.device_id.as_deref(), file.account_id.as_deref()),
        (Some(DEVICE), Some(ACCOUNT))
    );
    assert!(!dir.path().join("Account").join("entitlement.jwt").exists());
    assert!(
        !asked(&requests)
            .iter()
            .any(|request| request.starts_with("POST /v2/devices ")),
        "{:?}",
        asked(&requests)
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_expired_or_another_machine_s_entitlement_adopts_the_sign_in_and_a_missing_token_none() {
    let expired = tempfile::tempdir().expect("a temporary directory");
    legacy(
        expired.path(),
        &legacy_token(Utc::now() - TimeDelta::days(20), machine().as_str()),
    )
    .await;
    let other = tempfile::tempdir().expect("a temporary directory");
    legacy(other.path(), &legacy_token(Utc::now(), fakes::MACHINE)).await;
    let missing = tempfile::tempdir().expect("a temporary directory");
    legacy(missing.path(), &legacy_token(Utc::now(), machine().as_str())).await;

    let lapsed = mac(
        expired.path(),
        super::tests::unreachable(),
        Keyring::holding(Some("kept-refresh")),
        None,
    );
    lapsed.restore().await;
    let moved = mac(
        other.path(),
        super::tests::unreachable(),
        Keyring::holding(Some("kept-refresh")),
        None,
    );
    moved.restore().await;
    let keyring = Keyring::holding(None);
    let signed_out = mac(missing.path(), super::tests::unreachable(), keyring.clone(), None);
    signed_out.restore().await;

    assert!(matches!(signed_in(&lapsed).problem, Some(EntitlementProblem::Expired)));
    assert_eq!(stored(expired.path()).await.device_id.as_deref(), Some(DEVICE));
    assert!(signed_in(&moved).entitlement.is_none());
    assert_eq!(stored(other.path()).await.device_id, None);
    assert!(matches!(*signed_out.status().borrow(), AccountStatus::SignedOut));
    assert!(!missing.path().join("Account").join("entitlement.jwt").exists());
    assert!(!missing.path().join("account.json").exists());
    assert_eq!(keyring.opened(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_account_file_of_another_server_signs_out_of_it_at_restore() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let file = AccountFile {
        device_id: Some(DEVICE.to_owned()),
        server: Some("https://api.other.example/v2".to_owned()),
        ..AccountFile::default()
    };
    account_file::write(&dir.path().join("account.json"), &file)
        .await
        .expect("the account file");
    let items = Arc::new(Items::default());
    let other = SignInKey::of("https://api.other.example/v2", &dir.path().join("account.json"));
    *items.holding(&other).token.lock().await = Some(SecretString::from("other-refresh"));
    let account = super::company_tests::open(
        settings(dir.path(), AppClient::MACOS, managed("https://127.0.0.1:1", None)),
        &items,
        Arc::default(),
    );
    let mut sign_outs = account.sign_outs();

    account.restore().await;

    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    assert!(items.holding(&other).token.lock().await.is_none());
    assert!(!dir.path().join("account.json").exists());
    assert_eq!(sign_outs.try_recv().ok(), Some(SignOutCause::ServerChanged));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_access_token_is_refreshed_once_the_api_rejected_it_and_each_sign_out_says_why() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    keep(dir.path(), None).await;
    let requests = Asked::default();
    let account = mac(
        dir.path(),
        production_stub(requests.clone()),
        Keyring::holding(Some("kept-refresh")),
        None,
    );
    account.restore().await;
    let mut sign_outs = account.sign_outs();

    let first = account.access_token().await.expect("a token");
    let again = account.access_token().await.expect("a token");
    account.access_token_rejected(&first.token).await;
    let renewed = account.access_token().await.expect("a token");
    account.sign_out().await.expect("signed out");

    let refreshes = asked(&requests)
        .iter()
        .filter(|request| request.starts_with("POST /oauth/token"))
        .count();
    assert_eq!(refreshes, 2);
    assert_eq!(
        (
            first.token.expose_secret(),
            again.token.expose_secret(),
            renewed.token.expose_secret()
        ),
        ("stub-access", "stub-access", "stub-access")
    );
    assert!(first.api.ends_with("/v2"), "{}", first.api);
    assert_eq!(sign_outs.try_recv().ok(), Some(SignOutCause::Requested));
}

// The account file's folder is a link to nothing: it reads as missing, and no file can be written there.
#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_mac_s_entitlement_stays_while_the_account_file_cannot_be_written() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    legacy(dir.path(), &legacy_token(Utc::now(), machine().as_str())).await;
    std::os::unix::fs::symlink(dir.path().join("gone"), dir.path().join("state")).expect("the link");
    let settings = AccountSettings {
        client: AppClient::MACOS,
        account_file: dir.path().join("state").join("account.json"),
        legacy_entitlement_file: Some(dir.path().join("Account").join("entitlement.jwt")),
        ..stub_settings(dir.path(), super::tests::unreachable())
    };
    let hosts = AccountHosts {
        vaults: Arc::new(crate::token_vault::SingleVault(Keyring::holding(Some("kept-refresh")))),
        browser: Arc::new(super::tests::NoBrowser),
        web_authenticator: None,
    };
    let account = Account::open(settings, hosts, watch::Sender::new(AccountStatus::SignedOut)).expect("an account");

    account.restore().await;

    assert!(signed_in(&account).entitlement.is_some());
    assert!(dir.path().join("Account").join("entitlement.jwt").exists());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_mac_s_offline_file_with_no_sign_in_stays_an_offline_file() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let mut claims = fakes::claims(Utc::now(), TimeDelta::days(30), &["team_library"]);
    claims.mid = machine().as_str().to_owned();
    claims.offline = true;
    legacy(dir.path(), &fakes::sign(&claims).expect("a token")).await;
    let keyring = Keyring::holding(None);
    let account = mac(dir.path(), super::tests::unreachable(), keyring.clone(), None);

    account.restore().await;

    assert!(matches!(*account.status().borrow(), AccountStatus::Offline(_)));
    let file = stored(dir.path()).await;
    assert!(file.offline_only);
    assert_eq!(file.account_id.as_deref(), Some(ACCOUNT));
    assert!(!dir.path().join("Account").join("entitlement.jwt").exists());
    let restarted = mac(dir.path(), super::tests::unreachable(), keyring.clone(), None);
    restarted.restore().await;
    assert!(matches!(*restarted.status().borrow(), AccountStatus::Offline(_)));
    assert_eq!(keyring.opened(), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_429_on_the_key_exchange_holds_the_next_try() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    let endpoints = cloud_with_bodies({
        let requests = requests.clone();
        move |method, path, _| {
            requests.lock().expect("the requests").push(format!("{method} {path}"));
            (
                429,
                "retry-after: 60\r\n",
                r#"{"error":"temporarily_unavailable"}"#.to_owned(),
            )
        }
    });
    let account = mac(dir.path(), endpoints, Keyring::holding(None), None);

    let first = account.use_license_key(&SecretString::from("TP-KEY-1234")).await;
    let second = account.use_license_key(&SecretString::from("TP-KEY-1234")).await;

    assert!(
        matches!(first, Err(AccountError::RateLimited { retry_after: Some(_) })),
        "{first:?}"
    );
    assert!(matches!(second, Err(AccountError::RateLimited { .. })), "{second:?}");
    assert_eq!(asked(&requests).len(), 1, "{:?}", asked(&requests));
}
