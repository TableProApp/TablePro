use std::{
    io::Read,
    sync::atomic::{AtomicI32, Ordering},
};

/// Closure to obtain a new, unique request ID.
pub(crate) fn next_request_id() -> i32 {
    static REQUEST_ID: AtomicI32 = AtomicI32::new(0);

    REQUEST_ID.fetch_add(1, Ordering::SeqCst)
}

pub(super) struct SyncCountReader<R> {
    reader: R,
    bytes_read: usize,
}

impl<R: Read> SyncCountReader<R> {
    /// Constructs a new CountReader that wraps `reader`.
    pub(super) fn new(reader: R) -> Self {
        SyncCountReader {
            reader,
            bytes_read: 0,
        }
    }

    /// Gets the number of bytes read so far.
    pub(super) fn bytes_read(&self) -> usize {
        self.bytes_read
    }
}

impl<R: Read> Read for SyncCountReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let bytes = self.reader.read(buf)?;
        self.bytes_read += bytes;
        Ok(bytes)
    }
}
