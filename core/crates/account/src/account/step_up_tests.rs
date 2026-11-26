use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::path::Path;
use std::sync::{Arc, Mutex as StdMutex};

use async_trait::async_trait;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::Utc;
use secrecy::ExposeSecret as _;
use tokio::sync::{Semaphore, watch};
use url::Url;

use super::company_tests::{Items, LICENSED, company, managed, open, settings};
use super::tests::{
    ACCOUNT, Asked, HeldBrowser, Keyring, NoBrowser, OTHER_ACCOUNT, answer, approve, asked, device_answer, entitlement,
    form, keep, signed_in, stored, stub_settings,
};
use super::{Account, AccountHosts};
use crate::account_error::AccountError;
use crate::account_settings::{AccountSettings, AppClient, Endpoints, SignInKey};
use crate::account_status::AccountStatus;
use crate::browser::{WebAuthenticationError, WebAuthenticator};
use crate::server::ServerError;
use crate::token_vault::SingleVault;
use tablepro_cloud_api::StepUpChallenge;

const DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4ww4";
const LOST_DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4zzz";
const PASSKEY: &str = "urn:tablepro:acr:passkey";
const EMAIL_CODE: &str = "urn:tablepro:acr:email-code";
// tablepro.app's challenge: a passkey, or an emailed code while the account has none (core ADR 0051, Step-up).
const SAAS_CHALLENGE: &str = r#"Bearer error="insufficient_user_authentication", error_description="A fresh step-up is required", acr_values="urn:tablepro:acr:passkey urn:tablepro:acr:email-code", max_age=300"#;

// A request as the stub reads it.
struct Request {
    method: String,
    path: String,
    bearer: Option<String>,
    body: String,
}

// tablepro-cloud for a signed-in account on one machine: refresh families, the step-up's code exchange, the device
// registration that binds a family, and a device removal that needs a fresh step-up.
struct Server {
    challenge: &'static str,
    // The account the browser's session steps up.
    browser_account: &'static str,
    // Whether the removal ever takes a stepped-up token.
    takes_step_up: bool,
    // The families POST /v2/devices bound.
    bound: StdMutex<Vec<String>>,
    // Code exchanges answered so far: each after the first gets a refresh token of its own.
    exchanges: StdMutex<usize>,
    log: StdMutex<Vec<String>>,
    revoked: StdMutex<Vec<String>>,
}

impl Server {
    fn new(challenge: &'static str) -> Arc<Self> {
        Self::answering(challenge, ACCOUNT, true)
    }

    fn answering(challenge: &'static str, browser_account: &'static str, takes_step_up: bool) -> Arc<Self> {
        Arc::new(Self {
            challenge,
            browser_account,
            takes_step_up,
            bound: StdMutex::default(),
            exchanges: StdMutex::default(),
            log: StdMutex::default(),
            revoked: StdMutex::default(),
        })
    }

    fn log(&self) -> Vec<String> {
        self.log.lock().expect("the log").clone()
    }

    fn revoked(&self) -> Vec<String> {
        self.revoked.lock().expect("the revocations").clone()
    }

    fn start(self: &Arc<Self>) -> Endpoints {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        let server = self.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                server.serve(stream);
            }
        });
        Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints")
    }

    fn serve(&self, stream: std::net::TcpStream) {
        let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
        let mut line = String::new();
        reader.read_line(&mut line).expect("the request line");
        let mut words = line.split_whitespace();
        let (method, path) = (words.next().unwrap_or_default(), words.next().unwrap_or_default());
        let (mut length, mut bearer) = (0, None);
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).expect("a header");
            if header.trim().is_empty() {
                break;
            }
            let (name, value) = header.split_once(':').unwrap_or_default();
            match name.to_ascii_lowercase().as_str() {
                "content-length" => length = value.trim().parse().expect("a length"),
                "authorization" => bearer = value.trim().strip_prefix("Bearer ").map(str::to_owned),
                _ => {}
            }
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).expect("the body");
        let request = Request {
            method: method.to_owned(),
            path: path.to_owned(),
            bearer,
            body: String::from_utf8_lossy(&body).into_owned(),
        };
        let (status, headers, body) = self.answer(&request);
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .expect("the answer");
    }

    fn answer(&self, request: &Request) -> (u16, String, String) {
        let claims = request.bearer.as_deref().and_then(Claims::of).unwrap_or_default();
        let fields = form(&request.body);
        let entry = match (request.method.as_str(), request.path.as_str()) {
            ("POST", "/oauth/token") => format!(
                "token {}",
                fields
                    .get("refresh_token")
                    .map_or_else(|| "code".to_owned(), String::clone)
            ),
            _ => format!(
                "{} {} {}",
                request.method,
                request.path,
                claims.family.as_deref().unwrap_or("-")
            ),
        };
        self.log.lock().expect("the log").push(entry);
        match (request.method.as_str(), request.path.as_str()) {
            ("POST", "/oauth/token") => self.token(&fields),
            ("POST", "/oauth/revoke") => {
                let token = fields.get("token").cloned().unwrap_or_default();
                self.revoked.lock().expect("the revocations").push(token);
                (200, String::new(), String::new())
            }
            ("POST", "/v2/devices") => {
                let family = claims.family.unwrap_or_default();
                self.bound.lock().expect("the families").push(family);
                (200, String::new(), device_answer())
            }
            ("DELETE", path) if path == format!("/v2/devices/{LOST_DEVICE}") => {
                let stepped = claims.acr.is_some() && claims.dev.is_some();
                match stepped && self.takes_step_up {
                    true => (204, String::new(), String::new()),
                    false => (
                        401,
                        format!("www-authenticate: {}\r\n", self.challenge),
                        r#"{"type":"https://api.tablepro.app/problems/step-up-required","title":"Step up required","status":401,"code":"step_up_required"}"#.to_owned(),
                    ),
                }
            }
            _ => (404, String::new(), String::new()),
        }
    }

    // A family's tokens: the step-up's carry `acr`, and only a family a registration bound names the device.
    fn token(&self, fields: &std::collections::HashMap<String, String>) -> (u16, String, String) {
        let (family, refresh, subject) = match fields.get("grant_type").map(String::as_str) {
            Some("authorization_code") => {
                if fields.get("code").map(String::as_str) != Some("step-code")
                    || fields.get("code_verifier").is_none_or(String::is_empty)
                {
                    return (400, String::new(), r#"{"error":"invalid_grant"}"#.to_owned());
                }
                let mut exchanges = self.exchanges.lock().expect("the exchanges");
                *exchanges += 1;
                let refresh = match *exchanges {
                    1 => "stepped-refresh".to_owned(),
                    n => format!("stepped-refresh-{n}"),
                };
                ("stepped", refresh, self.browser_account)
            }
            Some("refresh_token") => {
                let presented = fields.get("refresh_token").cloned().unwrap_or_default();
                let family = if presented.starts_with("stepped") {
                    "stepped"
                } else {
                    "old"
                };
                (family, format!("{presented}+"), ACCOUNT)
            }
            _ => return (400, String::new(), r#"{"error":"unsupported_grant_type"}"#.to_owned()),
        };
        let stepped = family == "stepped";
        let bound = !stepped || self.bound.lock().expect("the families").iter().any(|it| it == family);
        let claims = Claims {
            sub: subject.to_owned(),
            family: Some(family.to_owned()),
            acr: stepped.then(|| PASSKEY.to_owned()),
            auth_time: stepped.then(|| Utc::now().timestamp()),
            dev: (bound && fields.get("grant_type").map(String::as_str) == Some("refresh_token"))
                .then(|| DEVICE.to_owned()),
            ..Claims::default()
        };
        let access = claims.token();
        let tokens = format!(
            r#"{{"access_token":"{access}","token_type":"Bearer","expires_in":900,"refresh_token":"{refresh}"}}"#
        );
        (200, String::new(), tokens)
    }
}

// An access token's claims, as tablepro-cloud signs them; the stub signs nothing.
#[derive(Default, serde::Serialize, serde::Deserialize)]
struct Claims {
    sub: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    aud: Option<Vec<String>>,
    // The stub's own: which refresh family the token is of.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    acr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    auth_time: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    dev: Option<String>,
}

impl Claims {
    fn of(token: &str) -> Option<Self> {
        let payload = token.split('.').nth(1)?;
        serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload).ok()?).ok()
    }

    fn token(&self) -> String {
        let json = serde_json::to_string(self).expect("the claims");
        format!("e30.{}.c2ln", URL_SAFE_NO_PAD.encode(json))
    }
}

// Stands in for ASWebAuthenticationSession: keeps each page it opened and answers it, once the test lets it when a
// gate is set.
struct Authenticator {
    opened: StdMutex<Vec<Url>>,
    answer: fn(&Url) -> Result<Url, WebAuthenticationError>,
    gate: Option<Arc<Semaphore>>,
}

impl Authenticator {
    fn answering(answer: fn(&Url) -> Result<Url, WebAuthenticationError>) -> Arc<Self> {
        Arc::new(Self {
            opened: StdMutex::default(),
            answer,
            gate: None,
        })
    }

    fn opened(&self) -> Vec<Url> {
        self.opened.lock().expect("the pages").clone()
    }
}

#[async_trait]
impl WebAuthenticator for Authenticator {
    async fn authenticate(&self, url: &Url, _: &str) -> Result<Url, WebAuthenticationError> {
        self.opened.lock().expect("the pages").push(url.clone());
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

// The person confirms with a passkey and the server redirects with the code and the request's state.
fn confirmed(url: &Url) -> Result<Url, WebAuthenticationError> {
    let state = query(url, "state").unwrap_or_default();
    Url::parse(&format!("app.tablepro:/oauth/callback?code=step-code&state={state}"))
        .map_err(|error| WebAuthenticationError::Failed(error.to_string()))
}

fn closed(_: &Url) -> Result<Url, WebAuthenticationError> {
    Err(WebAuthenticationError::Canceled)
}

fn mac(dir: &Path, endpoints: Endpoints, keyring: Arc<Keyring>, authenticator: Arc<Authenticator>) -> Account {
    let settings = AccountSettings {
        client: AppClient::MACOS,
        ..stub_settings(dir, endpoints)
    };
    let hosts = AccountHosts {
        vaults: Arc::new(SingleVault(keyring)),
        browser: Arc::new(NoBrowser),
        web_authenticator: Some(authenticator),
    };
    Account::open(settings, hosts, watch::Sender::new(AccountStatus::SignedOut)).expect("an account")
}

// Signed in on this machine with a kept entitlement, as a launch restores it.
async fn restored_mac(
    server: &Arc<Server>,
    authenticator: Arc<Authenticator>,
) -> (tempfile::TempDir, Arc<Keyring>, Account) {
    let dir = tempfile::tempdir().expect("a temporary directory");
    keep(dir.path(), Some(entitlement(Utc::now()))).await;
    let keyring = Keyring::holding(Some("old-refresh"));
    let account = mac(dir.path(), server.start(), keyring.clone(), authenticator);
    account.restore().await;
    (dir, keyring, account)
}

async fn held(keyring: &Keyring) -> Option<String> {
    keyring
        .token
        .lock()
        .await
        .as_ref()
        .map(|token| token.expose_secret().to_owned())
}

async fn remove_lost_device(account: &Account) -> Result<(), AccountError> {
    account
        .stepped_up(std::future::pending(), async || {
            account.remove_device(LOST_DEVICE).await
        })
        .await
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_challenged_call_steps_up_in_the_browser_registers_the_new_family_and_runs_again() {
    let server = Server::new(SAAS_CHALLENGE);
    let authenticator = Authenticator::answering(confirmed);
    let (dir, keyring, account) = restored_mac(&server, authenticator.clone()).await;
    let session = signed_in(&account).session_id;
    let kept = stored(dir.path()).await.entitlement;

    remove_lost_device(&account).await.expect("removed after the step-up");

    let [page] = authenticator.opened().try_into().expect("one page");
    assert_eq!(
        query(&page, "acr_values").as_deref(),
        Some(format!("{PASSKEY} {EMAIL_CODE}").as_str())
    );
    assert_eq!(query(&page, "max_age").as_deref(), Some("300"));
    assert_eq!(query(&page, "code_challenge_method").as_deref(), Some("S256"));
    assert!(
        query(&page, "code_challenge").is_some_and(|it| it.len() == 43),
        "{page}"
    );
    assert_eq!(query(&page, "client_id").as_deref(), Some("tablepro-macos"));
    assert_eq!(
        server.log(),
        [
            "token old-refresh",
            &format!("DELETE /v2/devices/{LOST_DEVICE} old"),
            "token code",
            "POST /oauth/revoke -",
            "POST /v2/devices stepped",
            "token stepped-refresh",
            &format!("DELETE /v2/devices/{LOST_DEVICE} stepped"),
            // The refresh every removal ends with, which this stub does not answer.
            &format!("POST /v2/devices/{DEVICE}/entitlement stepped"),
        ]
    );
    assert_eq!(server.revoked(), ["old-refresh+"]);
    assert_eq!(held(&keyring).await.as_deref(), Some("stepped-refresh+"));
    let file = stored(dir.path()).await;
    assert_eq!(file.device_id.as_deref(), Some(DEVICE));
    assert_eq!(file.account_id.as_deref(), Some(ACCOUNT));
    assert_eq!(file.entitlement, kept);
    let after = signed_in(&account);
    assert!(after.entitlement.is_some());
    assert_eq!(after.session_id, session);
}

// RFC 9470 section 3 lets a challenge name the methods, the age or both; the page asks for exactly what it named.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn each_challenge_s_methods_and_age_go_to_the_authorization_endpoint_as_named() {
    let cases: [(&'static str, Option<&str>, Option<&str>); 4] = [
        (
            SAAS_CHALLENGE,
            Some("urn:tablepro:acr:passkey urn:tablepro:acr:email-code"),
            Some("300"),
        ),
        (
            r#"Bearer error="insufficient_user_authentication", acr_values="urn:tablepro:acr:passkey", max_age=300"#,
            Some(PASSKEY),
            Some("300"),
        ),
        (
            r#"Bearer error="insufficient_user_authentication", max_age="60""#,
            None,
            Some("60"),
        ),
        (
            r#"DPoP algs="EdDSA", Bearer error="insufficient_user_authentication", acr_values="urn:tablepro:acr:passkey""#,
            Some(PASSKEY),
            None,
        ),
    ];
    for (challenge, acr_values, max_age) in cases {
        let server = Server::new(challenge);
        let authenticator = Authenticator::answering(confirmed);
        let (_dir, _keyring, account) = restored_mac(&server, authenticator.clone()).await;

        remove_lost_device(&account).await.expect(challenge);

        let [page] = authenticator.opened().try_into().expect(challenge);
        assert_eq!(query(&page, "acr_values").as_deref(), acr_values, "{challenge}");
        assert_eq!(query(&page, "max_age").as_deref(), max_age, "{challenge}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_server_that_challenges_the_stepped_up_call_again_gets_its_challenge_back_and_one_page() {
    let server = Server::answering(SAAS_CHALLENGE, ACCOUNT, false);
    let authenticator = Authenticator::answering(confirmed);
    let (_dir, keyring, account) = restored_mac(&server, authenticator.clone()).await;

    let again = remove_lost_device(&account).await;

    assert!(
        matches!(&again, Err(AccountError::StepUpRequired(challenge))
            if *challenge == StepUpChallenge { acr_values: vec![PASSKEY.to_owned(), EMAIL_CODE.to_owned()], max_age_secs: Some(300) }),
        "{again:?}"
    );
    assert_eq!(authenticator.opened().len(), 1);
    assert_eq!(held(&keyring).await.as_deref(), Some("stepped-refresh+"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_step_up_of_another_account_is_revoked_and_the_sign_in_stays_as_it_was() {
    let server = Server::answering(SAAS_CHALLENGE, OTHER_ACCOUNT, true);
    let authenticator = Authenticator::answering(confirmed);
    let (dir, keyring, account) = restored_mac(&server, authenticator).await;

    let refused = remove_lost_device(&account).await;

    assert!(matches!(refused, Err(AccountError::StepUpOtherAccount)), "{refused:?}");
    assert_eq!(server.revoked(), ["stepped-refresh"]);
    assert_eq!(held(&keyring).await.as_deref(), Some("old-refresh+"));
    assert!(!server.log().iter().any(|entry| entry.starts_with("POST /v2/devices")));
    assert_eq!(stored(dir.path()).await.device_id.as_deref(), Some(DEVICE));
    assert_eq!(AccountError::StepUpOtherAccount.code(), "account.step_up_other_account");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_step_up_closed_in_the_browser_changes_nothing() {
    let server = Server::new(SAAS_CHALLENGE);
    let authenticator = Authenticator::answering(closed);
    let (dir, keyring, account) = restored_mac(&server, authenticator).await;

    let closed = remove_lost_device(&account).await;

    assert!(matches!(closed, Err(AccountError::SignInCanceled)), "{closed:?}");
    assert!(server.revoked().is_empty());
    assert_eq!(held(&keyring).await.as_deref(), Some("old-refresh+"));
    assert_eq!(stored(dir.path()).await.device_id.as_deref(), Some(DEVICE));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_step_up_that_comes_back_after_a_sign_out_is_revoked_not_adopted() {
    let server = Server::new(SAAS_CHALLENGE);
    let gate = Arc::new(Semaphore::new(0));
    let authenticator = Arc::new(Authenticator {
        opened: StdMutex::default(),
        answer: confirmed,
        gate: Some(gate.clone()),
    });
    let (_dir, keyring, account) = restored_mac(&server, authenticator.clone()).await;
    let challenge = StepUpChallenge {
        acr_values: vec![PASSKEY.to_owned()],
        max_age_secs: Some(300),
    };
    let stepping_up = tokio::spawn({
        let account = account.clone();
        async move { account.step_up(&challenge, std::future::pending()).await }
    });
    while authenticator.opened().is_empty() {
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }

    account.sign_out().await.expect("signed out");
    gate.add_permits(1);
    let late = stepping_up.await.expect("the step-up task");

    assert!(matches!(late, Err(AccountError::SignedOut)), "{late:?}");
    assert_eq!(server.revoked(), ["old-refresh", "stepped-refresh"]);
    assert!(held(&keyring).await.is_none());
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
}

// A sign-in started before the step-up moves no attempt when it commits; its new session still ends the step-up.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_step_up_that_comes_back_after_an_earlier_sign_in_committed_is_revoked_not_adopted() {
    let server = Server::new(SAAS_CHALLENGE);
    let gate = Arc::new(Semaphore::new(0));
    let authenticator = Arc::new(Authenticator {
        opened: StdMutex::default(),
        answer: confirmed,
        gate: Some(gate.clone()),
    });
    let (_dir, keyring, account) = restored_mac(&server, authenticator.clone()).await;
    let before = signed_in(&account).session_id;
    let opened = |count: usize| {
        let authenticator = authenticator.clone();
        async move {
            while authenticator.opened().len() < count {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        }
    };
    let signing_in = tokio::spawn({
        let account = account.clone();
        async move { account.sign_in(std::future::pending()).await }
    });
    opened(1).await;
    let challenge = StepUpChallenge {
        acr_values: vec![PASSKEY.to_owned()],
        max_age_secs: Some(300),
    };
    let stepping_up = tokio::spawn({
        let account = account.clone();
        async move { account.step_up(&challenge, std::future::pending()).await }
    });
    opened(2).await;

    gate.add_permits(1);
    let _ = signing_in.await.expect("the sign-in task");
    let signed_in_now = signed_in(&account).session_id;
    gate.add_permits(1);
    let late = stepping_up.await.expect("the step-up task");

    assert!(matches!(late, Err(AccountError::SignInCanceled)), "{late:?}");
    assert_ne!(signed_in_now, before);
    assert_eq!(signed_in(&account).session_id, signed_in_now);
    assert!(
        server.revoked().contains(&"stepped-refresh-2".to_owned()),
        "{:?}",
        server.revoked()
    );
    assert_eq!(held(&keyring).await.as_deref(), Some("stepped-refresh+"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn signed_out_a_step_up_opens_no_page() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let server = Server::new(SAAS_CHALLENGE);
    let authenticator = Authenticator::answering(confirmed);
    let account = mac(
        dir.path(),
        server.start(),
        Keyring::holding(None),
        authenticator.clone(),
    );
    account.restore().await;
    let challenge = StepUpChallenge {
        acr_values: vec![PASSKEY.to_owned()],
        max_age_secs: Some(300),
    };

    let refused = account.step_up(&challenge, std::future::pending()).await;

    assert!(matches!(refused, Err(AccountError::SignedOut)), "{refused:?}");
    assert!(authenticator.opened().is_empty());
    assert!(server.log().is_empty());
}

// The Linux app's client: the page in the system browser, the answer on a loopback port.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_loopback_client_steps_up_through_the_system_browser() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    keep(dir.path(), Some(entitlement(Utc::now()))).await;
    let server = Server::new(SAAS_CHALLENGE);
    let keyring = Keyring::holding(Some("old-refresh"));
    let browser = Arc::new(HeldBrowser::default());
    let account = Account::new(
        stub_settings(dir.path(), server.start()),
        keyring.clone(),
        browser.clone(),
        watch::Sender::new(AccountStatus::SignedOut),
    )
    .expect("an account");
    account.restore().await;

    let (removed, ()) = tokio::join!(remove_lost_device(&account), answer(&browser, &[("code", "step-code")]));

    removed.expect("removed after the step-up");
    let page = browser.opened.lock().expect("the URL").clone().expect("a page");
    assert_eq!(
        query(&page, "acr_values").as_deref(),
        Some(format!("{PASSKEY} {EMAIL_CODE}").as_str())
    );
    assert_eq!(query(&page, "max_age").as_deref(), Some("300"));
    assert!(query(&page, "redirect_uri").is_some_and(|it| it.starts_with("http://127.0.0.1:")));
    assert_eq!(held(&keyring).await.as_deref(), Some("stepped-refresh+"));
}

// Signs in to a company server, then steps up with tokens whose `aud` `audience` gives for the server's origin. Answers
// the step-up, what the server was asked, the refresh tokens it revoked and the sign-in's keyring item.
async fn company_step_up(
    audience: fn(&str) -> String,
) -> (
    Result<(), AccountError>,
    Vec<String>,
    Vec<String>,
    Option<String>,
    Url,
    String,
) {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let requests = Asked::default();
    let revoked = Asked::default();
    let base = company(&LICENSED, {
        let (requests, revoked) = (requests.clone(), revoked.clone());
        move |origin, method, path, body| {
            requests.lock().expect("the requests").push(format!("{method} {path}"));
            let fields = form(body);
            let tokens = |claims: &Claims, refresh: &str| {
                let access = claims.token();
                Some((
                    200,
                    format!(
                        r#"{{"access_token":"{access}","token_type":"Bearer","expires_in":900,"refresh_token":"{refresh}"}}"#
                    ),
                ))
            };
            let stepped = Claims {
                sub: ACCOUNT.to_owned(),
                aud: Some(vec![audience(origin)]),
                acr: Some(PASSKEY.to_owned()),
                auth_time: Some(Utc::now().timestamp()),
                ..Claims::default()
            };
            match (method, path) {
                ("POST", "/oauth/token") if fields.get("code").map(String::as_str) == Some("step-code") => {
                    tokens(&stepped, "company-stepped")
                }
                ("POST", "/oauth/token")
                    if fields.get("refresh_token").map(String::as_str) == Some("company-stepped") =>
                {
                    tokens(&stepped, "company-stepped+")
                }
                ("POST", "/oauth/revoke") => {
                    revoked
                        .lock()
                        .expect("the revocations")
                        .push(fields.get("token").cloned().unwrap_or_default());
                    None
                }
                _ => None,
            }
        }
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, Some(false))),
        &items,
        browser.clone(),
    );
    account.restore().await;
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    *browser.opened.lock().expect("the URL") = None;
    let challenge = StepUpChallenge {
        acr_values: vec![PASSKEY.to_owned()],
        max_age_secs: Some(300),
    };

    let (stepped, ()) = tokio::join!(
        account.step_up(&challenge, std::future::pending()),
        answer(&browser, &[("code", "step-code")])
    );

    let page = browser.opened.lock().expect("the URL").clone().expect("a page");
    let item = items.holding(&SignInKey::of(&format!("{base}/v2"), &dir.path().join("account.json")));
    let revoked = asked(&revoked);
    (stepped, asked(&requests), revoked, held(&item).await, page, base)
}

// The issuer is found again first, as at a sign-in (core ADR 0047), so a server that names another since gets no page.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_company_server_s_step_up_finds_its_issuer_again_and_takes_tokens_for_its_api() {
    let (stepped, requests, revoked, held, page, base) = company_step_up(str::to_owned).await;

    stepped.expect("stepped up");
    let discoveries = requests
        .iter()
        .filter(|request| *request == "GET /.well-known/openid-configuration")
        .count();
    assert_eq!(discoveries, 2, "{requests:?}");
    assert!(page.as_str().starts_with(&format!("{base}/oauth/authorize?")), "{page}");
    assert_eq!(query(&page, "acr_values").as_deref(), Some(PASSKEY));
    assert_eq!(query(&page, "max_age").as_deref(), Some("300"));
    assert_eq!(revoked, ["stub-refresh"]);
    assert_eq!(held.as_deref(), Some("company-stepped+"));
    let registered = requests.iter().filter(|request| *request == "POST /v2/devices").count();
    assert_eq!(registered, 2, "{requests:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_company_server_s_step_up_for_another_api_is_revoked() {
    let (stepped, requests, revoked, held, _, _) =
        company_step_up(|_| "https://other-install.example".to_owned()).await;

    assert!(
        matches!(stepped, Err(AccountError::Server(ServerError::Mismatch(_)))),
        "{stepped:?}"
    );
    assert_eq!(revoked, ["company-stepped"]);
    assert_eq!(held.as_deref(), Some("stub-refresh"));
    let registered = requests.iter().filter(|request| *request == "POST /v2/devices").count();
    assert_eq!(registered, 1, "{requests:?}");
}
