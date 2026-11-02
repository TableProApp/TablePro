use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use crate::lock;

/// The faults every stream of one `FaultTransport` shares, so a fault
/// set after a stream was opened still reaches it.
#[derive(Debug, Default)]
pub(super) struct FaultState {
    black_holed: AtomicBool,
    stall_pattern: Mutex<Option<Vec<u8>>>,
    stalls: AtomicUsize,
}

impl FaultState {
    pub(super) fn black_hole(&self) {
        self.black_holed.store(true, Ordering::SeqCst);
    }

    pub(super) fn is_black_holed(&self) -> bool {
        self.black_holed.load(Ordering::SeqCst)
    }

    pub(super) fn arm_stall(&self, pattern: Vec<u8>) {
        *lock(&self.stall_pattern) = Some(pattern);
    }

    pub(super) fn stall_pattern_len(&self) -> Option<usize> {
        lock(&self.stall_pattern).as_ref().map(Vec::len)
    }

    /// Whether `written` holds the armed pattern. The first stream to
    /// write it takes the stall, so a later connection that writes the
    /// same bytes, such as the one resolving the commit, still works.
    pub(super) fn take_stall(&self, written: &[u8]) -> bool {
        let mut armed = lock(&self.stall_pattern);
        let found = armed.as_deref().is_some_and(|pattern| {
            !pattern.is_empty() && written.windows(pattern.len()).any(|window| window == pattern)
        });
        if found {
            *armed = None;
            self.stalls.fetch_add(1, Ordering::SeqCst);
        }
        found
    }

    pub(super) fn stalls(&self) -> usize {
        self.stalls.load(Ordering::SeqCst)
    }
}
