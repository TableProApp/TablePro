use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

type Answer = dyn Fn(&str, &str) -> (u16, String) + Send + Sync;

// Stands in for tablepro-cloud: `answer` gives the status and JSON body for a method and path.
pub(crate) struct CloudStub {
    pub(crate) url: String,
    requests: Arc<Mutex<Vec<String>>>,
}

impl CloudStub {
    pub(crate) fn start(answer: impl Fn(&str, &str) -> (u16, String) + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a free port");
        let url = format!("http://{}", listener.local_addr().expect("its address"));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let kept = requests.clone();
        let answer: Arc<Answer> = Arc::new(answer);
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let (kept, answer) = (kept.clone(), answer.clone());
                std::thread::spawn(move || serve(stream, &kept, &*answer));
            }
        });
        Self { url, requests }
    }

    // "METHOD /path" for each request, in the order they came.
    pub(crate) fn requests(&self) -> Vec<String> {
        self.requests.lock().expect("the requests").clone()
    }
}

fn serve(stream: TcpStream, kept: &Mutex<Vec<String>>, answer: &Answer) {
    let mut reader = BufReader::new(stream.try_clone().expect("a second handle"));
    let mut line = String::new();
    if reader.read_line(&mut line).unwrap_or(0) == 0 {
        return;
    }
    let mut words = line.split_whitespace();
    let method = words.next().unwrap_or_default().to_owned();
    let path = words
        .next()
        .unwrap_or_default()
        .split('?')
        .next()
        .unwrap_or_default()
        .to_owned();
    let mut length = 0;
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
    kept.lock().expect("the requests").push(format!("{method} {path}"));
    let (status, body) = answer(&method, &path);
    let reply = format!(
        "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    let mut writer = stream;
    let _ = writer.write_all(reply.as_bytes());
}
