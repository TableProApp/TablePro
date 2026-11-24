use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use chrono::{TimeDelta, Utc};
use tokio::sync::watch;

use super::tests::{
    Answer, Asked, HeldBrowser, Keyring, TOKENS, approve, asked, device_answer, form, machine, serve, signed_in, stored,
};
use super::{Account, AccountHosts, SignOutCause};
use crate::account_error::AccountError;
use crate::account_settings::{AccountSettings, AppClient, CallbackPage, DeviceDescription, SignInKey};
use crate::account_status::{AccountStatus, EntitlementProblem, FeatureAccess};
use crate::fakes;
use crate::license_keys::LicenseKeys;
use crate::server::{self, ServerError, ServerPolicy, ServerSettings, choice_file};
use crate::token_vault::{RefreshTokenVault, RefreshTokenVaults};

const DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4ww4";
pub(super) const LICENSED: [&str; 2] = ["team_library", "service_sync"];

// A tablepro-cloud install on a loopback port: its metadata, OAuth, license and keys. `answer` takes any other call.
pub(super) fn company(
    license_features: &'static [&'static str],
    answer: impl Fn(&str, &str, &str, &str) -> Option<(u16, String)> + Send + Sync + 'static,
) -> String {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
    let base = format!("http://{}", listener.local_addr().expect("its address"));
    let origin = base.clone();
    let answering: Box<Answer> = Box::new(move |method: &str, path: &str, body: &str| {
        let (status, body) =
            answer(&origin, method, path, body).unwrap_or_else(|| standard(&origin, license_features, method, path));
        // tablepro-cloud sends Retry-After with every 429 (api.md, Conventions).
        let headers = if status == 429 { "retry-after: 60\r\n" } else { "" };
        (status, headers, body)
    });
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            serve(stream, answering.as_ref());
        }
    });
    base
}

fn standard(origin: &str, features: &[&str], method: &str, path: &str) -> (u16, String) {
    match (method, path) {
        ("GET", "/.well-known/oauth-protected-resource") => (
            200,
            format!(
                r#"{{"resource":"{origin}","authorization_servers":["{origin}"],"jwks_uri":"{origin}/v2/entitlement-keys","bearer_methods_supported":["header"],"scopes_supported":["app"]}}"#
            ),
        ),
        ("GET", "/.well-known/openid-configuration") => (
            200,
            format!(
                r#"{{"issuer":"{origin}","authorization_endpoint":"{origin}/oauth/authorize","token_endpoint":"{origin}/oauth/token","revocation_endpoint":"{origin}/oauth/revoke"}}"#
            ),
        ),
        ("POST", "/oauth/token") => (200, tokens_for(origin)),
        ("POST", "/oauth/revoke") => (200, String::new()),
        ("POST", "/v2/devices") => (201, device_answer()),
        ("GET", "/v2/license") => (200, license_answer(origin, Utc::now(), TimeDelta::days(365), features)),
        ("GET", "/v2/entitlement-keys") => (200, fakes::jwks()),
        ("POST", p) if p == format!("/v2/devices/{DEVICE}/entitlement") => (200, entitlement_answer(origin)),
        _ => (404, String::new()),
    }
}

// A tablepro-cloud install's tokens: its access token names its API origin in `aud`.
fn tokens_for(origin: &str) -> String {
    use base64::Engine as _;
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(format!(r#"{{"aud":["{origin}"]}}"#));
    TOKENS.replace("stub-access", &format!("e30.{claims}.c2ln"))
}

pub(super) fn license_answer(
    origin: &str,
    issued: chrono::DateTime<Utc>,
    lasts: TimeDelta,
    features: &[&str],
) -> String {
    let token = fakes::sign_license(&fakes::license_claims(origin, issued, lasts, features)).expect("a license");
    format!(r#"{{"license":"{token}"}}"#)
}

fn entitlement_answer(issuer: &str) -> String {
    let mut claims = fakes::claims(
        Utc::now(),
        TimeDelta::days(14),
        &["team_library", "service_sync", "env_var_references"],
    );
    claims.mid = machine().as_str().to_owned();
    claims.iss = issuer.to_owned();
    format!(
        r#"{{"token":"{}","expires_at":"2026-12-01T00:00:00Z","refresh_after":"2026-11-20T00:00:00Z"}}"#,
        fakes::sign(&claims).expect("a token")
    )
}

// One keyring item per sign-in, as the Mac's Keychain keeps them.
#[derive(Default)]
pub(super) struct Items {
    vaults: StdMutex<Vec<(SignInKey, Arc<Keyring>)>>,
}

impl Items {
    pub(super) fn holding(&self, sign_in: &SignInKey) -> Arc<Keyring> {
        let mut vaults = self.vaults.lock().expect("the items");
        if let Some((_, keyring)) = vaults.iter().find(|(key, _)| key == sign_in) {
            return keyring.clone();
        }
        let keyring = Keyring::holding(None);
        vaults.push((sign_in.clone(), keyring.clone()));
        keyring
    }
}

impl RefreshTokenVaults for Arc<Items> {
    fn vault(&self, sign_in: &SignInKey) -> Arc<dyn RefreshTokenVault> {
        self.holding(sign_in)
    }
}

pub(super) fn settings(dir: &Path, client: AppClient, server: ServerSettings) -> AccountSettings {
    AccountSettings {
        client,
        server,
        device: DeviceDescription {
            name: "Ada's Mac".to_owned(),
            app_version: "0.89.0".to_owned(),
            os_version: "26.1".to_owned(),
        },
        machine_id: machine(),
        account_file: dir.join("account.json"),
        callback_page: CallbackPage {
            finished: String::new(),
            unknown: String::new(),
        },
        legacy_entitlement_file: Some(dir.join("Account").join("entitlement.jwt")),
    }
}

pub(super) fn managed(base: &str, allow_others: Option<bool>) -> ServerSettings {
    ServerSettings::Resolved(ServerPolicy {
        managed_url: Some(base.to_owned()),
        allow_other_servers: allow_others,
        license_keys: LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
    })
}

pub(super) fn open(settings: AccountSettings, items: &Arc<Items>, browser: Arc<HeldBrowser>) -> Account {
    let hosts = AccountHosts {
        vaults: Arc::new(items.clone()),
        browser,
        web_authenticator: None,
    };
    Account::open(settings, hosts, watch::Sender::new(AccountStatus::SignedOut)).expect("an account")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_company_server_is_found_through_its_metadata_and_its_license_cuts_the_features() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let base = company(&LICENSED, |_, _, _, _| None);
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

    let status = account.status().borrow().clone();
    assert_eq!(status.features(Utc::now()), LICENSED);
    assert_eq!(
        status.feature_access("env_var_references", Utc::now()),
        FeatureAccess::NotIncluded
    );
    let server = account.server();
    assert_eq!(
        (server.api_origin.as_str(), server.account_origin.as_deref()),
        (base.as_str(), Some(base.as_str()))
    );
    assert!(server.is_managed && !server.others_allowed && !server.is_production);
    let file = stored(dir.path()).await;
    assert_eq!(file.server.as_deref(), Some(format!("{base}/v2").as_str()));
    assert!(file.license.is_some() && file.entitlement_keys.is_some() && file.trust_tag.is_some());
    assert!(!choice_file(&dir.path().join("account.json")).exists());
    let opened = browser.opened.lock().expect("the URL").clone().expect("the page");
    assert!(
        opened.as_str().starts_with(&format!("{base}/oauth/authorize")),
        "{opened}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_with_the_server_down_verifies_the_kept_license_and_keys() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let down = Arc::new(AtomicBool::new(false));
    let base = company(&LICENSED, {
        let down = down.clone();
        move |_, _, _, _| down.load(Ordering::SeqCst).then(|| (503, String::new()))
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    down.store(true, Ordering::SeqCst);

    let restarted = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        Arc::default(),
    );
    restarted.restore().await;

    assert_eq!(restarted.status().borrow().features(Utc::now()), LICENSED);
    assert!(restarted.server().is_managed && restarted.server().others_allowed);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_license_for_another_server_or_none_admits_no_entitlement() {
    for (license, code) in [
        (
            (
                200,
                license_answer("https://api.other.example", Utc::now(), TimeDelta::days(365), &LICENSED),
            ),
            "account.license_other_server",
        ),
        (
            (
                404,
                r#"{"type":"about:blank","title":"Not installed","status":404,"code":"license_not_installed"}"#
                    .to_owned(),
            ),
            "account.license_not_installed",
        ),
    ] {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let base = company(&LICENSED, move |_, method, path, _| {
            ((method, path) == ("GET", "/v2/license")).then(|| license.clone())
        });
        let items = Arc::new(Items::default());
        let browser = Arc::new(HeldBrowser::default());
        let account = open(
            settings(dir.path(), AppClient::LINUX, managed(&base, None)),
            &items,
            browser.clone(),
        );

        let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));

        assert_eq!(signed.expect_err("no entitlement").code(), code);
        let held = signed_in(&account);
        assert!(held.entitlement.is_none());
        assert!(matches!(&held.problem, Some(EntitlementProblem::RefreshFailed(error)) if error.code() == code));
        assert_eq!(
            account.status().borrow().feature_access("team_library", Utc::now()),
            FeatureAccess::RefreshFailed
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn past_the_license_s_grace_only_the_team_library_works() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let base = company(&LICENSED, |origin, method, path, _| {
        ((method, path) == ("GET", "/v2/license")).then(|| {
            let issued = Utc::now() - TimeDelta::days(365 + 31);
            (200, license_answer(origin, issued, TimeDelta::days(365), &LICENSED))
        })
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );

    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");

    let status = account.status().borrow().clone();
    assert_eq!(status.features(Utc::now()), ["team_library"]);
    assert_eq!(
        status.feature_access("team_library", Utc::now()),
        FeatureAccess::Available
    );
    assert_eq!(
        status.feature_access("service_sync", Utc::now()),
        FeatureAccess::Expired
    );
}

// A metadata document written for the stub's origin.
type Metadata = fn(&str) -> String;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn discovery_refuses_a_server_that_names_another_resource_issuer_or_key_origin() {
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("a client");
    let cases: [(&str, Metadata, &str); 5] = [
        (
            "/.well-known/openid-configuration",
            |origin| {
                format!(
                    r#"{{"issuer":"{origin}","authorization_endpoint":"https://account.tablepro.app/oauth/authorize","token_endpoint":"{origin}/oauth/token","revocation_endpoint":"{origin}/oauth/revoke"}}"#
                )
            },
            "account.server_mismatch",
        ),
        (
            "/.well-known/oauth-protected-resource",
            |origin| {
                format!(
                    r#"{{"resource":"{origin}","authorization_servers":["https://account.tablepro.app"],"jwks_uri":"{origin}/v2/entitlement-keys"}}"#
                )
            },
            "account.server_mismatch",
        ),
        (
            "/.well-known/oauth-protected-resource",
            |_| {
                r#"{"resource":"https://api.other.example","authorization_servers":["https://account.other.example"],"jwks_uri":"https://api.other.example/v2/entitlement-keys"}"#.to_owned()
            },
            "account.server_mismatch",
        ),
        (
            "/.well-known/openid-configuration",
            |origin| {
                format!(
                    r#"{{"issuer":"https://evil.example","authorization_endpoint":"{origin}/a","token_endpoint":"{origin}/t","revocation_endpoint":"{origin}/r"}}"#
                )
            },
            "account.server_mismatch",
        ),
        (
            "/.well-known/oauth-protected-resource",
            |origin| {
                format!(
                    r#"{{"resource":"{origin}","authorization_servers":["{origin}"],"jwks_uri":"https://keys.other.example/jwks"}}"#
                )
            },
            "account.server_mismatch",
        ),
    ];
    for (path, body, code) in cases {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        let origin = base.clone();
        let answering: Box<Answer> = Box::new(move |method: &str, asked: &str, _: &str| match asked == path {
            true => (200, "", body(&origin)),
            false => {
                let (status, body) = standard(&origin, &LICENSED, method, asked);
                (status, "", body)
            }
        });
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                serve(stream, answering.as_ref());
            }
        });

        let refused = server::discover(&http, &base, true).await.expect_err("refused");

        assert_eq!(refused.code(), code, "{path}: {refused}");
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_managed_server_that_allows_no_other_refuses_a_choice() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let items = Arc::new(Items::default());
    let account = open(
        settings(
            dir.path(),
            AppClient::MACOS,
            managed("https://127.0.0.1:1", Some(false)),
        ),
        &items,
        Arc::default(),
    );

    let refused = account.choose_server(Some("https://api.example.com")).await;
    let reset = account.choose_server(None).await;

    assert!(
        matches!(refused, Err(AccountError::Server(ServerError::Managed))),
        "{refused:?}"
    );
    assert!(
        matches!(reset, Err(AccountError::Server(ServerError::Managed))),
        "{reset:?}"
    );
    assert_eq!(account.server().api_origin, "https://127.0.0.1:1");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn choosing_another_server_signs_out_of_the_first_and_the_choice_is_kept() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let revoked = Asked::default();
    let first = company(&LICENSED, {
        let revoked = revoked.clone();
        move |_, method, path, body| {
            ((method, path) == ("POST", "/oauth/revoke")).then(|| {
                revoked
                    .lock()
                    .expect("the revocations")
                    .push(form(body).get("token").cloned().unwrap_or_default());
                (200, String::new())
            })
        }
    });
    let second = company(&LICENSED, |_, _, _, _| None);
    let policy = ServerSettings::Resolved(ServerPolicy {
        license_keys: LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
        ..ServerPolicy::default()
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, policy.clone()),
        &items,
        browser.clone(),
    );
    let mut sign_outs = account.sign_outs();
    account.choose_server(Some(&first)).await.expect("chosen");
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");

    account.choose_server(Some(&first)).await.expect("the same server");
    let kept = matches!(*account.status().borrow(), AccountStatus::SignedIn(_));
    account.choose_server(Some(&second)).await.expect("another server");

    assert!(kept, "choosing the same server keeps the sign-in");
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    assert_eq!(asked(&revoked), ["stub-refresh"]);
    assert_eq!(sign_outs.try_recv().ok(), Some(SignOutCause::ServerChanged));
    assert!(
        items
            .holding(&SignInKey::of(&format!("{first}/v2"), &dir.path().join("account.json")))
            .token
            .lock()
            .await
            .is_none()
    );
    let reopened = open(settings(dir.path(), AppClient::LINUX, policy), &items, Arc::default());
    assert_eq!(reopened.server().api_origin, second);
    account.choose_server(None).await.expect("back to tablepro.app");
    assert!(account.server().is_production);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn keys_another_process_wrote_into_the_account_file_admit_no_entitlement() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let down = Arc::new(AtomicBool::new(false));
    let base = company(&LICENSED, {
        let down = down.clone();
        move |_, _, _, _| down.load(Ordering::SeqCst).then(|| (503, String::new()))
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    down.store(true, Ordering::SeqCst);
    let mut file = stored(dir.path()).await;
    file.entitlement_keys = Some(format!(
        r#"{{"keys":[{{"kty":"OKP","crv":"Ed25519","x":"{}"}},{{"kty":"OKP","crv":"Ed25519","x":"TMI9PhVmgIiU5Mj0UVJZrKTkOakZvybK5l3aPFnhfC0"}}]}}"#,
        fakes::PUBLIC_X
    ));
    crate::account_file::write(&dir.path().join("account.json"), &file)
        .await
        .expect("the account file");

    let restarted = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        Arc::default(),
    );
    restarted.restore().await;

    assert!(signed_in(&restarted).entitlement.is_none());
    assert!(restarted.status().borrow().features(Utc::now()).is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_kept_discovery_never_says_where_a_refresh_token_goes() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let base = company(&LICENSED, |_, _, _, _| Some((503, String::new())));
    let stolen = Asked::default();
    let elsewhere = company(&LICENSED, {
        let stolen = stolen.clone();
        move |_, method, path, body| {
            stolen
                .lock()
                .expect("the requests")
                .push(format!("{method} {path} {body}"));
            Some((200, TOKENS.to_owned()))
        }
    });
    let account_file = dir.path().join("account.json");
    std::fs::write(
        choice_file(&account_file),
        format!(
            r#"{{"version":1,"chosen":"{base}","discovered":{{"resource":"{base}","issuer":"{elsewhere}","authorization_endpoint":"{elsewhere}/oauth/authorize","token_endpoint":"{elsewhere}/oauth/token","revocation_endpoint":"{elsewhere}/oauth/revoke","jwks_uri":"{base}/v2/entitlement-keys"}}}}"#
        ),
    )
    .expect("the choice");
    let kept = crate::account_file::AccountFile {
        device_id: Some(DEVICE.to_owned()),
        server: Some(format!("{base}/v2")),
        ..crate::account_file::AccountFile::default()
    };
    crate::account_file::write(&account_file, &kept)
        .await
        .expect("the account file");
    let items = Arc::new(Items::default());
    *items
        .holding(&SignInKey::of(&format!("{base}/v2"), &account_file))
        .token
        .lock()
        .await = Some(secrecy::SecretString::from("kept-refresh"));
    let policy = ServerSettings::Resolved(ServerPolicy {
        license_keys: LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
        ..ServerPolicy::default()
    });
    let account = open(settings(dir.path(), AppClient::LINUX, policy), &items, Arc::default());

    account.restore().await;
    let refreshed = account.refresh_entitlement().await;

    assert!(refreshed.is_err(), "{refreshed:?}");
    assert_eq!(account.server().api_origin, base);
    assert!(asked(&stolen).is_empty(), "{:?}", asked(&stolen));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_license_that_drops_a_feature_applies_before_the_next_entitlement_comes() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let narrowed = Arc::new(AtomicBool::new(false));
    let base = company(&LICENSED, {
        let narrowed = narrowed.clone();
        move |origin, method, path, _| {
            if !narrowed.load(Ordering::SeqCst) {
                return None;
            }
            match (method, path) {
                ("GET", "/v2/license") => Some((
                    200,
                    license_answer(origin, Utc::now(), TimeDelta::days(365), &["team_library"]),
                )),
                ("POST", p) if p.ends_with("/entitlement") => Some((500, String::new())),
                _ => None,
            }
        }
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    narrowed.store(true, Ordering::SeqCst);

    let failed = account.refresh_entitlement().await;

    assert!(failed.is_err(), "{failed:?}");
    assert_eq!(account.status().borrow().features(Utc::now()), ["team_library"]);
    let kept = stored(dir.path()).await.license.expect("the license");
    let license = crate::license::License::verify(
        &kept,
        &LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
        &base,
        Utc::now(),
    )
    .expect("the kept license");
    assert_eq!(license.claims().features, ["team_library"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_license_that_drops_a_feature_applies_even_when_the_keys_then_fail_to_load() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let narrowed = Arc::new(AtomicBool::new(false));
    let base = company(&LICENSED, {
        let narrowed = narrowed.clone();
        move |origin, method, path, _| {
            if !narrowed.load(Ordering::SeqCst) {
                return None;
            }
            match (method, path) {
                ("GET", "/v2/license") => Some((
                    200,
                    license_answer(origin, Utc::now(), TimeDelta::days(365), &["team_library"]),
                )),
                ("GET", "/v2/entitlement-keys") => Some((503, String::new())),
                _ => None,
            }
        }
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    narrowed.store(true, Ordering::SeqCst);

    let failed = account.refresh_entitlement().await;

    assert!(failed.is_err(), "{failed:?}");
    assert_eq!(account.status().borrow().features(Utc::now()), ["team_library"]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_app_with_one_token_item_signs_in_to_its_fixed_server_whatever_a_choice_file_says() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    std::fs::write(
        choice_file(&dir.path().join("account.json")),
        r#"{"version":1,"chosen":"https://api.evil.example"}"#,
    )
    .expect("the choice");
    let keyring = Keyring::holding(Some("production-refresh"));
    let fixed = settings(dir.path(), AppClient::LINUX, ServerSettings::production());
    let resolved = settings(
        dir.path(),
        AppClient::LINUX,
        ServerSettings::Resolved(ServerPolicy::default()),
    );

    let account = Account::new(
        fixed,
        keyring.clone(),
        Arc::new(HeldBrowser::default()),
        watch::Sender::new(AccountStatus::SignedOut),
    )
    .expect("an account");
    let refused = Account::new(
        resolved,
        keyring,
        Arc::new(HeldBrowser::default()),
        watch::Sender::new(AccountStatus::SignedOut),
    );

    assert!(account.server().is_production);
    assert_eq!(account.server().api_origin, "https://api.tablepro.app");
    assert!(matches!(refused, Err(AccountError::Protocol(_))));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn leaving_a_server_found_offline_at_launch_still_revokes_its_sign_in() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let down = Arc::new(AtomicBool::new(false));
    let revoked = Asked::default();
    let first = company(&LICENSED, {
        let (down, revoked) = (down.clone(), revoked.clone());
        move |_, method, path, body| {
            if down.load(Ordering::SeqCst) {
                return Some((503, String::new()));
            }
            ((method, path) == ("POST", "/oauth/revoke")).then(|| {
                revoked
                    .lock()
                    .expect("the revocations")
                    .push(form(body).get("token").cloned().unwrap_or_default());
                (200, String::new())
            })
        }
    });
    let second = company(&LICENSED, |_, _, _, _| None);
    let policy = ServerSettings::Resolved(ServerPolicy {
        license_keys: LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
        ..ServerPolicy::default()
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, policy.clone()),
        &items,
        browser.clone(),
    );
    account.choose_server(Some(&first)).await.expect("chosen");
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    down.store(true, Ordering::SeqCst);
    let restarted = open(settings(dir.path(), AppClient::LINUX, policy), &items, Arc::default());
    restarted.restore().await;
    down.store(false, Ordering::SeqCst);

    restarted.choose_server(Some(&second)).await.expect("another server");

    assert_eq!(asked(&revoked), ["stub-refresh"]);
    assert!(matches!(*restarted.status().borrow(), AccountStatus::SignedOut));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_shared_link_is_read_from_tablepro_app_whatever_company_server_is_signed_in() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let items = Arc::new(Items::default());
    let at_company = open(
        settings(dir.path(), AppClient::LINUX, managed("https://127.0.0.1:1", None)),
        &items,
        Arc::default(),
    );
    let at_stack = super::tests::unreachable();

    let company_api = at_company.shared_links_api();
    let stack_api = open(
        AccountSettings {
            server: ServerSettings::Fixed(crate::server::FixedServer {
                endpoints: at_stack,
                keys: fakes::keys().expect("the test key"),
                issuer: fakes::ISSUER.to_owned(),
            }),
            ..settings(dir.path(), AppClient::LINUX, ServerSettings::production())
        },
        &items,
        Arc::default(),
    )
    .shared_links_api();

    assert_eq!(company_api, "https://api.tablepro.app/v2");
    assert_eq!(stack_api, "http://127.0.0.1:1/v2");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restore_asks_the_company_server_nothing_and_a_429_on_discovery_holds_the_next_try() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let limited = Arc::new(AtomicBool::new(false));
    let requests = Asked::default();
    let base = company(&LICENSED, {
        let (limited, requests) = (limited.clone(), requests.clone());
        move |_, method, path, _| {
            if !limited.load(Ordering::SeqCst) {
                return None;
            }
            requests.lock().expect("the requests").push(format!("{method} {path}"));
            Some((429, String::new()))
        }
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    limited.store(true, Ordering::SeqCst);
    let restarted = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        Arc::default(),
    );

    restarted.restore().await;
    let restored = asked(&requests).len();
    let first = restarted.refresh_entitlement().await;
    let second = restarted.refresh_entitlement().await;

    assert_eq!(restored, 0);
    assert_eq!(restarted.status().borrow().features(Utc::now()), LICENSED);
    assert!(matches!(first, Err(AccountError::RateLimited { .. })), "{first:?}");
    assert!(matches!(second, Err(AccountError::RateLimited { .. })), "{second:?}");
    assert_eq!(asked(&requests).len(), 1, "{:?}", asked(&requests));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_busy_candidate_server_holds_back_no_other_choice() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let busy = company(&LICENSED, |_, _, _, _| Some((429, String::new())));
    let healthy = company(&LICENSED, |_, _, _, _| None);
    let policy = ServerSettings::Resolved(ServerPolicy {
        license_keys: LicenseKeys::from_public_keys([fakes::PUBLIC_X]).expect("the test key"),
        ..ServerPolicy::default()
    });
    let account = open(
        settings(dir.path(), AppClient::LINUX, policy),
        &Arc::new(Items::default()),
        Arc::default(),
    );

    let refused = account.choose_server(Some(&busy)).await;
    let chosen = account.choose_server(Some(&healthy)).await;

    assert!(matches!(refused, Err(AccountError::RateLimited { .. })), "{refused:?}");
    assert!(chosen.is_ok(), "{chosen:?}");
    assert_eq!(account.server().api_origin, healthy);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_verified_license_shows_when_the_entitlement_after_it_fails() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let base = company(&LICENSED, |_, method, path, _| {
        (method == "POST" && path.ends_with("/entitlement")).then(|| (500, String::new()))
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );

    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));

    assert!(signed.is_err(), "{signed:?}");
    assert!(signed_in(&account).entitlement.is_none());
    let license = account.license().expect("the verified license");
    assert_eq!(license.claims().features, LICENSED);
    account.sign_out().await.expect("signed out");
    assert!(account.license().is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_server_that_borrows_another_install_s_account_server_never_gets_its_tokens() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let reached = Asked::default();
    let genuine = company(&LICENSED, |_, _, _, _| None);
    let borrowed = genuine.clone();
    let rogue = company(&LICENSED, {
        let reached = reached.clone();
        move |origin, method, path, _| {
            reached.lock().expect("the requests").push(format!("{method} {path}"));
            match path {
                "/.well-known/oauth-protected-resource" => Some((
                    200,
                    format!(
                        r#"{{"resource":"{origin}","authorization_servers":["{borrowed}"],"jwks_uri":"{origin}/v2/entitlement-keys"}}"#
                    ),
                )),
                _ => None,
            }
        }
    });
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&rogue, None)),
        &Arc::new(Items::default()),
        browser.clone(),
    );

    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));

    assert_eq!(signed.expect_err("refused").code(), "account.server_mismatch");
    assert_eq!(asked(&reached), ["GET /.well-known/oauth-protected-resource"]);
    assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refresh_token_goes_to_no_issuer_but_the_one_that_gave_it() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let swapped = Arc::new(AtomicBool::new(false));
    let stolen = Asked::default();
    let thief = company(&LICENSED, {
        let stolen = stolen.clone();
        move |origin, method, path, body| {
            stolen
                .lock()
                .expect("the requests")
                .push(format!("{method} {path} {body}"));
            (!path.starts_with("/.well-known/")).then(|| (200, tokens_for(origin)))
        }
    });
    let base = company(&LICENSED, {
        let (swapped, thief) = (swapped.clone(), thief.clone());
        move |origin, _, path, _| {
            (swapped.load(Ordering::SeqCst) && path == "/.well-known/oauth-protected-resource").then(|| {
                (
                    200,
                    format!(
                        r#"{{"resource":"{origin}","authorization_servers":["{thief}"],"jwks_uri":"{origin}/v2/entitlement-keys"}}"#
                    ),
                )
            })
        }
    });
    let items = Arc::new(Items::default());
    let browser = Arc::new(HeldBrowser::default());
    let account = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        browser.clone(),
    );
    let (signed, ()) = tokio::join!(account.sign_in(std::future::pending()), approve(&browser));
    signed.expect("signed in");
    swapped.store(true, Ordering::SeqCst);
    let restarted = open(
        settings(dir.path(), AppClient::LINUX, managed(&base, None)),
        &items,
        Arc::default(),
    );
    restarted.restore().await;

    let refreshed = restarted.refresh_entitlement().await;
    let signed_out = restarted.sign_out().await;

    assert_eq!(refreshed.expect_err("refused").code(), "account.server_mismatch");
    assert!(signed_out.is_err(), "{signed_out:?}");
    assert!(
        asked(&stolen).iter().all(|request| !request.contains("stub-refresh")),
        "{:?}",
        asked(&stolen)
    );
}
