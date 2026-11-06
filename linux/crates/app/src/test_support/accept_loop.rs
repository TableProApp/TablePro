use std::io::ErrorKind;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

// A local server's accept loop, which closes its listener when dropped: the gtk suite is one process.
pub(crate) struct AcceptLoop {
    address: SocketAddr,
    stopped: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl AcceptLoop {
    pub(crate) fn start(listener: TcpListener, serve: impl Fn(TcpStream) + Send + 'static) -> Self {
        let address = listener.local_addr().expect("the listener's address");
        // Polled, so stopping needs no connection, which a process out of descriptors cannot make.
        listener.set_nonblocking(true).expect("a non-blocking listener");
        let stopped = Arc::new(AtomicBool::new(false));
        let stopping = stopped.clone();
        let thread = std::thread::spawn(move || {
            while !stopping.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => {
                        if stream.set_nonblocking(false).is_ok() {
                            serve(stream);
                        }
                    }
                    Err(error) if error.kind() == ErrorKind::Interrupted => {}
                    Err(_) => std::thread::sleep(Duration::from_millis(5)),
                }
            }
        });
        Self {
            address,
            stopped,
            thread: Some(thread),
        }
    }

    pub(crate) fn url(&self) -> String {
        format!("http://{}", self.address)
    }
}

impl Drop for AcceptLoop {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
