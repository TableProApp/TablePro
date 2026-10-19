use std::sync::{Arc, Mutex, PoisonError};

/// What this thread logs, as text.
#[derive(Clone, Default)]
pub(crate) struct LogLines(Arc<Mutex<Vec<u8>>>);

impl LogLines {
    /// A subscriber that writes here, for `tracing::subscriber::set_default`.
    pub(crate) fn subscriber(&self, level: tracing::Level) -> impl tracing::Subscriber + Send + Sync + 'static {
        let lines = self.clone();
        tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(level)
            .with_writer(move || lines.clone())
            .finish()
    }

    pub(crate) fn text(&self) -> String {
        let bytes = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        String::from_utf8_lossy(&bytes).into_owned()
    }
}

impl std::io::Write for LogLines {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
