//! An OpenAI-compatible server for the assistant's tests: real HTTP on
//! 127.0.0.1, as Ollama answers.

use std::sync::{Arc, Mutex};

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::task::AbortOnDropHandle;

/// An Ollama-like server on 127.0.0.1 that answers every request
/// with the same events, and keeps the request bodies.
pub(crate) struct Provider {
    pub port: u16,
    pub bodies: Arc<Mutex<Vec<String>>>,
    _serving: AbortOnDropHandle<()>,
}

pub(crate) fn serve(runtime: &crate::runtime::AppRuntime, events: &'static str) -> Provider {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a port");
    listener.set_nonblocking(true).expect("non-blocking");
    let port = listener.local_addr().expect("the address").port();
    let bodies = Arc::new(Mutex::new(Vec::new()));
    let kept = bodies.clone();
    let serving = runtime.tasks().spawn_owned(async move {
        let listener = tokio::net::TcpListener::from_std(listener).expect("a tokio listener");
        while let Ok((mut stream, _)) = listener.accept().await {
            let request = read_request(&mut stream).await;
            kept.lock().expect("the bodies").push(request);
            let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
            let _ = stream.write_all(format!("{head}{events}").as_bytes()).await;
            let _ = stream.shutdown().await;
        }
    });
    Provider {
        port,
        bodies,
        _serving: serving,
    }
}

async fn read_request(stream: &mut tokio::net::TcpStream) -> String {
    let mut read = Vec::new();
    let mut chunk = [0_u8; 4096];
    while let Ok(count) = stream.read(&mut chunk).await {
        if count == 0 {
            break;
        }
        read.extend_from_slice(&chunk[..count]);
        let text = String::from_utf8_lossy(&read).to_string();
        if let Some(end) = text.find("\r\n\r\n") {
            let length = text[..end]
                .lines()
                .find_map(|line| line.to_lowercase().strip_prefix("content-length:").map(str::to_owned))
                .and_then(|value| value.trim().parse::<usize>().ok())
                .unwrap_or(0);
            if read.len() >= end + 4 + length {
                return String::from_utf8_lossy(&read[end + 4..]).to_string();
            }
        }
    }
    String::new()
}
