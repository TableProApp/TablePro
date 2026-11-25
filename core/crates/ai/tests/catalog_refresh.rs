//! The model catalog's refresh, against an HTTP server on 127.0.0.1 that
//! answers as the update host does.

#![expect(
    clippy::expect_used,
    reason = "the server and its helpers fail a test the way the test functions themselves do"
)]

use std::convert::Infallible;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use http::{Request, Response, StatusCode};
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tablepro_ai::{AiClient, ModelCatalog};
use tokio::net::TcpListener;

const ETAG: &str = "\"v1\"";

fn catalog_text(generated: &str) -> String {
    format!(
        r#"{{"schema":1,"generated":"{generated}","providers":{{"openai":{{"default":"gpt-9","models":[
            {{"id":"gpt-9","name":"GPT-9","apis":["chat-completions"]}}]}}}}}}"#
    )
}

struct Host {
    url: String,
    seen: Arc<Mutex<Vec<http::HeaderMap>>>,
}

impl Host {
    /// Answers `body` with an ETag, and 304 to a request that sends it back.
    async fn start(body: String) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("the test server");
        let address = listener.local_addr().expect("the test server");
        let seen = Arc::new(Mutex::new(Vec::new()));
        let recorded = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let (body, recorded) = (body.clone(), recorded.clone());
                tokio::spawn(async move {
                    let service = service_fn(move |request: Request<Incoming>| {
                        let (body, recorded) = (body.clone(), recorded.clone());
                        async move { Ok::<_, Infallible>(answer(&request, body, &recorded)) }
                    });
                    let _ = http1::Builder::new()
                        .serve_connection(TokioIo::new(stream), service)
                        .await;
                });
            }
        });
        Self {
            url: format!("http://{address}/ai/models-v1.json"),
            seen,
        }
    }

    fn seen(&self) -> Vec<http::HeaderMap> {
        self.seen.lock().expect("the test server").clone()
    }
}

fn answer(request: &Request<Incoming>, body: String, recorded: &Mutex<Vec<http::HeaderMap>>) -> Response<Full<Bytes>> {
    recorded
        .lock()
        .expect("the test server")
        .push(request.headers().clone());
    let revalidated = request
        .headers()
        .get(http::header::IF_NONE_MATCH)
        .is_some_and(|tag| tag == ETAG);
    let builder = Response::builder().header(http::header::ETAG, ETAG);
    if revalidated {
        return builder
            .status(StatusCode::NOT_MODIFIED)
            .body(Full::new(Bytes::new()))
            .expect("the test server");
    }
    builder
        .header("content-type", "application/json")
        .body(Full::new(Bytes::from(body)))
        .expect("the test server")
}

fn client() -> AiClient {
    AiClient::new("0.0.0-test").expect("the client")
}

#[tokio::test(flavor = "multi_thread")]
async fn a_newer_copy_is_kept_and_asked_for_again_with_its_etag() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2999-01-01T00:00:00Z")).await;
    let catalog = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

    catalog.refresh(&client()).await;
    let next_run = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);
    next_run.refresh(&client()).await;

    assert_eq!(catalog.current().generated(), "2999-01-01T00:00:00Z");
    assert_eq!(next_run.current().generated(), "2999-01-01T00:00:00Z");
    assert_eq!(
        next_run.default_model(tablepro_core::AiProvider::OpenAi).as_deref(),
        Some("gpt-9")
    );
    let seen = host.seen();
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[0].get(http::header::IF_NONE_MATCH), None);
    assert_eq!(
        seen[1].get(http::header::IF_NONE_MATCH).map(|tag| tag.as_bytes()),
        Some(ETAG.as_bytes())
    );
}

// Linux and Windows save the default for an empty model before any list loads.
#[tokio::test(flavor = "multi_thread")]
async fn the_default_reads_the_copy_an_earlier_run_kept() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2999-01-01T00:00:00Z")).await;
    ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url)
        .refresh(&client())
        .await;

    let next_launch = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

    assert_eq!(
        next_launch.default_model(tablepro_core::AiProvider::OpenAi).as_deref(),
        Some("gpt-9")
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn the_request_carries_no_key_and_no_user_agent() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2999-01-01T00:00:00Z")).await;

    ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url)
        .refresh(&client())
        .await;

    let seen = host.seen();
    let mut names: Vec<&str> = seen[0].keys().map(http::HeaderName::as_str).collect();
    names.sort_unstable();
    assert_eq!(names, ["accept", "host"]);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_runs_at_most_once_an_hour() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2999-01-01T00:00:00Z")).await;
    let catalog = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

    catalog.refresh(&client()).await;
    catalog.refresh(&client()).await;

    assert_eq!(host.seen().len(), 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn an_older_copy_leaves_the_bundled_one_in_use() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2000-01-01T00:00:00Z")).await;
    let catalog = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

    catalog.refresh(&client()).await;

    assert_eq!(
        catalog.current().generated(),
        ModelCatalog::bundled().current().generated()
    );
    assert!(
        !dir.path().join("models-v1.json").exists(),
        "an older copy must not replace what the next launch reads"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reply_that_does_not_read_changes_nothing() {
    for body in [
        r#"{"schema":2,"generated":"2999-01-01T00:00:00Z","providers":{}}"#.to_owned(),
        "<html>".to_owned(),
    ] {
        let dir = tempfile::tempdir().expect("a folder");
        let host = Host::start(body).await;
        let catalog = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

        catalog.refresh(&client()).await;

        assert_eq!(
            catalog.current().generated(),
            ModelCatalog::bundled().current().generated()
        );
        assert_eq!(std::fs::read_dir(dir.path()).expect("the folder").count(), 0);
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unreachable_host_changes_nothing() {
    let dir = tempfile::tempdir().expect("a folder");
    // Port 1 is below every system's ephemeral range, so the request is refused.
    let catalog = ModelCatalog::refreshed_from(dir.path().join("ai-models"), "http://127.0.0.1:1/models-v1.json");

    catalog.refresh(&client()).await;

    assert!(!dir.path().join("ai-models").exists());
    assert!(catalog.default_model(tablepro_core::AiProvider::Anthropic).is_some());
}

// An organization that holds the app to its own server keeps it off tablepro.app hosts: the kept copy serves.
#[tokio::test(flavor = "multi_thread")]
async fn a_refresh_that_is_not_allowed_asks_nothing_and_the_kept_copy_serves() {
    let dir = tempfile::tempdir().expect("a folder");
    let host = Host::start(catalog_text("2999-01-01T00:00:00Z")).await;
    ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url)
        .refresh(&client())
        .await;
    let held = ModelCatalog::refreshed_from(dir.path().to_path_buf(), &host.url);

    held.allow_refresh(false);
    held.refresh(&client()).await;
    held.allow_refresh(true);
    held.refresh(&client()).await;

    assert_eq!(held.current().generated(), "2999-01-01T00:00:00Z");
    assert_eq!(host.seen().len(), 2);
}
