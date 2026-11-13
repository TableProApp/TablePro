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
const TOKEN: &str = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";
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
    fn open_url(&self, url: String) -> Result<(), HostBrowserError> {
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_shared_link_opens_signed_out_and_the_owner_s_calls_do_not() {
    let path = format!("/v2/shared/{TOKEN}");
    let base = cloud(move |method, requested, _| match (method, requested) {
        ("GET", p) if p == path => (
            200,
            r#"{"kind":"query","title":"Orders","note":"","dialect":"postgres","sql":"SELECT 1",
            "created_at":"2026-11-13T00:00:00Z","allow_download":true,"made_with":"TablePro"}"#
                .to_owned(),
        ),
        _ => (404, String::new()),
    });
    let opened = open(&base).await;

    let shared = opened.service.fetch_shared(TOKEN.to_owned(), None).await.unwrap();
    let limits = opened.service.share_limits().await;
    let malformed = opened.service.fetch_shared("short".to_owned(), None).await;

    assert_eq!(shared.sql.as_deref(), Some("SELECT 1"));
    assert_eq!((shared.row_count, shared.expires_at_secs), (None, None));
    assert_eq!(limits.unwrap_err().code(), "account.signed_out");
    assert_eq!(malformed.unwrap_err().code(), "account.not_found");
}

#[cfg(feature = "engines")]
mod shares {
    use std::path::Path;

    use tablepro_ffi::{
        DatabaseSession, FileOpenRequest, ResultSet, RunListener, RunOutcome, RunSettings, ShareKindTag,
        ShareRequestArg, TableName,
    };

    use super::*;

    struct Quiet;

    impl RunListener for Quiet {
        fn events_pending(&self) {}
    }

    async fn run(session: &DatabaseSession, sql: &str) -> Option<Arc<ResultSet>> {
        let editor = session.open_editor(None).await.unwrap();
        let run = editor.run(sql.to_owned(), RunSettings::default(), false, Box::new(Quiet));
        let outcome = run.outcome().await.unwrap();
        assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
        let set = run.result_set(0);
        editor.close().await.unwrap();
        set
    }

    // Signed in against a stub cloud that keeps every create's body.
    async fn signed_in(bodies: &Arc<Mutex<Vec<String>>>) -> Opened {
        let base = cloud({
            let bodies = bodies.clone();
            let device = device_answer();
            let entitlement = entitlement_answer();
            let created = created();
            move |method, path, body| match (method, path) {
                ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                ("POST", "/v2/devices") => (201, device.clone()),
                ("POST", p) if p == format!("/v2/devices/{DEVICE}/entitlement") => (200, entitlement.clone()),
                ("POST", "/v2/shares") => {
                    bodies.lock().unwrap().push(body.to_owned());
                    (201, created.clone())
                }
                _ => (404, String::new()),
            }
        });
        let opened = open(&base).await;
        let (signed_in, ()) = tokio::join!(opened.service.sign_in(None), approve(&opened.browser));
        signed_in.unwrap();
        opened
    }

    async fn sqlite(dir: &Path) -> (Arc<Core>, Arc<DatabaseSession>) {
        let core = Core::new(
            HostConfig {
                client_version: "test".to_owned(),
                storage_dir: None,
            },
            Box::new(MemorySecrets::default()),
        )
        .unwrap();
        let file = FileOpenRequest {
            path: dir.join("shop.sqlite").display().to_string(),
            driver_id: None,
            read_only: false,
            create: true,
        };
        let session = core.open_file(file, None).await.unwrap();
        (core, session)
    }

    fn created() -> String {
        format!(
            r#"{{"share":{{"id":"shr_01","kind":"result","scope":"account","title":"Orders","note":"","dialect":"sqlite",
            "has_snapshot":true,"row_count":2,"truncated":true,"hide_sql":true,"allow_download":true,"has_password":false,
            "state":"live","suspended":false,"view_count":0,"created_at":"2026-11-13T00:00:00Z","updated_at":"2026-11-13T00:00:00Z",
            "expires_at":"2026-12-13T00:00:00Z","url":"https://s.tablepro.app/{TOKEN}"}},
            "token":"{TOKEN}","url":"https://s.tablepro.app/{TOKEN}"}}"#
        )
    }

    fn request(kind: ShareKindTag) -> ShareRequestArg {
        ShareRequestArg {
            kind,
            sql: "SELECT * FROM orders".to_owned(),
            title: Some("Orders".to_owned()),
            note: None,
            dialect: Some("sqlite".to_owned()),
            expiry: None,
            hide_sql: kind == ShareKindTag::Result,
            allow_download: None,
            password: None,
            team_id: None,
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_result_share_sends_the_visible_columns_and_the_plan_s_rows() {
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let opened = signed_in(&bodies).await;
        let dir = tempfile::tempdir().unwrap();
        let (_core, session) = sqlite(dir.path()).await;
        let set = run(
            &session,
            "SELECT 9007199254740993 AS big, 'a' AS name, x'cafe' AS hidden UNION ALL SELECT 2, 'b', NULL",
        )
        .await
        .unwrap();

        let shared = opened
            .service
            .create_share(request(ShareKindTag::Result), Some(set), 2, 1, None, Vec::new())
            .await
            .unwrap();
        let team_query = ShareRequestArg {
            team_id: Some("team_01".to_owned()),
            ..request(ShareKindTag::Query)
        };
        let query = opened
            .service
            .create_share(team_query, None, 0, 0, None, Vec::new())
            .await
            .unwrap();
        let needs_set = opened
            .service
            .create_share(request(ShareKindTag::Result), None, 0, 1_000, None, Vec::new())
            .await;

        assert_eq!(shared.url, format!("https://s.tablepro.app/{TOKEN}"));
        assert_eq!(shared.share.row_count, Some(2));
        assert_eq!(shared.share.expires_at_secs, Some(1_797_120_000));
        assert_eq!(query.share.id, "shr_01");
        assert_eq!(needs_set.unwrap_err().code(), "ffi.share_needs_result");
        let bodies = bodies.lock().unwrap();
        assert!(
            bodies[0].contains(r#""rows":[[9007199254740993,"a"]]"#),
            "{}",
            bodies[0]
        );
        assert!(bodies[0].contains(r#""row_count":2"#), "{}", bodies[0]);
        assert!(!bodies[0].contains("hidden"), "{}", bodies[0]);
        assert!(bodies[0].contains(r#""hide_sql":true"#), "{}", bodies[0]);
        assert!(!bodies[1].contains("snapshot"), "{}", bodies[1]);
        assert!(bodies[1].contains(r#""team_id":"team_01""#), "{}", bodies[1]);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_table_page_shares_its_view_sql_its_visible_columns_and_the_view_s_count() {
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let opened = signed_in(&bodies).await;
        let dir = tempfile::tempdir().unwrap();
        let (_core, session) = sqlite(dir.path()).await;
        run(
            &session,
            "CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('first'), ('second'), ('third')",
        )
        .await;
        let notes = TableName {
            schema: None,
            name: "notes".to_owned(),
        };
        let page = session
            .read_table_page(notes.clone(), None, None, 2, 0, false, Box::new(Quiet), None)
            .await
            .unwrap();
        let outcome = page.run().outcome().await.unwrap();
        let total = session.table_row_count(notes, None, None).await.unwrap();
        let set = page.run().result_set(0).unwrap();

        let shared = ShareRequestArg {
            sql: page.view_sql().unwrap(),
            ..request(ShareKindTag::Result)
        };
        opened
            .service
            .create_share(
                shared,
                Some(set),
                page.visible_columns(),
                1_000,
                Some(total),
                Vec::new(),
            )
            .await
            .unwrap();

        assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
        assert_eq!(page.visible_columns(), 1, "the page also reads each row's rowid");
        let body = bodies.lock().unwrap()[0].clone();
        assert!(
            body.contains(r#""sql":"SELECT \"body\" FROM \"notes\" ORDER BY \"rowid\" ASC""#),
            "{body}"
        );
        assert!(body.contains(r#""columns":[{"name":"body","type":"TEXT"}]"#), "{body}");
        assert!(body.contains(r#""rows":[["first"],["second"]]"#), "{body}");
        assert!(body.contains(r#""row_count":3"#), "{body}");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_result_past_the_column_cap_shares_its_first_columns_and_says_so() {
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let opened = signed_in(&bodies).await;
        let dir = tempfile::tempdir().unwrap();
        let (_core, session) = sqlite(dir.path()).await;
        let wide: Vec<String> = (0..101).map(|index| format!("{index} AS c{index}")).collect();
        let set = run(&session, &format!("SELECT {}", wide.join(", "))).await.unwrap();

        let created = opened
            .service
            .create_share(request(ShareKindTag::Result), Some(set), 101, 1_000, None, Vec::new())
            .await
            .unwrap();

        assert!(created.columns_truncated);
        let body = bodies.lock().unwrap()[0].clone();
        assert!(body.contains(r#""name":"c99""#), "{body}");
        assert!(!body.contains(r#""c100""#), "{body}");
    }
}
