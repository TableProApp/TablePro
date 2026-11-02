use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::{Arc, PoisonError, RwLock};
use std::time::Duration;

use bytes::Bytes;
use http::header::{AUTHORIZATION, CONTENT_TYPE, WWW_AUTHENTICATE};
use http::{Request, Response, StatusCode};
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full};
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::{TokioIo, TokioTimer};
use rmcp::transport::streamable_http_server::session::local::LocalSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use tablepro_session::runtime::Tasks;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use tokio_util::task::AbortOnDropHandle;

use crate::access_token::AccessToken;
use crate::tool_context::ToolContext;
use crate::tool_server::ToolServer;

pub const MCP_PATH: &str = "/mcp";

/// Connections served at once. A client holds one or two; the rest wait
/// until one closes rather than growing without bound.
const MAX_CONNECTIONS: usize = 32;

const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

/// A request body larger than this is refused before it is read: a
/// statement is at most 100 KB, and nothing else a client sends is big.
const MAX_REQUEST_BYTES: usize = 1024 * 1024;

type Service = StreamableHttpService<ToolServer, LocalSessionManager>;
type Body = BoxBody<Bytes, Infallible>;

#[derive(Debug, thiserror::Error)]
pub enum StartError {
    #[error("port {0} is in use")]
    PortInUse(u16),
    #[error("could not listen on 127.0.0.1:{port}: {source}")]
    Listen {
        port: u16,
        #[source]
        source: std::io::Error,
    },
}

/// The MCP server, listening on the loopback interface until it is
/// stopped or dropped.
pub struct McpServer {
    address: SocketAddr,
    token: Arc<RwLock<AccessToken>>,
    cancel: CancellationToken,
    accept: Option<AbortOnDropHandle<()>>,
}

impl McpServer {
    /// Listen on 127.0.0.1 alone. Port 0 takes any free port, for tests.
    pub async fn start(
        port: u16,
        token: AccessToken,
        context: ToolContext,
        version: &str,
        tasks: &Tasks,
    ) -> Result<Self, StartError> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, port))
            .await
            .map_err(|source| match source.kind() {
                std::io::ErrorKind::AddrInUse => StartError::PortInUse(port),
                _ => StartError::Listen { port, source },
            })?;
        let address = listener
            .local_addr()
            .map_err(|source| StartError::Listen { port, source })?;
        let cancel = CancellationToken::new();
        let tools = ToolServer::new(context, version);
        // Stateless: a client keeps nothing on the server between calls,
        // and the answers are plain JSON with no stream to hold open.
        let config = StreamableHttpServerConfig::default()
            .with_legacy_session_mode(false)
            .with_json_response(true)
            .with_sse_keep_alive(None)
            .with_allowed_hosts(["localhost", "127.0.0.1"])
            .enforce_origin_validation()
            .with_cancellation_token(cancel.child_token());
        let service = StreamableHttpService::new(move || Ok(tools.clone()), Arc::default(), config);
        let token = Arc::new(RwLock::new(token));
        let accept = tasks.spawn_owned(accept(listener, service, token.clone(), cancel.clone(), tasks.clone()));
        tracing::info!(%address, "MCP server listening");
        Ok(Self {
            address,
            token,
            cancel,
            accept: Some(accept),
        })
    }

    pub fn address(&self) -> SocketAddr {
        self.address
    }

    /// Stop, and return once the port is free again, so a restart on the
    /// same port can bind it.
    pub async fn shutdown(mut self) {
        self.cancel.cancel();
        if let Some(accept) = self.accept.take() {
            let _ = accept.await;
        }
    }

    /// Clients holding the old token are refused from the next request.
    pub fn replace_token(&self, token: AccessToken) {
        *self.token.write().unwrap_or_else(PoisonError::into_inner) = token;
    }
}

impl Drop for McpServer {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

async fn accept(
    listener: TcpListener,
    service: Service,
    token: Arc<RwLock<AccessToken>>,
    cancel: CancellationToken,
    tasks: Tasks,
) {
    let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    loop {
        let acquired = tokio::select! {
            () = cancel.cancelled() => return,
            permit = permits.clone().acquire_owned() => permit,
        };
        let Ok(permit) = acquired else {
            return;
        };
        let stream = tokio::select! {
            () = cancel.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => stream,
                Err(error) => {
                    // Out of file descriptors, most likely: wait rather
                    // than spin on an accept that fails at once.
                    tracing::debug!(%error, "MCP accept failed");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                }
            },
        };
        let (service, token, cancel) = (service.clone(), token.clone(), cancel.clone());
        drop(tasks.spawn_task(async move {
            serve(stream, service, token, cancel).await;
            drop(permit);
        }));
    }
}

async fn serve(stream: TcpStream, service: Service, token: Arc<RwLock<AccessToken>>, cancel: CancellationToken) {
    let handler = service_fn(move |request: Request<Incoming>| {
        let (service, token) = (service.clone(), token.clone());
        async move { Ok::<_, Infallible>(respond(&service, &token, request).await) }
    });
    let mut builder = http1::Builder::new();
    builder.timer(TokioTimer::new()).header_read_timeout(HEADER_TIMEOUT);
    let connection = builder.serve_connection(TokioIo::new(stream), handler);
    tokio::pin!(connection);
    tokio::select! {
        served = connection.as_mut() => {
            if let Err(error) = served {
                tracing::debug!(%error, "an MCP connection ended with an error");
            }
        }
        () = cancel.cancelled() => {
            connection.as_mut().graceful_shutdown();
            let _ = connection.await;
        }
    }
}

/// Every request presents the token before anything reads its body.
async fn respond(service: &Service, token: &RwLock<AccessToken>, request: Request<Incoming>) -> Response<Body> {
    if request.uri().path() != MCP_PATH {
        return plain(StatusCode::NOT_FOUND, "Not found");
    }
    let authorized = request.headers().get(AUTHORIZATION).is_some_and(|header| {
        token
            .read()
            .unwrap_or_else(PoisonError::into_inner)
            .authorizes(header.as_bytes())
    });
    if !authorized {
        let mut response = plain(StatusCode::UNAUTHORIZED, "A TablePro access token is required");
        response.headers_mut().insert(
            WWW_AUTHENTICATE,
            http::HeaderValue::from_static("Bearer realm=\"TablePro\""),
        );
        return response;
    }
    if declared_length(&request).is_some_and(|length| length > MAX_REQUEST_BYTES) {
        return plain(StatusCode::PAYLOAD_TOO_LARGE, "The request is too large");
    }
    let (parts, body) = request.into_parts();
    let limited = http_body_util::Limited::new(body, MAX_REQUEST_BYTES);
    service.handle(Request::from_parts(parts, limited)).await
}

fn declared_length(request: &Request<Incoming>) -> Option<usize> {
    request
        .headers()
        .get(http::header::CONTENT_LENGTH)?
        .to_str()
        .ok()?
        .parse()
        .ok()
}

fn plain(status: StatusCode, text: &'static str) -> Response<Body> {
    let mut response = Response::new(Full::new(Bytes::from_static(text.as_bytes())).boxed());
    *response.status_mut() = status;
    response.headers_mut().insert(
        CONTENT_TYPE,
        http::HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response
}
