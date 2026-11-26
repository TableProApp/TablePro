// A managed value change and the commits that act on the values, serialized (core ADR 0055; orchestrator ruling): a
// commit reads the values under a read it holds until it lands, and a change waits for every read in flight and holds
// new ones back, so it lands wholly before a commit or wholly after it.

use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use tokio::sync::Notify;

#[derive(Debug, Default)]
pub struct PolicyGate {
    state: Mutex<Gate>,
    // A change waits here for the reads to end, and for another change before it.
    drained: Condvar,
    // Reads held back by a change wait here.
    opened: Notify,
}

#[derive(Debug, Default)]
struct Gate {
    reads: usize,
    changing: bool,
}

// Ends its read when dropped.
#[derive(Debug)]
pub struct PolicyRead {
    gate: Arc<PolicyGate>,
}

impl PolicyGate {
    fn gate(&self) -> MutexGuard<'_, Gate> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub async fn read(self: &Arc<Self>) -> PolicyRead {
        loop {
            let opened = self.opened.notified();
            tokio::pin!(opened);
            // Registered before the flag is read, so a change ending in between still wakes this read.
            opened.as_mut().enable();
            {
                let mut gate = self.gate();
                if !gate.changing {
                    gate.reads += 1;
                    return PolicyRead { gate: Arc::clone(self) };
                }
            }
            opened.await;
        }
    }

    // Blocks the caller, never an async task, until no read is held: the host calls it from its own thread. A commit
    // holds its read only from its check until it lands, so the wait is one commit's.
    pub fn change<T>(&self, apply: impl FnOnce() -> T) -> T {
        let mut gate = self.gate();
        while gate.changing {
            gate = self.drained.wait(gate).unwrap_or_else(PoisonError::into_inner);
        }
        gate.changing = true;
        while gate.reads > 0 {
            gate = self.drained.wait(gate).unwrap_or_else(PoisonError::into_inner);
        }
        drop(gate);
        let applied = apply();
        self.gate().changing = false;
        self.drained.notify_all();
        self.opened.notify_waiters();
        applied
    }
}

impl Drop for PolicyRead {
    fn drop(&mut self) {
        let mut gate = self.gate.gate();
        gate.reads -= 1;
        if gate.reads == 0 {
            drop(gate);
            self.gate.drained.notify_all();
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_change_waits_for_a_read_in_flight_and_holds_new_ones_back() {
        let gate = Arc::new(PolicyGate::default());
        let changed = Arc::new(AtomicBool::new(false));
        let read = gate.read().await;

        let changing = {
            let (gate, changed) = (Arc::clone(&gate), Arc::clone(&changed));
            std::thread::spawn(move || gate.change(|| changed.store(true, Ordering::SeqCst)))
        };
        tokio::time::sleep(Duration::from_millis(50)).await;
        let during = changed.load(Ordering::SeqCst);
        let later = {
            let (gate, changed) = (Arc::clone(&gate), Arc::clone(&changed));
            tokio::spawn(async move {
                let _read = gate.read().await;
                changed.load(Ordering::SeqCst)
            })
        };
        tokio::time::sleep(Duration::from_millis(50)).await;
        drop(read);
        changing.join().unwrap();

        assert!(!during);
        assert!(later.await.unwrap());
    }
}
