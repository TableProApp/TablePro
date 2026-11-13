use std::num::NonZeroU64;

use progenitor_client::{Error, ResponseValue};
use secrecy::{ExposeSecret as _, SecretString};

use super::{Account, Call, Session};
use crate::account_error::AccountError;
use crate::cloud_api::{Bearer, answer_error, v2};
use crate::share::{CreatedShare, Share, ShareExpiry, ShareLimits, SharePage, ShareRequest, SharedLink, SnapshotBody};
use crate::share_link::is_share_token;

const SHARE_PAGE: NonZeroU64 = NonZeroU64::MIN.saturating_add(99);
// The document's maxLength for each, in characters; a longer title, note or dialect is cut rather than refused.
const TITLE_CHARACTERS: usize = 200;
const NOTE_CHARACTERS: usize = 2_000;
const DIALECT_CHARACTERS: usize = 40;

impl Account {
    // What the plan allows and how many live links the account holds, for the share sheet.
    pub async fn share_limits(&self) -> Result<ShareLimits, AccountError> {
        self.share_call(Call::Share, async |api| {
            answer(api.get_share_limits().await).await.map(ShareLimits::from)
        })
        .await
    }

    // The URL is the link to copy. A result's snapshot must already be cut to the plan's `max_rows`.
    pub async fn create_share(&self, request: ShareRequest) -> Result<CreatedShare, AccountError> {
        let body = create_body(request)?;
        let created = self
            .share_call(Call::ShareCreate, async |api| {
                answer(api.create_share(&body).await).await.map(CreatedShare::from)
            })
            .await?;
        tracing::info!(kind = %created.share.kind, "created a shared link");
        Ok(created)
    }

    // The account's own links, newest first, without their SQL. `live_only` leaves out expired, revoked and removed.
    pub async fn list_shares(&self, live_only: bool, cursor: Option<&str>) -> Result<SharePage, AccountError> {
        let state = list_state(live_only)?;
        let cursor: Option<v2::types::ListSharesCursor> = cursor
            .map(|cursor| limited(cursor.to_owned(), "not a cursor the server gave"))
            .transpose()?;
        self.share_call(Call::Share, async |api| {
            answer(
                api.list_shares(cursor.as_ref(), Some(SHARE_PAGE), Some(state), None)
                    .await,
            )
            .await
            .map(SharePage::from)
        })
        .await
    }

    // The link stops working at once; revoking it again changes nothing.
    pub async fn revoke_share(&self, share_id: &str) -> Result<(), AccountError> {
        let share_id: v2::types::DeleteShareShareId = known(share_id)?;
        self.share_call(Call::Share, async |api| answer(api.delete_share(&share_id).await).await)
            .await?;
        tracing::info!("revoked a shared link");
        Ok(())
    }

    // A new expiry counted from now, which also revives an expired link while a live slot is free.
    pub async fn extend_share(&self, share_id: &str, expiry: ShareExpiry) -> Result<Share, AccountError> {
        let share_id: v2::types::UpdateShareShareId = known(share_id)?;
        let body = v2::types::UpdateShareBody {
            expiry: Some(wire(expiry.code())?),
            ..Default::default()
        };
        self.share_call(Call::Share, async |api| {
            answer(api.update_share(&share_id, &body).await).await.map(Share::from)
        })
        .await
    }

    // Public: no session and no token, so anyone with a link reads it, signed in or not.
    pub async fn fetch_shared(&self, token: &str, password: Option<&SecretString>) -> Result<SharedLink, AccountError> {
        if !is_share_token(token) {
            return Err(not_found("not a share token"));
        }
        let api = self.api(Bearer(None));
        let password = password.map(|password| password.expose_secret());
        answer(api.get_shared(token, password).await)
            .await
            .map(SharedLink::from)
    }

    // Each call holds the session, waits out its 429, takes the bearer and ends the session on a refused sign-in.
    async fn share_call<T>(
        &self,
        call: Call,
        request: impl AsyncFnOnce(v2::Client) -> Result<T, AccountError>,
    ) -> Result<T, AccountError> {
        let mut session = self.inner.session.lock().await;
        let answered = self.share_answer(&mut session, call, request).await;
        self.ended_by(&mut session, answered).await
    }

    async fn share_answer<T>(
        &self,
        session: &mut Session,
        call: Call,
        request: impl AsyncFnOnce(v2::Client) -> Result<T, AccountError>,
    ) -> Result<T, AccountError> {
        session.waited(call)?;
        let api = self.api(self.bearer(session, false).await?);
        let answer = request(api).await;
        session.answered(call, answer)
    }
}

async fn answer<T>(sent: Result<ResponseValue<T>, Error<v2::types::Problem>>) -> Result<T, AccountError> {
    match sent {
        Ok(answer) => Ok(answer.into_inner()),
        Err(error) => Err(answer_error(error).await),
    }
}

fn create_body(request: ShareRequest) -> Result<v2::types::CreateShareBody, AccountError> {
    Ok(v2::types::CreateShareBody {
        kind: wire(request.kind.code())?,
        sql: limited(request.sql, "the SQL is longer than the server takes")?,
        title: cut(request.title, TITLE_CHARACTERS)?,
        note: cut(request.note, NOTE_CHARACTERS)?,
        dialect: cut(request.dialect, DIALECT_CHARACTERS)?,
        expiry: request.expiry.map(|expiry| wire(expiry.code())).transpose()?,
        hide_sql: request.hide_sql.then_some(true),
        allow_download: request.allow_download,
        password: request
            .password
            .map(|password| limited(password.expose_secret().to_owned(), "the password is too long"))
            .transpose()?,
        team_id: request.team_id.map(|team| limited(team, "not a team ID")).transpose()?,
        snapshot: request.snapshot.map(SnapshotBody::from),
    })
}

fn list_state(live_only: bool) -> Result<v2::types::ShareListState, AccountError> {
    wire(if live_only { "live" } else { "all" })
}

// A value of one of the document's string enums, by its wire spelling.
fn wire<T: std::str::FromStr>(code: &str) -> Result<T, AccountError> {
    code.parse()
        .map_err(|_| AccountError::Protocol(format!("{code:?} is not in the /v2 document")))
}

// The document's own check, such as a maxLength, answered as the server would answer it.
fn limited<T: TryFrom<String>>(text: String, detail: &str) -> Result<T, AccountError> {
    T::try_from(text).map_err(|_| invalid(detail))
}

fn cut<T: TryFrom<String>>(text: Option<String>, characters: usize) -> Result<Option<T>, AccountError> {
    let Some(text) = text.map(|text| text.trim().chars().take(characters).collect::<String>()) else {
        return Ok(None);
    };
    if text.is_empty() {
        return Ok(None);
    }
    limited(text, "a field is longer than the server takes").map(Some)
}

// An ID longer than the document allows names no share the server holds.
fn known<T: TryFrom<String>>(share_id: &str) -> Result<T, AccountError> {
    T::try_from(share_id.to_owned()).map_err(|_| not_found("not a share ID"))
}

fn not_found(detail: &str) -> AccountError {
    AccountError::Refused {
        status: 404,
        code: "not_found".to_owned(),
        detail: detail.to_owned(),
    }
}

fn invalid(detail: &str) -> AccountError {
    AccountError::Refused {
        status: 422,
        code: "validation_failed".to_owned(),
        detail: detail.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead as _, Read as _, Write as _};
    use std::path::Path;
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use chrono::Utc;
    use tablepro_core::credentials::SecretError;
    use tokio::sync::watch;

    use super::*;
    use crate::account_file::{self, AccountFile};
    use crate::account_settings::{AccountSettings, AppClient, CallbackPage, DeviceDescription, Endpoints};
    use crate::account_status::AccountStatus;
    use crate::browser::BrowserLauncher;
    use crate::entitlement::test_tokens::keys;
    use crate::machine_id::MachineId;
    use crate::share::ShareKind;
    use crate::token_vault::RefreshTokenVault;

    const TOKEN: &str = "Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK";
    const TOKENS: &str =
        r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900,"refresh_token":"stub-refresh"}"#;
    const VIEW: &str = r#"{"id":"shr_01","kind":"query","scope":"account","title":"Orders","note":"","dialect":"postgres",
        "has_snapshot":false,"hide_sql":false,"allow_download":true,"has_password":false,"state":"live","suspended":false,
        "view_count":3,"created_at":"2026-11-13T00:00:00Z","updated_at":"2026-11-13T00:00:00Z","expires_at":"2026-12-13T00:00:00Z",
        "url":"https://s.tablepro.app/Ab3dEf6hIj9kLm2nOp5qRs8tUv1wXy4zAb7dEf0hIjK"}"#;

    // What the stub was sent: the method and path, the header lines in lower case, and the body.
    #[derive(Debug, Clone)]
    struct Sent {
        request: String,
        headers: String,
        body: String,
    }

    type Log = Arc<Mutex<Vec<Sent>>>;
    type Answer = dyn Fn(&Sent) -> (u16, &'static str, String) + Send;

    fn cloud(answer: impl Fn(&Sent) -> (u16, &'static str, String) + Send + 'static) -> (Endpoints, Log) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        let log = Log::default();
        let kept = log.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                serve(stream, &answer, &kept);
            }
        });
        let endpoints = Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints");
        (endpoints, log)
    }

    fn serve(stream: std::net::TcpStream, answer: &Answer, log: &Log) {
        let mut reader = std::io::BufReader::new(stream.try_clone().expect("a second handle"));
        let mut line = String::new();
        reader.read_line(&mut line).expect("the request line");
        let mut words = line.split_whitespace();
        let request = format!(
            "{} {}",
            words.next().unwrap_or_default(),
            words.next().unwrap_or_default()
        );
        let (mut headers, mut length) = (String::new(), 0);
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).expect("a header");
            if header.trim().is_empty() {
                break;
            }
            let header = header.to_ascii_lowercase();
            if let Some(value) = header.strip_prefix("content-length:") {
                length = value.trim().parse().expect("a length");
            }
            headers.push_str(&header);
        }
        let mut body = vec![0; length];
        reader.read_exact(&mut body).expect("the body");
        let sent = Sent {
            request,
            headers,
            body: String::from_utf8_lossy(&body).into_owned(),
        };
        let (status, extra, answer) = answer(&sent);
        log.lock().expect("the log").push(sent);
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\n{extra}content-length: {}\r\nconnection: close\r\n\r\n{answer}",
            answer.len()
        )
        .expect("the answer");
    }

    struct Vault;

    #[async_trait]
    impl RefreshTokenVault for Vault {
        async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
            Ok(Some(SecretString::from("refresh")))
        }

        async fn store_refresh_token(&self, _: &SecretString) -> Result<(), SecretError> {
            Ok(())
        }

        async fn delete_refresh_token(&self) -> Result<(), SecretError> {
            Ok(())
        }
    }

    struct NoBrowser;

    #[async_trait]
    impl BrowserLauncher for NoBrowser {
        async fn open(&self, _: &url::Url) -> Result<(), String> {
            Err("a unit test opens no browser".to_owned())
        }
    }

    // Signed in from a kept sign-in, as at a launch, so the first call refreshes the token.
    async fn signed_in(dir: &Path, endpoints: Endpoints) -> Account {
        let file = AccountFile {
            device_id: Some("dev_01".to_owned()),
            ..AccountFile::default()
        };
        account_file::write(&dir.join("account.json"), &file)
            .await
            .expect("the account file");
        let settings = AccountSettings {
            client: AppClient::WINDOWS,
            endpoints,
            device: DeviceDescription {
                name: "Lab".to_owned(),
                app_version: "1.0.0".to_owned(),
                os_version: "Windows 11".to_owned(),
            },
            machine_id: MachineId::derive_machine_guid("d3b07384-d113-4ec6-a2f1-6a3f0c2e9b7a").expect("a machine"),
            keys: keys(),
            account_file: dir.join("account.json"),
            callback_page: CallbackPage {
                finished: String::new(),
                unknown: String::new(),
            },
        };
        let account = Account::new(
            settings,
            Arc::new(Vault),
            Arc::new(NoBrowser),
            watch::Sender::new(AccountStatus::SignedOut),
        )
        .expect("an account");
        account.restore().await;
        account
    }

    fn problem(status: u16, code: &str) -> String {
        format!(r#"{{"type":"about:blank","title":"Refused","status":{status},"code":"{code}"}}"#)
    }

    fn query(title: &str) -> ShareRequest {
        ShareRequest {
            kind: ShareKind::Query,
            sql: "SELECT * FROM orders".to_owned(),
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

    fn sent(log: &Log, request: &str) -> Vec<Sent> {
        log.lock()
            .expect("the log")
            .iter()
            .filter(|sent| sent.request.starts_with(request))
            .cloned()
            .collect()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_limits_say_what_the_plan_allows() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (endpoints, log) = cloud(|sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "GET /v2/share-limits" => (
                200,
                "",
                r#"{"plan":"free","live":5,"live_limit":5,"max_rows":1000,"expiries":["1d","7d","30d","2w"],
                "default_expiry":"30d","password":false,"disable_download":false,"team":false,
                "email_verified":true,"sharing_disabled":false}"#
                    .to_owned(),
            ),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let limits = account.share_limits().await.expect("the limits");

        assert_eq!(limits.plan, "free");
        assert_eq!(
            limits.expiries,
            [ShareExpiry::OneDay, ShareExpiry::SevenDays, ShareExpiry::ThirtyDays]
        );
        assert_eq!(limits.default_expiry, Some(ShareExpiry::ThirtyDays));
        assert_eq!(limits.max_rows, 1_000);
        assert!(limits.at_limit());
        assert!(
            sent(&log, "GET /v2/share-limits")[0]
                .headers
                .contains("authorization: bearer stub-access")
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_create_sends_only_what_was_set_and_gives_the_url() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (endpoints, log) = cloud(|sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "POST /v2/shares" => (
                201,
                "",
                format!(r#"{{"share":{VIEW},"token":"{TOKEN}","url":"https://s.tablepro.app/{TOKEN}"}}"#),
            ),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;
        let request = ShareRequest {
            expiry: Some(ShareExpiry::SevenDays),
            note: Some("  ".to_owned()),
            ..query(&format!("  {}  ", "t".repeat(250)))
        };

        let created = account.create_share(request).await.expect("created");

        assert_eq!(created.url, format!("https://s.tablepro.app/{TOKEN}"));
        assert_eq!(created.share.id, "shr_01");
        assert!(created.share.is_live());
        let body: serde_json::Value =
            serde_json::from_str(&sent(&log, "POST /v2/shares")[0].body).expect("a JSON body");
        assert_eq!(body["kind"], "query");
        assert_eq!(body["expiry"], "7d");
        assert_eq!(body["title"].as_str().map(|title| title.chars().count()), Some(200));
        for absent in ["note", "hide_sql", "password", "team_id", "snapshot", "allow_download"] {
            assert!(
                body.get(absent).is_none_or(serde_json::Value::is_null),
                "{absent}: {body}"
            );
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_result_s_rows_go_out_as_the_core_wrote_them() {
        use tablepro_core::column::{ColumnType, ResultColumn};
        use tablepro_core::export::build_snapshot;
        use tablepro_core::value::Value;

        let dir = tempfile::tempdir().expect("a temporary directory");
        let (endpoints, log) = cloud(|sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "POST /v2/shares" => (
                201,
                "",
                format!(r#"{{"share":{VIEW},"token":"{TOKEN}","url":"https://s.tablepro.app/{TOKEN}"}}"#),
            ),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;
        let columns = [ResultColumn::new("big", ColumnType::untyped_text("numeric"))];
        let rows = [
            vec![Value::Decimal(
                "123456789012345678901234567890.5".parse().expect("a decimal"),
            )],
            vec![Value::Null],
        ];
        let request = ShareRequest {
            kind: ShareKind::Result,
            hide_sql: true,
            snapshot: Some(build_snapshot(&columns, &rows, 48_210, 1)),
            ..query("Orders")
        };

        account.create_share(request).await.expect("created");

        let body = sent(&log, "POST /v2/shares")[0].body.clone();
        assert!(
            body.contains(r#""rows":[[123456789012345678901234567890.5]]"#),
            "{body}"
        );
        assert!(body.contains(r#""row_count":48210"#), "{body}");
        assert!(
            body.contains(r#""columns":[{"name":"big","type":"numeric"}]"#),
            "{body}"
        );
        assert!(body.contains(r#""hide_sql":true"#), "{body}");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn each_refusal_reads_as_the_code_the_app_words() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let answers = Arc::new(Mutex::new(vec![
            (403, problem(403, "email_unverified")),
            (403, problem(403, "pro_required")),
            (409, problem(409, "share_limit_reached")),
            (413, "<html>Request Entity Too Large</html>".to_owned()),
            (422, problem(422, "snapshot_too_large")),
        ]));
        let (endpoints, _) = cloud(move |sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "POST /v2/shares" => {
                let (status, body) = answers.lock().expect("the answers").remove(0);
                (status, "", body)
            }
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let mut codes = Vec::new();
        for _ in 0..5 {
            codes.push(account.create_share(query("Orders")).await.expect_err("refused").code());
        }

        assert_eq!(
            codes,
            [
                "account.email_unverified",
                "account.pro_required",
                "account.share_limit_reached",
                "account.snapshot_too_large",
                "account.snapshot_too_large",
            ]
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_429_on_create_holds_further_creates_and_nothing_else() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (endpoints, log) = cloud(|sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "POST /v2/shares" => (429, "retry-after: 60\r\n", problem(429, "rate_limited")),
            request if request.starts_with("GET /v2/shares") => (200, "", format!(r#"{{"data":[{VIEW}]}}"#)),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let limited = account.create_share(query("Orders")).await;
        let held = account.create_share(query("Orders")).await;
        let listed = account.list_shares(true, None).await.expect("the list");

        assert!(
            matches!(limited, Err(AccountError::RateLimited { retry_after: Some(wait) }) if wait.as_secs() == 60),
            "{limited:?}"
        );
        assert!(matches!(held, Err(AccountError::RateLimited { .. })), "{held:?}");
        assert_eq!(sent(&log, "POST /v2/shares").len(), 1);
        assert_eq!(listed.shares.len(), 1);
        assert_eq!(listed.next_cursor, None);
        let list = &sent(&log, "GET /v2/shares")[0].request;
        assert!(list.contains("state=live") && list.contains("limit=100"), "{list}");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_suspended_link_stays_live_without_a_url() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let held = r#"{"id":"shr_02","kind":"query","scope":"account","title":"Orders","note":"","dialect":"postgres",
            "has_snapshot":false,"hide_sql":false,"allow_download":true,"has_password":false,"state":"live",
            "suspended":true,"suspended_by":"account","view_count":0,
            "created_at":"2026-11-13T00:00:00Z","updated_at":"2026-11-13T00:00:00Z"}"#;
        let (endpoints, _) = cloud(move |sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            request if request.starts_with("GET /v2/shares") => (200, "", format!(r#"{{"data":[{VIEW},{held}]}}"#)),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let listed = account.list_shares(true, None).await.expect("the list");

        let [open, suspended] = listed.shares.as_slice() else {
            panic!("{listed:?}");
        };
        assert!(!open.suspended && open.suspended_by.is_none() && open.url.is_some());
        assert!(suspended.is_live() && suspended.suspended);
        assert_eq!(suspended.suspended_by.as_deref(), Some("account"));
        assert_eq!(suspended.url, None);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_extend_sends_the_expiry_and_a_revoke_deletes() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let (endpoints, log) = cloud(|sent| match sent.request.as_str() {
            "POST /oauth/token" => (200, "", TOKENS.to_owned()),
            "PATCH /v2/shares/shr_01" => (200, "", VIEW.to_owned()),
            "DELETE /v2/shares/shr_01" => (204, "", String::new()),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let extended = account
            .extend_share("shr_01", ShareExpiry::ThirtyDays)
            .await
            .expect("extended");
        account.revoke_share("shr_01").await.expect("revoked");

        assert_eq!(
            extended.expires_at.map(|at| at.to_rfc3339()).as_deref(),
            Some("2026-12-13T00:00:00+00:00")
        );
        assert_eq!(sent(&log, "PATCH /v2/shares/shr_01")[0].body, r#"{"expiry":"30d"}"#);
        assert_eq!(sent(&log, "DELETE /v2/shares/shr_01").len(), 1);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_shared_link_is_read_without_a_token_and_with_its_password() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = format!("GET /v2/shared/{TOKEN}");
        let (endpoints, log) = cloud(move |sent| match sent.request.as_str() {
            request if request == path && sent.headers.contains("x-share-password: hunter2") => (
                200,
                "",
                r#"{"kind":"result","title":"Orders","note":"","dialect":"postgres","sql":"SELECT 1",
                "created_at":"2026-11-13T00:00:00Z","allow_download":true,"made_with":"TablePro",
                "snapshot":{"columns":[{"name":"n","type":"int"}],"rows":[["9007199254740993"],[1]],
                "row_count":48210,"truncated":true}}"#
                    .to_owned(),
            ),
            request if request == path && sent.headers.contains("x-share-password:") => {
                (401, "", problem(401, "share_password_wrong"))
            }
            request if request == path => (401, "", problem(401, "share_password_required")),
            _ => (404, "", String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let required = account.fetch_shared(TOKEN, None).await;
        let wrong = account.fetch_shared(TOKEN, Some(&SecretString::from("nope"))).await;
        let opened = account
            .fetch_shared(TOKEN, Some(&SecretString::from("hunter2")))
            .await
            .expect("the link");
        let malformed = account.fetch_shared("short", None).await;

        assert_eq!(required.expect_err("refused").code(), "account.share_password_required");
        assert_eq!(wrong.expect_err("refused").code(), "account.share_password_wrong");
        assert_eq!(opened.sql.as_deref(), Some("SELECT 1"));
        assert_eq!((opened.row_count, opened.truncated), (Some(48_210), Some(true)));
        assert_eq!(opened.expires_at, None);
        assert_eq!(malformed.expect_err("refused").code(), "account.not_found");
        let log = log.lock().expect("the log");
        assert_eq!(log.len(), 3, "{log:?}");
        assert!(
            log.iter().all(|sent| !sent.headers.contains("authorization")),
            "{log:?}"
        );
        assert!(opened.created_at <= Utc::now());
    }
}
