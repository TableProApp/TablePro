use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::accept_loop::AcceptLoop;

// Stands in for PostHog: answers every request and keeps each body.
pub(crate) struct PostHogCollector {
    pub(crate) url: String,
    connections: Arc<Mutex<usize>>,
    bodies: Arc<Mutex<Vec<String>>>,
    held: Arc<AtomicBool>,
    _accepting: AcceptLoop,
}

impl PostHogCollector {
    pub(crate) fn start() -> Self {
        Self::answering(200)
    }

    pub(crate) fn answering(status: u16) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
        let connections = Arc::new(Mutex::new(0));
        let bodies = Arc::new(Mutex::new(Vec::new()));
        let held = Arc::new(AtomicBool::new(false));
        let (counted, kept, holding) = (connections.clone(), bodies.clone(), held.clone());
        let accepting = AcceptLoop::start(listener, move |stream| {
            *counted.lock().expect("the count") += 1;
            let (kept, holding) = (kept.clone(), holding.clone());
            std::thread::spawn(move || answer(stream, &kept, status, &holding));
        });
        Self {
            url: accepting.url(),
            connections,
            bodies,
            held,
            _accepting: accepting,
        }
    }

    // Until release, a request is kept but not answered, as by a slow PostHog.
    pub(crate) fn hold(&self) {
        self.held.store(true, Ordering::SeqCst);
    }

    pub(crate) fn release(&self) {
        self.held.store(false, Ordering::SeqCst);
    }

    pub(crate) fn connections(&self) -> usize {
        *self.connections.lock().expect("the count")
    }

    pub(crate) fn bodies(&self) -> Vec<String> {
        self.bodies.lock().expect("the bodies").clone()
    }

    pub(crate) fn events(&self) -> Vec<serde_json::Value> {
        self.bodies
            .lock()
            .expect("the bodies")
            .iter()
            .filter_map(|body| serde_json::from_str::<serde_json::Value>(body).ok())
            .flat_map(|batch| batch["batch"].as_array().cloned().unwrap_or_default())
            .collect()
    }

    pub(crate) fn named(&self, name: &str) -> Vec<serde_json::Value> {
        self.events()
            .into_iter()
            .filter(|event| event["event"] == name)
            .collect()
    }
}

fn answer(stream: std::net::TcpStream, kept: &Mutex<Vec<String>>, status: u16, held: &AtomicBool) {
    let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
    let mut writer = stream;
    loop {
        let mut length = 0;
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            if line == "\r\n" {
                break;
            }
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().unwrap_or(0);
            }
        }
        let mut body = vec![0; length];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        kept.lock()
            .expect("the bodies")
            .push(String::from_utf8_lossy(&body).into_owned());
        while held.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(10));
        }
        let reply = format!(
            "HTTP/1.1 {status} Collector\r\ncontent-type: application/json\r\ncontent-length: 12\r\n\r\n{{\"status\":1}}"
        );
        if writer.write_all(reply.as_bytes()).is_err() {
            return;
        }
    }
}
