use std::sync::{Mutex, PoisonError};

use tokio::sync::Notify;

use super::{MonitorSignal, PendingSignals};

/// Where signals wait while the monitor is busy.
///
/// Posting never blocks and never awaits, so a UI callback or a
/// finishing operation can drop a signal here from anywhere. The std
/// mutex is held only long enough to merge, never across an await.
#[derive(Default)]
pub struct MonitorMailbox {
    pending: Mutex<PendingSignals>,
    notify: Notify,
}

impl MonitorMailbox {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn post(&self, signal: MonitorSignal) {
        // A poisoned lock means some other poster panicked mid-merge.
        // The worst case is one stale field, which is not worth losing
        // every later signal over.
        self.pending
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .merge(signal);
        self.notify.notify_one();
    }

    /// The signals that have arrived, waiting for the first if there
    /// are none yet.
    pub async fn next(&self) -> PendingSignals {
        loop {
            let taken = self.pending.lock().unwrap_or_else(PoisonError::into_inner).take();
            if !taken.is_empty() {
                return taken;
            }
            self.notify.notified().await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::LinkGeneration;
    use super::*;

    #[tokio::test]
    async fn merge_keeps_max_generation() {
        let mailbox = MonitorMailbox::new();

        for generation in [3, 9, 4] {
            mailbox.post(MonitorSignal::ConnectionLost {
                generation: LinkGeneration::new(generation),
            });
        }

        assert_eq!(mailbox.next().await.lost, Some(LinkGeneration::new(9)));
    }

    #[tokio::test]
    async fn retry_never_dropped_under_1000_posts() {
        let mailbox = MonitorMailbox::new();

        mailbox.post(MonitorSignal::RetryNow);
        for generation in 0..1_000 {
            mailbox.post(MonitorSignal::ProbeRequested {
                generation: LinkGeneration::new(generation),
            });
        }

        let signals = mailbox.next().await;
        assert!(signals.retry, "the user's retry was merged away");
        assert_eq!(signals.probe_requested, Some(LinkGeneration::new(999)));
    }

    #[tokio::test]
    async fn next_waits_for_the_first_signal() {
        let mailbox = std::sync::Arc::new(MonitorMailbox::new());
        let mailbox_for_post = mailbox.clone();

        let waiting = crate::test_support::paused_tasks().spawn_task(async move { mailbox.next().await });
        tokio::task::yield_now().await;
        mailbox_for_post.post(MonitorSignal::RetryNow);

        assert!(waiting.await.expect("the waiter").retry);
    }

    #[tokio::test]
    async fn next_drains_so_a_signal_is_delivered_once() {
        let mailbox = MonitorMailbox::new();
        mailbox.post(MonitorSignal::RetryNow);

        assert!(mailbox.next().await.retry);

        let second = tokio::time::timeout(std::time::Duration::from_millis(50), mailbox.next()).await;
        assert!(second.is_err(), "the same signal was delivered twice");
    }
}
