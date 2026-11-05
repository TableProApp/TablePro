//! The notices a session's connection hands to its runs, at most a run's
//! worth at a time.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};

/// Notices one run keeps. A loop that raises one per row would otherwise
/// grow the queue, and the results, for as long as it runs.
pub(crate) const NOTICES_PER_RUN: u64 = 10_000;

pub(crate) fn notice_channel<T>(limit: u64) -> (NoticeSender<T>, NoticeQueue<T>) {
    let budget = Arc::new(Budget {
        limit,
        admitted: AtomicU64::new(0),
        dropped: AtomicBool::new(false),
    });
    let (sender, receiver) = mpsc::unbounded_channel();
    (
        NoticeSender {
            sender,
            budget: Arc::clone(&budget),
        },
        NoticeQueue { receiver, budget },
    )
}

/// Counted where the connection reads a notice, so one past the budget is
/// dropped there and never queued.
struct Budget {
    limit: u64,
    admitted: AtomicU64,
    dropped: AtomicBool,
}

/// The connection's end.
pub(crate) struct NoticeSender<T> {
    sender: UnboundedSender<T>,
    budget: Arc<Budget>,
}

impl<T> NoticeSender<T> {
    pub(crate) fn send(&self, notice: T) {
        let admitted = self
            .budget
            .admitted
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |count| {
                (count < self.budget.limit).then(|| count.saturating_add(1))
            })
            .is_ok();
        if admitted {
            let _ = self.sender.send(notice);
        } else {
            self.budget.dropped.store(true, Ordering::SeqCst);
        }
    }
}

/// The session's end.
pub(crate) struct NoticeQueue<T> {
    receiver: UnboundedReceiver<T>,
    budget: Arc<Budget>,
}

impl<T> NoticeQueue<T> {
    pub(crate) fn start_run(&self) {
        self.budget.admitted.store(0, Ordering::SeqCst);
        self.budget.dropped.store(false, Ordering::SeqCst);
    }

    pub(crate) fn next(&mut self) -> Option<T> {
        self.receiver.try_recv().ok()
    }

    pub(crate) fn discard(&mut self) {
        while self.receiver.try_recv().is_ok() {}
    }

    /// Whether the connection dropped a notice since the run started.
    /// Every notice it queued before the first drop is already queued.
    pub(crate) fn dropped(&self) -> bool {
        self.budget.dropped.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn drain(queue: &mut NoticeQueue<u64>) -> Vec<u64> {
        std::iter::from_fn(|| queue.next()).collect()
    }

    #[test]
    fn notices_past_the_budget_are_dropped_and_said_to_be() {
        let (sender, mut queue) = notice_channel(3);

        for notice in 1..=5 {
            sender.send(notice);
        }

        assert_eq!(drain(&mut queue), [1, 2, 3]);
        assert!(queue.dropped());
    }

    #[test]
    fn a_run_within_the_budget_drops_nothing() {
        let (sender, mut queue) = notice_channel(3);

        for notice in 1..=3 {
            sender.send(notice);
        }

        assert_eq!(drain(&mut queue), [1, 2, 3]);
        assert!(!queue.dropped());
    }

    #[test]
    fn a_new_run_starts_with_the_whole_budget() {
        let (sender, mut queue) = notice_channel(2);
        for notice in 1..=4 {
            sender.send(notice);
        }
        drain(&mut queue);

        queue.start_run();
        sender.send(10);
        sender.send(11);

        assert!(!queue.dropped());
        assert_eq!(drain(&mut queue), [10, 11]);
        sender.send(12);
        assert!(queue.dropped());
        assert!(queue.next().is_none());
    }

    #[test]
    fn discarded_notices_still_spend_the_runs_budget() {
        let (sender, mut queue) = notice_channel(2);

        sender.send(1);
        queue.discard();
        sender.send(2);
        sender.send(3);

        assert_eq!(drain(&mut queue), [2]);
        assert!(queue.dropped());
    }
}
