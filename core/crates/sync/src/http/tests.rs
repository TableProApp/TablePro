use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::Value;
use sha2::{Digest as _, Sha256};
use tablepro_keys::b64;
use tablepro_keys::keys::Ed25519Seed;
use uuid::Uuid;

use super::*;
use crate::api::ids::{ChangeTag, EpochId, IdempotencyKey, KindName};
use crate::api::scopes::Role;
use crate::api::transport::{AppliedStamp, Change, ChangeOp, ChangeOutcome, DeletedReason, RejectedCode};

const TOKEN: &str = "access-1";
const ACCOUNT_TYPEID: &str = "acct_01k8d6wk00f8xsr79e7x052rkk";
const DEVICE: &str = "dev_01k8d6wpggfd68tbhz818p4ww4";
const TEAM: &str = "team_01k8d6wk00f8xsr79e7x052aaa";

// What the stub was sent.
#[derive(Debug, Clone)]
struct Sent {
    method: String,
    target: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl Sent {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(held, _)| held.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    fn proof_claims(&self) -> Value {
        let proof = self.header("dpop").expect("a DPoP proof");
        let payload = proof.split('.').nth(1).expect("a payload");
        serde_json::from_slice(&b64::decode(payload).expect("base64url")).expect("claims")
    }
}

type Answer = dyn Fn(usize, &Sent) -> (u16, String, String) + Send + Sync;

// Answers each request with the status, header lines and body `answer` gives for its index and what it sent.
fn server(
    answer: impl Fn(usize, &Sent) -> (u16, String, String) + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<Sent>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
    let base = format!("http://{}/v2", listener.local_addr().expect("its address"));
    let log = Arc::new(Mutex::new(Vec::new()));
    let kept = Arc::clone(&log);
    let answer: Arc<Answer> = Arc::new(answer);
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
            let mut line = String::new();
            reader.read_line(&mut line).expect("the request line");
            let mut words = line.split_whitespace();
            let (method, target) = (
                words.next().unwrap_or_default().to_owned(),
                words.next().unwrap_or_default().to_owned(),
            );
            let mut headers = Vec::new();
            let mut length = 0;
            loop {
                let mut header = String::new();
                reader.read_line(&mut header).expect("a header");
                if header.trim().is_empty() {
                    break;
                }
                if let Some((name, value)) = header.split_once(':') {
                    if name.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse().expect("a length");
                    }
                    headers.push((name.trim().to_owned(), value.trim().to_owned()));
                }
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body).expect("the body");
            let sent = Sent {
                method,
                target,
                headers,
                body: String::from_utf8_lossy(&body).into_owned(),
            };
            let index = {
                let mut log = kept.lock().expect("the log");
                log.push(sent.clone());
                log.len() - 1
            };
            let (status, extra, body) = answer(index, &sent);
            let mut stream = stream;
            write!(
                stream,
                "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\n{extra}content-length: {}\r\nconnection: close\r\n\r\n{body}",
                body.len()
            )
            .expect("the answer");
        }
    });
    (base, log)
}

struct Account {
    now: Mutex<SignedIn>,
    rejected: AtomicUsize,
}

impl Account {
    fn at(api: &str) -> Arc<Self> {
        Arc::new(Self {
            now: Mutex::new(SignedIn {
                token: SecretString::from(TOKEN),
                api: api.to_owned(),
                origin: Origin::of_url(api).expect("an origin").as_str().to_owned(),
                sign_in: "0123456789abcdef".to_owned(),
                account_id: Some(ACCOUNT_TYPEID.to_owned()),
                device_id: Some(DEVICE.to_owned()),
                session_id: Some("session-1".to_owned()),
            }),
            rejected: AtomicUsize::new(0),
        })
    }
}

#[async_trait]
impl SignIn for Account {
    async fn signed_in(&self) -> Result<SignedIn, TransportError> {
        Ok(self.now.lock().expect("the sign-in").clone())
    }

    async fn rejected(&self, _: &SecretString) {
        self.rejected.fetch_add(1, Ordering::SeqCst);
        self.now.lock().expect("the sign-in").token = SecretString::from("access-2");
    }
}

async fn transport(api: &str) -> (HttpTransport, Arc<Account>) {
    let account = Account::at(api);
    let transport = HttpTransport::open(account.clone(), reqwest::Client::new())
        .await
        .expect("a transport");
    (transport, account)
}

fn key() -> DpopKey {
    DpopKey(std::sync::Arc::new(Ed25519Seed::generate().expect("a key")))
}

fn ok(body: String) -> (u16, String, String) {
    (200, String::new(), body)
}

fn epoch() -> (EpochId, String) {
    let id = EpochId(Uuid::from_u128(0x0193_0000_0000_7000_8000_0000_0000_0001));
    (id, wire::epoch_of(id.0))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_pull_keeps_each_record_s_field_text_as_the_server_sent_it() {
    let (_, epoch_text) = epoch();
    let page = format!(
        r#"{{"records":[
            {{"kind":"key.account","record_id":"A","version":1,"revision":7,"epoch":"{epoch_text}","change_tag":"t1","deleted":false,"fields":{{"av":1,"av":2}},"updated_at":"2026-11-26T00:00:00Z","taken_at":5,"updated_by":"{ACCOUNT_TYPEID}","updated_device":"{DEVICE}"}},
            {{"kind":"connection","record_id":"B","version":3,"revision":8,"epoch":"{epoch_text}","change_tag":"t2","deleted":true,"deleted_reason":"policy","updated_at":"2026-11-26T00:00:01Z","taken_at":6}}
        ],"cursor":"c2"}}"#
    );
    let (api, log) = server(move |_, _| ok(page.clone()));
    let (transport, _) = transport(&api).await;
    let dsk = key();

    let pulled = transport
        .pull(PullRequest {
            scope: ScopeName::Personal,
            cursor: Some(Cursor::Service("c1".to_owned())),
            limit: Some(100),
            proof: Proof::Dpop(dsk),
        })
        .await
        .expect("a page");

    let sent = log.lock().unwrap()[0].clone();
    let claims = sent.proof_claims();
    assert_eq!(sent.method, "GET");
    assert_eq!(sent.target, "/v2/sync/scopes/personal/changes?cursor=c1&limit=100");
    assert_eq!(sent.header("authorization"), Some("Bearer access-1"));
    assert_eq!(claims["htm"], "GET");
    assert_eq!(claims["htu"], format!("{api}/sync/scopes/personal/changes"));
    assert_eq!(claims["ath"], b64::encode(&Sha256::digest(TOKEN.as_bytes())));
    assert_eq!(pulled.records[0].fields_json.as_deref(), Some(r#"{"av":1,"av":2}"#));
    assert_eq!(pulled.records[0].tag, ChangeTag::Service("t1".to_owned()));
    let meta = pulled.records[0].service.clone().unwrap();
    assert_eq!((meta.version, meta.revision, meta.taken_at_us), (1, 7, 5));
    assert_eq!(meta.updated_device, Some(DeviceRowId(DEVICE.to_owned())));
    assert_eq!(pulled.records[1].deleted, Some(DeletedReason::Policy));
    assert_eq!(pulled.records[1].fields, None);
    assert_eq!(pulled.cursor, Some(Cursor::Service("c2".to_owned())));
    assert!(!pulled.caught_up);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_empty_page_is_caught_up_and_a_team_read_carries_no_proof() {
    let (api, log) = server(|_, _| ok(r#"{"records":[],"cursor":"c9"}"#.to_owned()));
    let (transport, _) = transport(&api).await;
    let team = ScopeName::parse(TEAM).unwrap();

    let pulled = transport
        .pull(PullRequest {
            scope: team,
            cursor: None,
            limit: None,
            proof: Proof::None,
        })
        .await
        .expect("a page");

    assert!(pulled.caught_up);
    let sent = log.lock().unwrap()[0].clone();
    assert_eq!(sent.target, format!("/v2/sync/scopes/{TEAM}/changes"));
    assert_eq!(sent.header("dpop"), None);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_push_names_its_epoch_key_and_bases_and_reads_each_outcome_in_order() {
    let (epoch_id, epoch_text) = epoch();
    let answer = format!(
        r#"{{"outcomes":[
            {{"kind":"connection","record_id":"A","status":"applied","change_tag":"t9","version":4,"revision":12}},
            {{"kind":"connection","record_id":"B","status":"conflict","stored":{{"change_tag":"t3","version":2,"revision":10,"epoch":"{epoch_text}","deleted":false}}}},
            {{"kind":"connection","record_id":"C","status":"rejected","code":"too_large"}}
        ]}}"#
    );
    let (api, log) = server(move |_, _| ok(answer.clone()));
    let (transport, _) = transport(&api).await;
    let patch: Value = serde_json::from_str(r#"{"name":"db"}"#).unwrap();
    let write = |id: &str, base: Option<&str>| Change {
        kind: KindName::parse("connection").unwrap(),
        record_id: id.to_owned(),
        base: base.map(|tag| ChangeTag::Service(tag.to_owned())),
        op: ChangeOp::Write {
            fields: patch.clone(),
            patch: patch.clone(),
        },
    };
    let changes = vec![
        write("A", None),
        write("B", Some("t1")),
        Change {
            op: ChangeOp::Delete,
            ..write("C", Some("t2"))
        },
    ];

    let answered = transport
        .push(PushBatch {
            scope: ScopeName::Personal,
            epoch: Some(epoch_id),
            idempotency_key: Some(IdempotencyKey::parse("6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44").unwrap()),
            changes,
            proof: Proof::Dpop(key()),
        })
        .await
        .expect("an answer");

    let sent = log.lock().unwrap()[0].clone();
    let body: Value = serde_json::from_str(&sent.body).unwrap();
    assert_eq!(sent.method, "POST");
    assert_eq!(
        sent.header("idempotency-key"),
        Some("6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44")
    );
    assert_eq!(body["epoch"], epoch_text);
    assert_eq!(body["changes"][0].get("base_tag"), None);
    assert_eq!(body["changes"][1]["base_tag"], "t1");
    assert_eq!(body["changes"][1]["patch"]["name"], "db");
    assert_eq!(body["changes"][2]["op"], "delete");
    assert_eq!(body["changes"][2].get("patch"), None);
    assert_eq!(
        answered.outcomes[0],
        ChangeOutcome::Applied {
            tag: Some(ChangeTag::Service("t9".to_owned())),
            service: Some(AppliedStamp {
                version: 4,
                revision: 12
            }),
        }
    );
    assert!(
        matches!(&answered.outcomes[1], ChangeOutcome::Conflict { stored: Some(stored) }
            if stored.tag == ChangeTag::Service("t3".to_owned()) && !stored.tombstone),
        "{:?}",
        answered.outcomes[1]
    );
    assert_eq!(
        answered.outcomes[2],
        ChangeOutcome::Rejected {
            code: RejectedCode::TooLarge
        }
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_answer_that_does_not_pair_with_what_was_sent_is_refused() {
    let (epoch_id, _) = epoch();
    let (api, _) = server(|_, _| ok(r#"{"outcomes":[]}"#.to_owned()));
    let (transport, _) = transport(&api).await;

    let answered = transport
        .push(PushBatch {
            scope: ScopeName::Personal,
            epoch: Some(epoch_id),
            idempotency_key: Some(IdempotencyKey::parse("k").unwrap()),
            changes: vec![Change {
                kind: KindName::parse("connection").unwrap(),
                record_id: "A".to_owned(),
                base: None,
                op: ChangeOp::Delete,
            }],
            proof: Proof::None,
        })
        .await;

    assert!(
        matches!(&answered, Err(TransportError::Server { code, .. }) if code == "malformed_answer"),
        "{answered:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_server_s_nonce_is_taken_once_and_carried_by_the_retried_proof() {
    let (api, log) = server(|index, _| match index {
        0 => (
            401,
            "www-authenticate: DPoP error=\"use_dpop_nonce\"\r\ndpop-nonce: n-1\r\n".to_owned(),
            r#"{"type":"about:blank","title":"Nonce","status":401,"code":"use_dpop_nonce"}"#.to_owned(),
        ),
        _ => (204, String::new(), String::new()),
    });
    let (transport, _) = transport(&api).await;

    transport.revoke_key_device(key()).await.expect("revoked");

    let sent = log.lock().unwrap().clone();
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[0].proof_claims().get("nonce"), None);
    assert_eq!(sent[1].proof_claims()["nonce"], "n-1");
    assert_eq!(sent[1].target, "/v2/sync/key-device");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_refused_token_is_refreshed_once_and_a_second_refusal_ends_the_sign_in_s_calls() {
    let (api, log) = server(|_, _| {
        (
            401,
            "www-authenticate: Bearer error=\"invalid_token\"\r\n".to_owned(),
            r#"{"type":"about:blank","title":"Unauthorized","status":401,"code":"unauthorized"}"#.to_owned(),
        )
    });
    let (transport, account) = transport(&api).await;

    let answered = transport.scopes(None, Proof::None).await;

    let sent = log.lock().unwrap().clone();
    assert_eq!(answered, Err(TransportError::SignedOut));
    assert_eq!(account.rejected.load(Ordering::SeqCst), 1);
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[1].header("authorization"), Some("Bearer access-2"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_call_after_the_sign_in_changed_is_refused_and_never_sent() {
    let (api, log) = server(|_, _| ok(r#"{"records":[]}"#.to_owned()));
    let (transport, account) = transport(&api).await;
    account.now.lock().unwrap().session_id = Some("session-2".to_owned());

    let answered = transport
        .pull(PullRequest {
            scope: ScopeName::Personal,
            cursor: None,
            limit: None,
            proof: Proof::None,
        })
        .await;

    assert_eq!(answered, Err(TransportError::SignedOut));
    assert!(log.lock().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_sign_in_with_no_device_row_opens_no_transport() {
    let account = Account::at("http://127.0.0.1:1/v2");
    account.now.lock().unwrap().device_id = None;

    let opened = HttpTransport::open(account, reqwest::Client::new()).await;

    assert!(matches!(opened, Err(TransportError::SignedOut)), "{opened:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_scopes_body_reads_with_its_etag_and_an_unchanged_one_answers_304() {
    let (_, epoch_text) = epoch();
    let body = format!(
        r#"{{"epoch":"{epoch_text}","scopes":[
            {{"id":"personal","type":"personal","role":"owner","horizon":3,"epochs":[{{"id":"{epoch_text}","kept_revision":0}}],"writable":true,"policies":{{}},"quota":null,"approved":true}},
            {{"id":"{TEAM}","type":"team","team":"{TEAM}","role":"admin","horizon":9,"epochs":[],"writable":true,"policies":{{"password_sync":false}},"quota":null,"rotation_due":true,
              "members":[{{"account":"{ACCOUNT_TYPEID}","role":"owner"}},{{"account":"{ACCOUNT_TYPEID}","role":"steward"}}],
              "stopped":[{{"account":"{ACCOUNT_TYPEID}","device":"{DEVICE}","version":2}}]}},
            {{"id":"archive","type":"archive","role":"owner","horizon":0,"epochs":[],"writable":false,"policies":{{}},"quota":null}}
        ],"limits":{{"record_bytes":1048576,"body_bytes":4194304,"push_changes":500,"change_set_changes":10000,"page_records":500,"page_bytes":4194304,"json_depth":32,"team_key_holders":5000}},
        "server_version":"0.3.0","capabilities":[],"idempotency_retention":86400,"poll_interval":60}}"#
    );
    let (api, log) = server(move |index, sent| match (index, sent.header("if-none-match")) {
        (0, None) => (200, "etag: \"e1\"\r\n".to_owned(), body.clone()),
        _ => (304, "etag: \"e1\"\r\n".to_owned(), String::new()),
    });
    let (transport, _) = transport(&api).await;

    let first = transport.scopes(None, Proof::Dpop(key())).await.expect("a body");
    let second = transport
        .scopes(Some("\"e1\"".to_owned()), Proof::None)
        .await
        .expect("an idle poll");

    let ScopesAnswer::Body { body, etag } = first else {
        panic!("no body");
    };
    assert_eq!(etag, "\"e1\"");
    assert_eq!(body.scopes.len(), 2, "the scope this build cannot name is left out");
    assert_eq!(body.scopes[0].role, None);
    assert_eq!(body.scopes[0].approved, Some(true));
    let team = &body.scopes[1];
    assert_eq!(team.role, Some(Role::Admin));
    assert!(team.rotation_due);
    assert_eq!(
        team.members[1].role,
        Role::Member,
        "a role this build does not know grants a member's"
    );
    assert_eq!(team.stopped[0].version.get(), 2);
    assert_eq!(team.policies.password_sync, Some(false));
    assert_eq!(body.poll_interval_secs, 60);
    assert_eq!(second, ScopesAnswer::NotModified);
    assert_eq!(log.lock().unwrap()[1].header("if-none-match"), Some("\"e1\""));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_step_up_challenge_and_the_whole_request_refusals_read_as_their_errors() {
    let (api, _) = server(|index, _| match index {
        0 => (
            401,
            "www-authenticate: Bearer error=\"insufficient_user_authentication\", acr_values=\"passkey otp\"\r\n"
                .to_owned(),
            r#"{"type":"about:blank","title":"Step up","status":401,"code":"step_up_required"}"#.to_owned(),
        ),
        1 => (
            403,
            String::new(),
            r#"{"type":"about:blank","title":"Removed","status":403,"code":"device_removed"}"#.to_owned(),
        ),
        _ => (404, String::new(), String::new()),
    });
    let (transport, _) = transport(&api).await;
    let device = DeviceRowId(DEVICE.to_owned());

    let step_up = transport.remove_device_row(device.clone(), key()).await;
    let removed = transport
        .report_stopped(TeamId(Uuid::from_u128(1)), Version::new(2).unwrap(), key())
        .await;
    let too_old = transport.scopes(None, Proof::None).await;
    let refused_path = transport
        .remove_device_row(DeviceRowId("../admin".to_owned()), key())
        .await;

    assert_eq!(
        step_up,
        Err(TransportError::StepUpRequired(crate::api::transport::StepUpChallenge {
            acr_values: vec!["passkey".to_owned(), "otp".to_owned()],
            max_age_secs: 300,
        }))
    );
    assert_eq!(removed, Err(TransportError::DeviceRemoved));
    assert_eq!(too_old, Err(TransportError::ServerTooOld));
    assert_eq!(refused_path, Err(TransportError::ValidationFailed));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_bearer_and_the_proof_never_show_in_a_request_s_debug_text() {
    let (transport, _) = transport("http://127.0.0.1:1/v2").await;
    let dsk = key();
    let call = Call {
        method: Method::GET,
        path: "/sync/scopes".to_owned(),
        query: Vec::new(),
        headers: Vec::new(),
        body: None,
        proof: Some(&dsk),
    };

    let request = transport
        .request(&call, &SecretString::from(TOKEN))
        .unwrap()
        .build()
        .unwrap();
    let text = format!("{request:?} {:?}", request.headers());

    assert!(request.headers().contains_key("dpop"));
    assert!(!text.contains(TOKEN), "{text}");
    assert!(!text.contains("eyJ"), "{text}");
}
