//! The providers' wire protocols end to end, against an HTTP server on
//! 127.0.0.1 that answers the way each provider does.

#![expect(
    clippy::expect_used,
    reason = "the server and its helpers fail a test the way the test functions themselves do"
)]

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use futures_util::StreamExt;
use http::{Request, Response, StatusCode};
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use secrecy::SecretString;
use tablepro_ai::{
    AiClient, AiError, ChatMessage, ChatRequest, Endpoint, ReplyEnd, ReplyEvent, StopReason, Usage, collect_reply,
    list_models, stream_reply,
};
use tablepro_core::AiProvider;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

type BoxedBody = http_body_util::combinators::BoxBody<Bytes, Infallible>;

#[derive(Clone)]
enum Answer {
    Events {
        content_type: &'static str,
        body: String,
    },
    /// The first event, then nothing more until the client goes.
    Stalls(String),
    Status(StatusCode, String),
    Json(String),
}

#[derive(Debug, Clone)]
struct Seen {
    method: String,
    path: String,
    headers: http::HeaderMap,
    body: serde_json::Value,
}

struct Server {
    address: SocketAddr,
    seen: Arc<Mutex<Vec<Seen>>>,
}

impl Server {
    /// A server that knows no model by name, as a compatible one.
    async fn start(answer: Answer) -> Self {
        Self::serve(answer, None).await
    }

    /// A server whose Models API describes the model as `info`.
    async fn with_model_info(answer: Answer, info: &str) -> Self {
        Self::serve(answer, Some(info.to_owned())).await
    }

    async fn serve(answer: Answer, model_info: Option<String>) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("the test server");
        let address = listener.local_addr().expect("the test server");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorded = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let answer = answer.clone();
                let model_info = model_info.clone();
                let recorded = recorded.clone();
                tokio::spawn(async move {
                    let service = service_fn(move |request: Request<Incoming>| {
                        let answer = answer.clone();
                        let model_info = model_info.clone();
                        let recorded = recorded.clone();
                        async move { Ok::<_, Infallible>(respond(request, answer, model_info, recorded).await) }
                    });
                    let _ = http1::Builder::new()
                        .serve_connection(TokioIo::new(stream), service)
                        .await;
                });
            }
        });
        Self { address, seen }
    }

    fn base(&self) -> String {
        format!("http://{}/v1", self.address)
    }

    fn seen(&self) -> Vec<Seen> {
        self.seen.lock().expect("the test server").clone()
    }
}

async fn respond(
    request: Request<Incoming>,
    answer: Answer,
    model_info: Option<String>,
    recorded: Arc<Mutex<Vec<Seen>>>,
) -> Response<BoxedBody> {
    let (parts, body) = request.into_parts();
    let bytes = body.collect().await.map(|body| body.to_bytes()).unwrap_or_default();
    let describes_a_model = parts.method == http::Method::GET && parts.uri.path().starts_with("/v1/models/");
    recorded.lock().expect("the test server").push(Seen {
        method: parts.method.to_string(),
        path: parts.uri.path_and_query().map(ToString::to_string).unwrap_or_default(),
        headers: parts.headers,
        body: serde_json::from_slice(&bytes).unwrap_or(serde_json::Value::Null),
    });
    let answer = match (describes_a_model, model_info) {
        (true, Some(info)) => Answer::Json(info),
        (true, None) => Answer::Status(
            StatusCode::NOT_FOUND,
            r#"{"type":"error","error":{"type":"not_found_error","message":"model: m"}}"#.to_owned(),
        ),
        (false, _) => answer,
    };
    match answer {
        Answer::Events { content_type, body } => Response::builder()
            .header("content-type", content_type)
            .body(Full::new(Bytes::from(body)).boxed())
            .expect("the test server"),
        Answer::Stalls(first) => {
            let frames = futures_util::stream::iter([Ok::<_, Infallible>(Frame::data(Bytes::from(first)))])
                .chain(futures_util::stream::pending());
            Response::builder()
                .header("content-type", "text/event-stream")
                .body(BodyExt::boxed(StreamBody::new(frames)))
                .expect("the test server")
        }
        Answer::Status(status, body) => Response::builder()
            .status(status)
            .header("content-type", "application/json")
            .body(Full::new(Bytes::from(body)).boxed())
            .expect("the test server"),
        Answer::Json(body) => Response::builder()
            .header("content-type", "application/json")
            .body(Full::new(Bytes::from(body)).boxed())
            .expect("the test server"),
    }
}

fn sse(events: &[(&str, &str)]) -> String {
    events
        .iter()
        .map(|(event, data)| {
            if event.is_empty() {
                format!("data: {data}\n\n")
            } else {
                format!("event: {event}\ndata: {data}\n\n")
            }
        })
        .collect()
}

fn anthropic_reply() -> String {
    sse(&[
        (
            "message_start",
            r#"{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":42,"output_tokens":1}}}"#,
        ),
        (
            "content_block_start",
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        ),
        ("ping", r#"{"type":"ping"}"#),
        (
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
        ),
        (
            "content_block_start",
            r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
        ),
        (
            "content_block_delta",
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"SELECT "}}"#,
        ),
        (
            "content_block_delta",
            r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"1;"}}"#,
        ),
        ("content_block_stop", r#"{"type":"content_block_stop","index":1}"#),
        (
            "message_delta",
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}"#,
        ),
        ("message_stop", r#"{"type":"message_stop"}"#),
    ])
}

fn request() -> ChatRequest {
    ChatRequest {
        system: "You help with SQL.".to_owned(),
        messages: vec![ChatMessage::user("Count the rows")],
        max_tokens: ChatRequest::CHAT_MAX_TOKENS,
    }
}

fn client() -> AiClient {
    AiClient::new("0.0.0-test").expect("the test server")
}

async fn events_of(endpoint: &Endpoint, cancel: CancellationToken) -> Vec<ReplyEvent> {
    let (sender, mut receiver) = mpsc::unbounded_channel();
    stream_reply(&client(), endpoint, &request(), cancel, sender).await;
    let mut events = Vec::new();
    while let Some(event) = receiver.recv().await {
        events.push(event);
    }
    events
}

#[tokio::test(flavor = "multi_thread")]
async fn an_anthropic_reply_streams_its_text_and_ends_with_the_usage() {
    let server = Server::start(Answer::Events {
        content_type: "text/event-stream",
        body: anthropic_reply(),
    })
    .await;
    let endpoint = Endpoint::new(
        AiProvider::Anthropic,
        &server.base(),
        "claude-opus-5-5",
        Some(SecretString::from("sk-ant-test")),
    )
    .unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert_eq!(
        events,
        vec![
            ReplyEvent::Text("SELECT ".to_owned()),
            ReplyEvent::Text("1;".to_owned()),
            ReplyEvent::Finished(ReplyEnd {
                stop: StopReason::Complete,
                usage: Usage {
                    input_tokens: Some(42),
                    output_tokens: Some(9),
                },
            }),
        ]
    );
    let seen = server.seen();
    assert_eq!(seen[0].path, "/v1/models/claude-opus-5-5");
    let request = &seen[1];
    assert_eq!(request.method, "POST");
    assert_eq!(request.path, "/v1/messages");
    assert_eq!(request.headers["x-api-key"], "sk-ant-test");
    assert_eq!(request.headers["anthropic-version"], "2026-10-21");
    assert!(request.headers.get("authorization").is_none());
    assert_eq!(request.body["model"], "claude-opus-5-5");
    assert_eq!(request.body["max_tokens"], ChatRequest::CHAT_MAX_TOKENS);
    assert_eq!(request.body["system"], "You help with SQL.");
    assert_eq!(request.body["messages"][0]["content"], "Count the rows");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_anthropic_request_asks_for_no_more_than_the_model_writes() {
    let server = Server::with_model_info(
        Answer::Events {
            content_type: "text/event-stream",
            body: anthropic_reply(),
        },
        r#"{"type":"model","id":"claude-opus-4-0","max_input_tokens":200000,"max_tokens":32000}"#,
    )
    .await;
    let endpoint = Endpoint::new(
        AiProvider::Anthropic,
        &server.base(),
        "claude-opus-4-0",
        Some(SecretString::from("k")),
    )
    .unwrap();
    let client = client();

    for _ in 0..2 {
        let (text, _) = collect_reply(&client, &endpoint, &request()).await.unwrap();
        assert_eq!(text, "SELECT 1;");
    }

    let seen = server.seen();
    let lookups = seen.iter().filter(|seen| seen.method == "GET").count();
    let asked: Vec<_> = seen
        .iter()
        .filter(|seen| seen.method == "POST")
        .map(|seen| seen.body["max_tokens"].clone())
        .collect();
    assert_eq!(lookups, 1, "the limit is read once per model");
    assert_eq!(asked, [32000, 32000]);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_ollama_reply_streams_until_done() {
    let body = sse(&[
        (
            "",
            r#"{"choices":[{"index":0,"delta":{"role":"assistant","content":"SEL"}}]}"#,
        ),
        ("", r#"{"choices":[{"index":0,"delta":{"content":"ECT 1"}}]}"#),
        ("", r#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#),
        ("", "[DONE]"),
    ]);
    let server = Server::start(Answer::Events {
        content_type: "text/event-stream",
        body,
    })
    .await;
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &server.base(), "llama3.2", None).unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert_eq!(
        events,
        vec![
            ReplyEvent::Text("SEL".to_owned()),
            ReplyEvent::Text("ECT 1".to_owned()),
            ReplyEvent::Finished(ReplyEnd::default()),
        ]
    );
    let seen = server.seen();
    assert_eq!(seen[0].path, "/v1/chat/completions");
    assert!(seen[0].headers.get("authorization").is_none(), "no key, no header");
    assert_eq!(seen[0].body["messages"][0]["role"], "system");
}

#[tokio::test(flavor = "multi_thread")]
async fn openai_gets_the_key_as_a_bearer_token() {
    let body = sse(&[
        (
            "",
            r#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
        ),
        (
            "",
            r#"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":1,"total_tokens":6}}"#,
        ),
        ("", "[DONE]"),
    ]);
    let server = Server::start(Answer::Events {
        content_type: "text/event-stream",
        body,
    })
    .await;
    let endpoint = Endpoint::new(
        AiProvider::OpenAi,
        &server.base(),
        "gpt-test",
        Some(SecretString::from("sk-o")),
    )
    .unwrap();

    let (text, end) = collect_reply(&client(), &endpoint, &request()).await.unwrap();

    assert_eq!(text, "ok");
    assert_eq!(end.usage.total(), Some(6));
    assert_eq!(server.seen()[0].headers["authorization"], "Bearer sk-o");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refused_key_fails_with_the_providers_words() {
    let server = Server::start(Answer::Status(
        StatusCode::UNAUTHORIZED,
        r#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.to_owned(),
    ))
    .await;
    let endpoint = Endpoint::new(
        AiProvider::Anthropic,
        &server.base(),
        "m",
        Some(SecretString::from("wrong")),
    )
    .unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert_eq!(
        events,
        vec![ReplyEvent::Failed(AiError::Unauthorized {
            host: "127.0.0.1".to_owned(),
            message: Some("invalid x-api-key".to_owned()),
        })]
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_cut_before_its_end_is_a_failure_not_an_answer() {
    let mut body = anthropic_reply();
    let cut = body.find("event: message_delta").unwrap();
    body.truncate(cut);
    let server = Server::start(Answer::Events {
        content_type: "text/event-stream",
        body,
    })
    .await;
    let endpoint = Endpoint::new(
        AiProvider::Anthropic,
        &server.base(),
        "m",
        Some(SecretString::from("k")),
    )
    .unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert!(
        matches!(events.last(), Some(ReplyEvent::Failed(AiError::Protocol(_)))),
        "{events:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stopped_reply_sends_nothing_after_the_stop() {
    let server = Server::start(Answer::Stalls(sse(&[(
        "",
        r#"{"choices":[{"index":0,"delta":{"content":"partial"}}]}"#,
    )])))
    .await;
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &server.base(), "m", None).unwrap();
    let (sender, mut receiver) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();
    let stop = cancel.clone();
    let reading = tokio::spawn(async move { stream_reply(&client(), &endpoint, &request(), cancel, sender).await });

    let first = tokio::time::timeout(Duration::from_secs(10), receiver.recv())
        .await
        .unwrap();
    stop.cancel();
    tokio::time::timeout(Duration::from_secs(10), reading)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(first, Some(ReplyEvent::Text("partial".to_owned())));
    assert_eq!(receiver.recv().await, None, "nothing follows a stop");
}

#[tokio::test(flavor = "multi_thread")]
async fn no_model_is_refused_before_anything_is_sent() {
    let server = Server::start(Answer::Json("{}".to_owned())).await;
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &server.base(), "  ", None).unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert_eq!(events, vec![ReplyEvent::Failed(AiError::MissingModel)]);
    assert!(server.seen().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn the_models_are_listed_sorted() {
    let server = Server::start(Answer::Json(
        r#"{"object":"list","data":[{"id":"qwen3"},{"id":"llama3.2:latest"},{"id":"qwen3"}]}"#.to_owned(),
    ))
    .await;
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &server.base(), "", None).unwrap();

    let models = list_models(&client(), &endpoint).await.unwrap();

    assert_eq!(models, ["llama3.2:latest", "qwen3"]);
    let seen = server.seen();
    assert_eq!(seen[0].method, "GET");
    assert_eq!(seen[0].path, "/v1/models");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_closed_port_says_it_could_not_reach_the_host() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &format!("http://{address}/v1"), "m", None).unwrap();

    let models = list_models(&client(), &endpoint).await;

    assert!(
        matches!(models, Err(AiError::Unreachable { ref host, .. }) if host == "127.0.0.1"),
        "{models:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stream_that_never_ends_a_line_is_cut_off() {
    let body = format!("data: {}", "x".repeat(33 * 1024 * 1024));
    let server = Server::start(Answer::Events {
        content_type: "text/event-stream",
        body,
    })
    .await;
    let endpoint = Endpoint::new(AiProvider::OpenAiCompatible, &server.base(), "m", None).unwrap();

    let events = events_of(&endpoint, CancellationToken::new()).await;

    assert_eq!(events, vec![ReplyEvent::Failed(AiError::TooLong)]);
}
