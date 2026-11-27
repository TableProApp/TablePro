#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use secrecy::{ExposeSecret, SecretString};
use tablepro_ffi::{
    AiChatArg, AiConversationArg, AiMessageArg, AiPolicyTag, AiProviderTag, AiReply, AiReplyEvent, AiReplyListener,
    AiRoleTag, AiSettingsArg, AiStopTag, ConnectionRecord, ConnectionSecrets, Core, CoreError, DatabaseSession,
    FileOpenRequest, HostConfig, HostSecretError, HostSecrets, ObjectScopeArg, RunListener, RunOutcome, RunSettings,
    SafeModeTag, SecretItemTag, SecretKindTag, TlsModeTag, TlsSettings,
};

#[derive(Clone, Default)]
struct MemorySecrets {
    items: Arc<Mutex<HashMap<SecretItemTag, String>>>,
}

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
        Ok(self.items.lock().unwrap().get(&item).cloned().map(SecretString::from))
    }

    fn store_item(&self, item: SecretItemTag, secret: SecretString) -> Result<(), HostSecretError> {
        self.items
            .lock()
            .unwrap()
            .insert(item, secret.expose_secret().to_owned());
        Ok(())
    }

    fn delete_item(&self, item: SecretItemTag) -> Result<(), HostSecretError> {
        self.items.lock().unwrap().remove(&item);
        Ok(())
    }
}

struct Quiet;

impl RunListener for Quiet {
    fn events_pending(&self) {}
}

impl AiReplyListener for Quiet {
    fn events_pending(&self) {}
}

const SHOP: &str = "CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL); \
    CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers (id), total REAL); \
    CREATE TABLE audit (id INTEGER PRIMARY KEY, note TEXT); \
    INSERT INTO customers (id, name) VALUES (1, 'Ada Lovelace')";

fn core(dir: &Path, secrets: MemorySecrets) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.join("storage").display().to_string()),
        },
        Box::new(secrets),
    )
    .unwrap()
}

async fn shop(core: &Core, path: &Path) -> Arc<DatabaseSession> {
    let session = core
        .open_file(
            FileOpenRequest {
                path: path.display().to_string(),
                driver_id: None,
                read_only: false,
                create: !path.exists(),
            },
            None,
        )
        .await
        .unwrap();
    let editor = session.open_editor(None, None).await.unwrap();
    let run = editor.run(SHOP.to_owned(), RunSettings::default(), Box::new(Quiet));
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    editor.close().await.unwrap();
    // The catalog does not see tables an editor made until it reads again, as the tree's refresh does.
    session
        .refresh_objects(ObjectScopeArg::DefaultSchema, None)
        .await
        .unwrap();
    session
}

fn record(path: &Path, ai_policy: Option<AiPolicyTag>) -> ConnectionRecord {
    ConnectionRecord {
        id: String::new(),
        name: "shop".to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: path.display().to_string(),
        username: String::new(),
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
        ai_policy,
        external_access: None,
        project_id: None,
        icon: None,
        order: 0,
    }
}

async fn connect(core: &Core, id: String) -> Arc<DatabaseSession> {
    core.connect_saved(
        id,
        None,
        ConnectionSecrets::default(),
        ConnectionSecrets::default(),
        None,
        None,
    )
    .await
    .unwrap()
}

fn compatible(address: &str) -> AiSettingsArg {
    AiSettingsArg {
        provider: AiProviderTag::OpenAiCompatible,
        model: "test-model".to_owned(),
        address: Some(address.to_owned()),
    }
}

fn question(text: &str) -> AiChatArg {
    AiChatArg {
        system: "system".to_owned(),
        messages: vec![AiMessageArg {
            role: AiRoleTag::User,
            text: text.to_owned(),
        }],
    }
}

// Every event until the one that ends the reply.
async fn read_to_end(reply: &AiReply) -> Vec<AiReplyEvent> {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut events = Vec::new();
    loop {
        events.extend(reply.drain_events());
        if events
            .last()
            .is_some_and(|event| !matches!(event, AiReplyEvent::Text { .. }))
        {
            return events;
        }
        assert!(Instant::now() < deadline, "the reply never ended: {events:?}");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

fn text_of(events: &[AiReplyEvent]) -> String {
    events
        .iter()
        .filter_map(|event| match event {
            AiReplyEvent::Text { part } => Some(part.as_str()),
            _ => None,
        })
        .collect()
}

#[derive(Debug, Clone)]
struct Seen {
    request_line: String,
    headers: HashMap<String, String>,
    body: String,
}

#[derive(Clone)]
enum Answer {
    Ok { content_type: &'static str, body: String },
    Status(u16, String),
    // The headers of a stream, then nothing until the client goes.
    Stalls,
}

struct Server {
    address: String,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Server {
    // A thread per request, so one that stalls holds only its own connection.
    fn start(answer: Answer) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = format!("http://{}/v1", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorded = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let answer = answer.clone();
                let recorded = recorded.clone();
                std::thread::spawn(move || serve(stream, &answer, &recorded));
            }
        });
        Self { address, seen }
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().unwrap().clone()
    }
}

fn serve(mut stream: TcpStream, answer: &Answer, recorded: &Mutex<Vec<Seen>>) {
    let request = read_request(&stream);
    recorded.lock().unwrap().push(request);
    let response = match answer {
        Answer::Ok { content_type, body } => respond(200, content_type, body),
        Answer::Status(status, body) => respond(*status, "application/json", body),
        Answer::Stalls => {
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n");
            std::thread::sleep(Duration::from_secs(60));
            return;
        }
    };
    let _ = stream.write_all(response.as_bytes());
}

fn respond(status: u16, content_type: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status} X\r\ncontent-type: {content_type}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn read_request(stream: &TcpStream) -> Seen {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    reader.read_line(&mut request_line).unwrap();
    let mut headers = HashMap::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        if line.trim().is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_owned());
        }
    }
    let length: usize = headers
        .get("content-length")
        .and_then(|length| length.parse().ok())
        .unwrap_or(0);
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    Seen {
        request_line: request_line.trim_end().to_owned(),
        headers,
        body: String::from_utf8_lossy(&body).into_owned(),
    }
}

fn chunks() -> String {
    [
        r#"{"choices":[{"delta":{"content":"SELECT "}}]}"#,
        r#"{"choices":[{"delta":{"content":"1;"},"finish_reason":"stop"}]}"#,
        r#"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#,
        "[DONE]",
    ]
    .iter()
    .map(|data| format!("data: {data}\n\n"))
    .collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_saved_connection_keeps_the_ai_policy_it_was_given() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shop.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    let library = core.library().unwrap();

    let new = library
        .save(record(&path, None), ConnectionSecrets::default())
        .await
        .unwrap();
    let never = library
        .save(
            ConnectionRecord {
                ai_policy: Some(AiPolicyTag::Never),
                ..new.clone()
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();
    let kept = library
        .save(
            ConnectionRecord {
                ai_policy: None,
                name: "shop (prod)".to_owned(),
                ..never.clone()
            },
            ConnectionSecrets::default(),
        )
        .await
        .unwrap();

    assert_eq!(new.ai_policy, Some(AiPolicyTag::Ask));
    assert_eq!(never.ai_policy, Some(AiPolicyTag::Never));
    assert_eq!(kept.ai_policy, Some(AiPolicyTag::Never));
}

#[tokio::test(flavor = "multi_thread")]
async fn under_never_nothing_from_the_connection_reaches_the_provider() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shop.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    shop(&core, &path).await.close().await.unwrap();
    let saved = core
        .library()
        .unwrap()
        .save(record(&path, Some(AiPolicyTag::Never)), ConnectionSecrets::default())
        .await
        .unwrap();
    let session = connect(&core, saved.id).await;
    let server = Server::start(Answer::Ok {
        content_type: "text/event-stream",
        body: chunks(),
    });
    let assistant = core.ai_assistant();

    let started = assistant
        .start_conversation(
            session.clone(),
            AiConversationArg {
                engine: "SQLite".to_owned(),
                asked: "orders".to_owned(),
                editor: None,
                database: None,
            },
            None,
        )
        .await;
    let reply = assistant.reply(
        session.clone(),
        compatible(&server.address),
        question("orders?"),
        Box::new(Quiet),
    );
    let events = read_to_end(&reply).await;

    assert!(
        matches!(&started, Err(CoreError::Failed { info }) if info.code == "ai.blocked"),
        "{started:?}"
    );
    assert!(
        matches!(events.as_slice(), [AiReplyEvent::Failed { error }] if error.code == "ai.blocked"),
        "{events:?}"
    );
    assert!(server.seen().is_empty());
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_conversation_carries_the_structure_of_the_tables_its_question_names() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("shop.sqlite");
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &path).await;

    let started = core
        .ai_assistant()
        .start_conversation(
            session.clone(),
            AiConversationArg {
                engine: "SQLite".to_owned(),
                asked: "Which customers have no orders?".to_owned(),
                editor: Some("SELECT * FROM audit;".to_owned()),
                database: None,
            },
            None,
        )
        .await
        .unwrap();

    assert_eq!(started.described, ["audit", "customers", "orders"]);
    let system = started.system;
    assert!(system.contains("connected to a SQLite database"), "{system}");
    assert!(
        system.contains("\"orders\" (\"id\" INTEGER primary key, \"customer_id\" INTEGER, \"total\" REAL)"),
        "{system}"
    );
    assert!(system.contains("```sql\nSELECT * FROM audit;\n```"), "{system}");
    assert!(!system.contains("Ada Lovelace"), "a row reached the prompt: {system}");
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_streams_with_the_key_from_the_store_and_ends_with_its_usage() {
    let dir = tempfile::tempdir().unwrap();
    let secrets = MemorySecrets::default();
    let core = core(dir.path(), secrets.clone());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;
    let server = Server::start(Answer::Ok {
        content_type: "text/event-stream",
        body: chunks(),
    });
    let assistant = core.ai_assistant();

    assistant
        .set_key(AiProviderTag::OpenAiCompatible, SecretString::from(" sk-local \n"))
        .await
        .unwrap();
    let has_key = assistant.has_key(AiProviderTag::OpenAiCompatible).await.unwrap();
    let reply = assistant.reply(
        session.clone(),
        compatible(&server.address),
        question("one row?"),
        Box::new(Quiet),
    );
    let events = read_to_end(&reply).await;
    assistant
        .set_key(AiProviderTag::OpenAiCompatible, SecretString::from("  "))
        .await
        .unwrap();
    let removed = !assistant.has_key(AiProviderTag::OpenAiCompatible).await.unwrap();

    assert!(has_key);
    assert!(removed);
    assert!(secrets.items.lock().unwrap().is_empty());
    assert_eq!(text_of(&events), "SELECT 1;");
    assert_eq!(
        events.last(),
        Some(&AiReplyEvent::Finished {
            stop: AiStopTag::Complete,
            input_tokens: Some(12),
            output_tokens: Some(3),
        })
    );
    let seen = server.seen();
    let request = seen.first().expect("the request");
    assert_eq!(request.request_line, "POST /v1/chat/completions HTTP/1.1");
    assert_eq!(
        request.headers.get("authorization").map(String::as_str),
        Some("Bearer sk-local")
    );
    assert!(request.body.contains("\"model\":\"test-model\""), "{}", request.body);
    assert!(request.body.contains("one row?"), "{}", request.body);
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refused_key_names_the_host_and_keeps_the_providers_words() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;
    let server = Server::start(Answer::Status(
        401,
        r#"{"error":{"message":"invalid api key"}}"#.to_owned(),
    ));

    let reply = core.ai_assistant().reply(
        session.clone(),
        compatible(&server.address),
        question("hello"),
        Box::new(Quiet),
    );
    let events = read_to_end(&reply).await;

    let [AiReplyEvent::Failed { error }] = events.as_slice() else {
        panic!("{events:?}");
    };
    assert_eq!(error.code, "ai.unauthorized");
    assert_eq!(error.ai.as_ref().and_then(|ai| ai.host.as_deref()), Some("127.0.0.1"));
    assert_eq!(
        error.server.as_ref().map(|server| server.message.as_str()),
        Some("invalid api key")
    );
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_hosted_provider_with_no_key_is_refused_before_any_request() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;

    let reply = core.ai_assistant().reply(
        session.clone(),
        AiSettingsArg {
            provider: AiProviderTag::Anthropic,
            model: "claude-opus-5-5".to_owned(),
            address: None,
        },
        question("hello"),
        Box::new(Quiet),
    );
    let events = read_to_end(&reply).await;

    let [AiReplyEvent::Failed { error }] = events.as_slice() else {
        panic!("{events:?}");
    };
    assert_eq!(error.code, "ai.missing_key");
    assert_eq!(
        error.ai.as_ref().and_then(|ai| ai.provider),
        Some(AiProviderTag::Anthropic)
    );
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cancelled_reply_ends_as_stopped() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;
    let server = Server::start(Answer::Stalls);

    let reply = core.ai_assistant().reply(
        session.clone(),
        compatible(&server.address),
        question("hello"),
        Box::new(Quiet),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while server.seen().is_empty() {
        assert!(Instant::now() < deadline, "the request never arrived");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    reply.cancel();
    let events = read_to_end(&reply).await;

    assert_eq!(events, [AiReplyEvent::Stopped]);
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn the_models_listed_come_back_sorted() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let server = Server::start(Answer::Ok {
        content_type: "application/json",
        body: r#"{"object":"list","data":[{"id":"qwen3"},{"id":"llama3.2:latest"}]}"#.to_owned(),
    });

    let models = core
        .ai_assistant()
        .list_models(compatible(&server.address), None)
        .await
        .unwrap();

    let ids: Vec<&str> = models.iter().map(|model| model.id.as_str()).collect();
    assert_eq!(ids, ["llama3.2:latest", "qwen3"]);
    assert!(
        models
            .iter()
            .all(|model| !model.offline && !model.is_default && model.name.is_none())
    );
    assert_eq!(server.seen()[0].request_line, "GET /v1/models HTTP/1.1");
}

#[test]
fn a_hosted_provider_has_offline_models_and_a_default_and_the_compatible_server_has_none() {
    let dir = tempfile::tempdir().unwrap();
    let assistant = core(dir.path(), MemorySecrets::default()).ai_assistant();

    for provider in [AiProviderTag::Anthropic, AiProviderTag::OpenAi] {
        let offline = assistant.offline_models(provider);
        let default = assistant.default_model(provider).unwrap();
        assert!(offline.iter().all(|model| model.offline), "{provider:?}");
        assert!(
            offline.iter().any(|model| model.id == default),
            "{provider:?} {default}"
        );
    }
    assert!(assistant.offline_models(AiProviderTag::OpenAiCompatible).is_empty());
    assert_eq!(assistant.default_model(AiProviderTag::OpenAiCompatible), None);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_key_the_server_echoes_never_reaches_the_app() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;
    let server = Server::start(Answer::Status(
        401,
        r#"{"error":{"message":"the key sk-echoed-secret is not valid"}}"#.to_owned(),
    ));
    let assistant = core.ai_assistant();
    assistant
        .set_key(AiProviderTag::OpenAiCompatible, SecretString::from("sk-echoed-secret"))
        .await
        .unwrap();

    let events = read_to_end(&assistant.reply(
        session.clone(),
        compatible(&server.address),
        question("hello"),
        Box::new(Quiet),
    ))
    .await;
    let listed = assistant.list_models(compatible(&server.address), None).await;

    let [AiReplyEvent::Failed { error }] = events.as_slice() else {
        panic!("{events:?}");
    };
    assert_eq!(
        error.server.as_ref().map(|server| server.message.as_str()),
        Some("the key [redacted] is not valid")
    );
    assert!(!format!("{error:?}").contains("sk-echoed-secret"));
    assert!(!format!("{listed:?}").contains("sk-echoed-secret"), "{listed:?}");
    session.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_stops_with_its_session_and_a_closed_one_sends_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path(), MemorySecrets::default());
    let session = shop(&core, &dir.path().join("shop.sqlite")).await;
    let server = Server::start(Answer::Stalls);
    let assistant = core.ai_assistant();

    let reply = assistant.reply(
        session.clone(),
        compatible(&server.address),
        question("hello"),
        Box::new(Quiet),
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while server.seen().is_empty() {
        assert!(Instant::now() < deadline, "the request never arrived");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    session.close().await.unwrap();
    let during = read_to_end(&reply).await;
    let after = read_to_end(&assistant.reply(
        session.clone(),
        compatible(&server.address),
        question("again"),
        Box::new(Quiet),
    ))
    .await;

    assert_eq!(during, [AiReplyEvent::Stopped]);
    assert_eq!(after, [AiReplyEvent::Stopped]);
    assert_eq!(server.seen().len(), 1);
}
