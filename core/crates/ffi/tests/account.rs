#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::io::{BufRead as _, Read as _, Write as _};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{TimeDelta, Utc};
use secrecy::{ExposeSecret as _, SecretString};
use tablepro_account::{MachineId, fakes};
use tablepro_ffi::{
    AccountConfig, AccountListener, AccountService, AccountStateTag, CancelToken, Core, CoreError, FeatureAccessTag,
    HostBrowser, HostBrowserError, HostConfig, HostSecretError, HostSecrets, SecretItemTag, SecretKindTag,
};

const GUID: &str = "d3b07384-d113-4ec6-a2f1-6a3f0c2e9b7a";
const DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4ww4";
const TOKENS: &str =
    r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900,"refresh_token":"stub-refresh"}"#;

type Items = Arc<Mutex<HashMap<SecretItemTag, SecretString>>>;

#[derive(Default)]
struct MemorySecrets(Items);

impl HostSecrets for MemorySecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, item: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(self.0.lock().unwrap().get(&item).cloned())
    }

    fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().insert(item, secret);
        Ok(())
    }

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError> {
        self.0.lock().unwrap().remove(&item);
        Ok(())
    }
}

#[derive(Default)]
struct Counting(Arc<AtomicUsize>);

impl AccountListener for Counting {
    fn status_changed(&self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

// Keeps the sign-in page's URL for the test to answer.
#[derive(Default)]
struct Browser(Arc<Mutex<Option<String>>>);

impl HostBrowser for Browser {
    fn open(&self, url: String) -> Result<(), HostBrowserError> {
        *self.0.lock().unwrap() = Some(url);
        Ok(())
    }
}

struct Opened {
    service: Arc<AccountService>,
    items: Items,
    changes: Arc<AtomicUsize>,
    browser: Arc<Mutex<Option<String>>>,
    _dir: tempfile::TempDir,
}

async fn open(base: &str) -> Opened {
    let dir = tempfile::tempdir().unwrap();
    let items = Items::default();
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(MemorySecrets(items.clone())),
    )
    .unwrap();
    let changes = Arc::new(AtomicUsize::new(0));
    let browser = Arc::new(Mutex::new(None));
    let config = AccountConfig {
        account_url: Some(base.to_owned()),
        api_url: Some(format!("{base}/v2")),
        entitlement_keys: vec![fakes::PUBLIC_X.to_owned()],
        device_name: "Lab".to_owned(),
        app_version: "1.0.0".to_owned(),
        os_version: "Windows 11".to_owned(),
        account_file: dir.path().join("account.json").display().to_string(),
        callback_finished: "Done".to_owned(),
        callback_unknown: "Unknown".to_owned(),
        machine_guid: Some(GUID.to_owned()),
    };
    let service = core
        .open_account(
            config,
            Box::new(Browser(browser.clone())),
            Box::new(Counting(changes.clone())),
        )
        .await
        .unwrap();
    Opened {
        service,
        items,
        changes,
        browser,
        _dir: dir,
    }
}

// Nothing listens once the listener is dropped, so every request is refused.
fn unreachable() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    format!("http://{}", listener.local_addr().unwrap())
}

// Stands in for tablepro-cloud: `answer` gives the status and body for a method, path and request body.
fn cloud(answer: impl Fn(&str, &str, &str) -> (u16, String) + Send + 'static) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            serve(stream, &answer);
        }
    });
    base
}

fn serve(stream: TcpStream, answer: &dyn Fn(&str, &str, &str) -> (u16, String)) {
    let mut reader = std::io::BufReader::new(stream.try_clone().unwrap());
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let mut words = line.split_whitespace();
    let (method, path) = (words.next().unwrap_or_default(), words.next().unwrap_or_default());
    let mut length = 0;
    loop {
        let mut header = String::new();
        reader.read_line(&mut header).unwrap();
        if header.trim().is_empty() {
            break;
        }
        if let Some(value) = header.to_ascii_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse().unwrap();
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    let (status, body) = answer(method, path, &String::from_utf8_lossy(&body));
    let mut stream = stream;
    write!(
        stream,
        "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
    .unwrap();
}

async fn eventually(what: &str, done: impl Fn() -> bool) {
    for _ in 0..500 {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(done(), "{what} did not happen");
}

// What the browser does once the user approves: the redirect to the app's loopback listener.
async fn approve(browser: &Arc<Mutex<Option<String>>>) {
    eventually("the sign-in page opening", || browser.lock().unwrap().is_some()).await;
    let opened = browser.lock().unwrap().clone().unwrap();
    let url = tablepro_account::Url::parse(&opened).unwrap();
    let asked = |name: &str| {
        url.query_pairs()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.into_owned())
            .unwrap()
    };
    let mut redirect = tablepro_account::Url::parse(&asked("redirect_uri")).unwrap();
    redirect
        .query_pairs_mut()
        .append_pair("code", "stub-code")
        .append_pair("state", &asked("state"));
    let address = format!("{}:{}", redirect.host_str().unwrap(), redirect.port().unwrap());
    let target = format!("{}?{}", redirect.path(), redirect.query().unwrap());
    // Blocking is fine here: the listener answers on the core's own runtime.
    let mut stream = TcpStream::connect(address).unwrap();
    write!(
        stream,
        "GET {target} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: close\r\n\r\n"
    )
    .unwrap();
    let mut answer = String::new();
    let _ = stream.read_to_string(&mut answer);
}

fn entitlement_answer() -> String {
    let mut claims = fakes::claims(Utc::now(), TimeDelta::days(14), &["shared_links"]);
    claims.mid = MachineId::derive_machine_guid(GUID).unwrap().as_str().to_owned();
    claims.dev = DEVICE.to_owned();
    format!(
        r#"{{"token":"{}","expires_at":"2026-12-01T00:00:00Z","refresh_after":"2026-11-20T00:00:00Z"}}"#,
        fakes::sign(&claims).unwrap()
    )
}

fn device_answer() -> String {
    format!(
        r#"{{"id":"{DEVICE}","machine_id":"{}","platform":"windows","name":"Lab","app_version":"1.0.0","os_version":"Windows 11","created_at":"2026-11-13T00:00:00Z","last_seen_at":"2026-11-13T00:00:00Z"}}"#,
        MachineId::derive_machine_guid(GUID).unwrap().as_str()
    )
}

fn refresh_token(items: &Items) -> Option<String> {
    items
        .lock()
        .unwrap()
        .get(&SecretItemTag::AccountRefreshToken)
        .map(|token| token.expose_secret().to_owned())
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_machine_starts_signed_out_and_the_app_is_told() {
    let opened = open(&unreachable()).await;

    eventually("the first status change", || opened.changes.load(Ordering::SeqCst) > 0).await;
    let profile = opened.service.profile().await;

    assert_eq!(opened.service.status().state, AccountStateTag::SignedOut);
    assert_eq!(
        opened.service.feature_access("shared_links".to_owned()),
        FeatureAccessTag::SignedOut
    );
    assert_eq!(profile.unwrap_err().code(), "account.signed_out");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sign_in_through_the_browser_registers_the_device_and_unlocks_its_features() {
    let requests = Arc::new(Mutex::new(Vec::new()));
    let base = cloud({
        let requests = requests.clone();
        let device = device_answer();
        let entitlement = entitlement_answer();
        move |method, path, _| {
            requests.lock().unwrap().push(format!("{method} {path}"));
            match (method, path) {
                ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                ("POST", "/oauth/revoke") => (200, String::new()),
                ("POST", "/v2/devices") => (201, device.clone()),
                ("POST", p) if p == format!("/v2/devices/{DEVICE}/entitlement") => (200, entitlement.clone()),
                _ => (404, String::new()),
            }
        }
    });
    let opened = open(&base).await;

    let (signed_in, ()) = tokio::join!(opened.service.sign_in(None), approve(&opened.browser));
    signed_in.unwrap();
    let status = opened.service.status();
    let kept = refresh_token(&opened.items);
    opened.service.sign_out().await.unwrap();

    assert_eq!(status.state, AccountStateTag::SignedIn);
    assert_eq!(status.features, ["shared_links"]);
    assert!(status.remembered);
    assert_eq!(kept.as_deref(), Some("stub-refresh"));
    assert_eq!(opened.service.status().state, AccountStateTag::SignedOut);
    assert_eq!(refresh_token(&opened.items), None);
    let requests = requests.lock().unwrap().clone();
    assert!(requests.contains(&"POST /v2/devices".to_owned()), "{requests:?}");
    assert!(requests.contains(&"POST /oauth/revoke".to_owned()), "{requests:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_cancel_ends_the_wait_for_the_browser() {
    let opened = open(&unreachable()).await;
    let cancel = CancelToken::new();
    let cancelling = async {
        eventually("the sign-in page opening", || opened.browser.lock().unwrap().is_some()).await;
        cancel.cancel();
    };

    let (ended, ()) = tokio::join!(opened.service.sign_in(Some(cancel.clone())), cancelling);

    assert_eq!(ended, Err(CoreError::Cancelled));
    assert_eq!(opened.service.status().state, AccountStateTag::SignedOut);
}
