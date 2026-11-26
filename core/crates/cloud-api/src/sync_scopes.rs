use progenitor_client::Error;
use reqwest::StatusCode;
use reqwest::header::{ETAG, HeaderMap, HeaderName};

use crate::api_error::ApiError;
use crate::problem::answer_error;
use crate::v2;

const DPOP_NONCE: HeaderName = HeaderName::from_static("dpop-nonce");

// A poll of `GET /v2/sync/scopes` (core ADR 0051, Protocol): 304 while the body's strong ETag is the one the poll named.
#[derive(Debug)]
pub enum SyncScopesPoll {
    NotModified,
    Changed {
        scopes: Box<v2::types::SyncScopes>,
        // What the next poll names in `If-None-Match`.
        etag: Option<String>,
        // RFC 9449 section 9: the nonce the next DPoP proof carries.
        dpop_nonce: Option<String>,
    },
}

// `if_none_match` is the ETag of the body held; None asks for the body whatever it is. The generated client reads a
// 304 as an answer the document does not list, since it has no body.
pub async fn poll_sync_scopes(
    api: &v2::Client,
    if_none_match: Option<&str>,
    dpop: Option<&str>,
) -> Result<SyncScopesPoll, ApiError> {
    match api.list_sync_scopes(dpop, if_none_match).await {
        Ok(answer) => Ok(SyncScopesPoll::Changed {
            etag: text(answer.headers(), &ETAG),
            dpop_nonce: text(answer.headers(), &DPOP_NONCE),
            scopes: Box::new(answer.into_inner()),
        }),
        Err(Error::UnexpectedResponse(response)) if response.status() == StatusCode::NOT_MODIFIED => {
            match if_none_match {
                Some(_) => Ok(SyncScopesPoll::NotModified),
                None => Err(ApiError::Protocol(
                    "the server answered 304 to a poll that named no ETag".to_owned(),
                )),
            }
        }
        Err(error) => Err(answer_error(error).await),
    }
}

fn text(headers: &HeaderMap, name: &HeaderName) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use std::io::{BufRead as _, BufReader, Write as _};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    use super::*;
    use crate::Bearer;

    const ETAG_NOW: &str = r#""sVjN4xpcV1lKqGNa1iBcOxpQ3gGs3NnmP6FZVYqrhnE""#;
    const BODY: &str = r#"{"epoch":"epoch_01jbvh7pn9e3sv4bzq4rqk4kzh","scopes":[{"id":"personal","type":"personal","role":"owner","horizon":12,"epochs":[{"id":"epoch_01jbvh7pn9e3sv4bzq4rqk4kzh","kept_revision":0}],"writable":true,"policies":{},"quota":null}],"limits":{"record_bytes":262144,"body_bytes":8388608,"push_changes":500,"change_set_changes":10000,"page_records":500,"page_bytes":4194304,"json_depth":32,"team_key_holders":5000},"server_version":"0.3.0","capabilities":[],"idempotency_retention":86400,"poll_interval":60}"#;

    // Stands in for the server: 304 when If-None-Match names the current ETag, the body otherwise. Keeps each poll's
    // If-None-Match.
    fn server(asked: Arc<Mutex<Vec<Option<String>>>>, not_modified_always: bool) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}/v2", listener.local_addr().expect("its address"));
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
                let mut if_none_match = None;
                loop {
                    let mut line = String::new();
                    reader.read_line(&mut line).expect("a line");
                    if line.trim().is_empty() {
                        break;
                    }
                    if let Some((name, value)) = line.split_once(':')
                        && name.eq_ignore_ascii_case("if-none-match")
                    {
                        if_none_match = Some(value.trim().to_owned());
                    }
                }
                let current = not_modified_always || if_none_match.as_deref() == Some(ETAG_NOW);
                asked.lock().expect("the polls").push(if_none_match);
                let mut stream = stream;
                let answer = match current {
                    true => format!("HTTP/1.1 304 Not Modified\r\netag: {ETAG_NOW}\r\nconnection: close\r\n\r\n"),
                    false => format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\netag: {ETAG_NOW}\r\ndpop-nonce: n-1\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{BODY}",
                        BODY.len()
                    ),
                };
                stream.write_all(answer.as_bytes()).expect("the answer");
            }
        });
        base
    }

    fn client(base: &str) -> v2::Client {
        v2::Client::new_with_client(base, reqwest::Client::new(), Bearer::public())
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_poll_naming_the_current_etag_reads_304_and_any_other_the_body_with_its_etag() {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let api = client(&server(asked.clone(), false));

        let first = poll_sync_scopes(&api, None, None).await.expect("the body");
        let SyncScopesPoll::Changed {
            scopes,
            etag,
            dpop_nonce,
        } = first
        else {
            panic!("no body: {first:?}");
        };
        let idle = poll_sync_scopes(&api, etag.as_deref(), Some("proof"))
            .await
            .expect("an idle poll");
        let stale = poll_sync_scopes(&api, Some(r#""an-older-body""#), None)
            .await
            .expect("a poll after a change");

        assert_eq!(etag.as_deref(), Some(ETAG_NOW));
        assert_eq!(dpop_nonce.as_deref(), Some("n-1"));
        assert_eq!(scopes.scopes.len(), 1);
        assert_eq!(scopes.poll_interval, 60);
        assert!(matches!(idle, SyncScopesPoll::NotModified), "{idle:?}");
        assert!(
            matches!(&stale, SyncScopesPoll::Changed { etag, .. } if etag.as_deref() == Some(ETAG_NOW)),
            "{stale:?}"
        );
        assert_eq!(
            *asked.lock().expect("the polls"),
            [None, Some(ETAG_NOW.to_owned()), Some(r#""an-older-body""#.to_owned())]
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_304_to_a_poll_that_named_no_etag_is_refused() {
        let api = client(&server(Arc::new(Mutex::new(Vec::new())), true));

        let answered = poll_sync_scopes(&api, None, None).await;

        assert!(matches!(answered, Err(ApiError::Protocol(_))), "{answered:?}");
    }
}
