use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use bytes::Bytes;
use http::header::{CACHE_CONTROL, CONTENT_TYPE};
use http::{Request, Response, StatusCode};
use http_body_util::Full;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio::sync::mpsc;
use tokio::task::JoinSet;

use crate::account_settings::CallbackPage;

const CALLBACK_PATH: &str = "/oauth/callback";
// The browser may still be reading the page when the answer is in.
const PAGE_GRACE: Duration = Duration::from_secs(2);

// RFC 8252 section 7.3: only a request carrying this sign-in's `state` ends the wait.
pub(crate) struct Loopback {
    listener: TcpListener,
    port: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Callback {
    Code(String),
    Refused { error: String, description: Option<String> },
}

impl Loopback {
    pub(crate) async fn bind() -> std::io::Result<Self> {
        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await?;
        let port = listener.local_addr()?.port();
        Ok(Self { listener, port })
    }

    pub(crate) fn redirect_uri(&self) -> String {
        format!("http://127.0.0.1:{}{CALLBACK_PATH}", self.port)
    }

    pub(crate) async fn wait(self, state: &str, page: &CallbackPage) -> std::io::Result<Callback> {
        let (answers, mut answered) = mpsc::channel(1);
        let mut connections = JoinSet::new();
        let callback = loop {
            tokio::select! {
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted?;
                    let (state, page, answers) = (state.to_owned(), page.clone(), answers.clone());
                    let service = service_fn(move |request: Request<Incoming>| {
                        let reply = reply(&request, &state, &page);
                        let answers = answers.clone();
                        async move {
                            if let Some(callback) = reply.callback {
                                let _ = answers.send(callback).await;
                            }
                            Ok::<_, Infallible>(reply.response)
                        }
                    });
                    connections.spawn(
                        http1::Builder::new()
                            .keep_alive(false)
                            .serve_connection(TokioIo::new(stream), service),
                    );
                }
                Some(callback) = answered.recv() => break callback,
            }
        };
        let _ = tokio::time::timeout(PAGE_GRACE, async { while connections.join_next().await.is_some() {} }).await;
        Ok(callback)
    }
}

struct Reply {
    callback: Option<Callback>,
    response: Response<Full<Bytes>>,
}

fn reply<B>(request: &Request<B>, state: &str, page: &CallbackPage) -> Reply {
    if request.uri().path() != CALLBACK_PATH {
        return Reply {
            callback: None,
            response: html(StatusCode::NOT_FOUND, &page.unknown),
        };
    }
    match callback(request.uri().query().unwrap_or_default(), state) {
        Some(callback) => Reply {
            callback: Some(callback),
            response: html(StatusCode::OK, &page.finished),
        },
        None => Reply {
            callback: None,
            response: html(StatusCode::BAD_REQUEST, &page.unknown),
        },
    }
}

pub(crate) fn callback(query: &str, state: &str) -> Option<Callback> {
    let (mut code, mut error, mut description, mut returned) = (None, None, None, None);
    for (name, value) in url::form_urlencoded::parse(query.as_bytes()) {
        match &*name {
            "code" => code = Some(value.into_owned()),
            "error" => error = Some(value.into_owned()),
            "error_description" => description = Some(value.into_owned()),
            "state" => returned = Some(value.into_owned()),
            _ => {}
        }
    }
    if returned.as_deref() != Some(state) {
        return None;
    }
    Some(match (code, error) {
        (_, Some(error)) => Callback::Refused { error, description },
        (Some(code), None) => Callback::Code(code),
        (None, None) => Callback::Refused {
            error: "invalid_request".to_owned(),
            description,
        },
    })
}

fn html(status: StatusCode, text: &str) -> Response<Full<Bytes>> {
    let body = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>TablePro</title><p>{}</p>\n",
        escape(text)
    );
    let mut response = Response::new(Full::new(Bytes::from(body)));
    *response.status_mut() = status;
    let headers = response.headers_mut();
    headers.insert(CONTENT_TYPE, http::HeaderValue::from_static("text/html; charset=utf-8"));
    headers.insert(CACHE_CONTROL, http::HeaderValue::from_static("no-store"));
    response
}

fn escape(text: &str) -> String {
    text.chars()
        .fold(String::with_capacity(text.len()), |mut escaped, character| {
            match character {
                '&' => escaped.push_str("&amp;"),
                '<' => escaped.push_str("&lt;"),
                '>' => escaped.push_str("&gt;"),
                '"' => escaped.push_str("&quot;"),
                other => escaped.push(other),
            }
            escaped
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page() -> CallbackPage {
        CallbackPage {
            finished: "Back to <TablePro>".to_owned(),
            unknown: "Not this sign-in".to_owned(),
        }
    }

    #[test]
    fn only_the_matching_state_answers() {
        assert_eq!(
            callback("code=abc&state=s1", "s1"),
            Some(Callback::Code("abc".to_owned()))
        );
        assert_eq!(callback("code=abc&state=s2", "s1"), None);
        assert_eq!(callback("code=abc", "s1"), None);
        assert_eq!(callback("", "s1"), None);
    }

    #[test]
    fn an_error_with_the_matching_state_ends_the_sign_in() {
        let refused = callback("error=access_denied&error_description=No+thanks&state=s1", "s1");

        assert_eq!(
            refused,
            Some(Callback::Refused {
                error: "access_denied".to_owned(),
                description: Some("No thanks".to_owned()),
            })
        );
    }

    #[test]
    fn the_page_text_is_escaped() {
        assert_eq!(escape(r#"<b>"x" & y</b>"#), "&lt;b&gt;&quot;x&quot; &amp; y&lt;/b&gt;");
    }

    #[tokio::test]
    async fn the_listener_keeps_waiting_past_other_requests_for_its_state() {
        let loopback = Loopback::bind().await.expect("a loopback port");
        let redirect = loopback.redirect_uri();
        let base = redirect.trim_end_matches(CALLBACK_PATH).to_owned();
        let waiting = tokio::spawn(async move { loopback.wait("s1", &page()).await });
        let http = reqwest::Client::new();

        let favicon = http.get(format!("{base}/favicon.ico")).send().await.expect("an answer");
        let forged = http
            .get(format!("{redirect}?code=evil&state=s2"))
            .send()
            .await
            .expect("an answer");
        let real = http
            .get(format!("{redirect}?code=abc&state=s1"))
            .send()
            .await
            .expect("an answer");
        let real_page = real.text().await.expect("the page");
        let callback = waiting.await.expect("the wait ends").expect("a callback");

        assert!(redirect.starts_with("http://127.0.0.1:"));
        assert_eq!(favicon.status(), StatusCode::NOT_FOUND);
        assert_eq!(forged.status(), StatusCode::BAD_REQUEST);
        assert!(real_page.contains("Back to &lt;TablePro&gt;"), "{real_page}");
        assert_eq!(callback, Callback::Code("abc".to_owned()));
    }
}
