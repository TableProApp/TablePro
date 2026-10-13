use std::collections::HashMap;
use std::hash::Hash;

use tokio_util::sync::CancellationToken;

use super::{RequestStamp, RequestTicket};

/// Keeps one request of each kind current.
///
/// Issuing a request stops the one of its kind still running, so the
/// server drops work nobody will look at, and only the reply to the
/// latest request is accepted. Dropping the sequencer stops them all,
/// which is what closing a view should do.
#[derive(Debug)]
pub struct RequestSequencer<K: Eq + Hash> {
    last: u64,
    current: HashMap<K, (RequestStamp, CancellationToken)>,
}

impl<K: Eq + Hash + Copy> RequestSequencer<K> {
    pub fn new() -> Self {
        Self {
            last: 0,
            current: HashMap::new(),
        }
    }

    pub fn issue(&mut self, kind: K) -> RequestTicket {
        self.last += 1;
        let stamp = RequestStamp::new(self.last);
        let cancel = CancellationToken::new();
        if let Some((_, previous)) = self.current.insert(kind, (stamp, cancel.clone())) {
            previous.cancel();
        }
        RequestTicket { stamp, cancel }
    }

    /// Whether a reply is the answer to the current request of its kind.
    /// Accepting it ends that request, so the same reply twice, or a
    /// reply to one a newer request replaced, is refused.
    pub fn accept(&mut self, kind: K, stamp: RequestStamp) -> bool {
        match self.current.get(&kind) {
            Some((current, _)) if *current == stamp => {
                self.current.remove(&kind);
                true
            }
            _ => false,
        }
    }

    pub fn is_current(&self, kind: K, stamp: RequestStamp) -> bool {
        self.current.get(&kind).is_some_and(|(current, _)| *current == stamp)
    }

    /// Whether a request of this kind is still waiting for its reply.
    pub fn is_pending(&self, kind: K) -> bool {
        self.current.contains_key(&kind)
    }

    pub fn cancel_all(&mut self) {
        for (_, (_, cancel)) in self.current.drain() {
            cancel.cancel();
        }
    }
}

impl<K: Eq + Hash + Copy> Default for RequestSequencer<K> {
    fn default() -> Self {
        Self::new()
    }
}

impl<K: Eq + Hash> Drop for RequestSequencer<K> {
    fn drop(&mut self) {
        for (_, (_, cancel)) in self.current.drain() {
            cancel.cancel();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    enum Kind {
        Page,
        Count,
    }

    #[test]
    fn issue_cancels_previous_token_of_same_kind() {
        let mut sequencer = RequestSequencer::new();
        let first = sequencer.issue(Kind::Page);
        let count = sequencer.issue(Kind::Count);

        let second = sequencer.issue(Kind::Page);

        assert!(first.cancel.is_cancelled());
        assert!(!second.cancel.is_cancelled());
        assert!(!count.cancel.is_cancelled(), "a page request stopped the count");
        assert!(second.stamp > first.stamp);
    }

    #[test]
    fn accept_rejects_superseded_stamp() {
        let mut sequencer = RequestSequencer::new();
        let first = sequencer.issue(Kind::Page);
        let second = sequencer.issue(Kind::Page);

        assert!(!sequencer.accept(Kind::Page, first.stamp));
        assert!(sequencer.is_current(Kind::Page, second.stamp));
        assert!(sequencer.accept(Kind::Page, second.stamp));
    }

    #[test]
    fn duplicate_reply_dropped() {
        let mut sequencer = RequestSequencer::new();
        let ticket = sequencer.issue(Kind::Count);

        assert!(sequencer.accept(Kind::Count, ticket.stamp));
        assert!(!sequencer.accept(Kind::Count, ticket.stamp));
        assert!(!sequencer.is_pending(Kind::Count));
        assert!(
            !ticket.cancel.is_cancelled(),
            "accepting a reply stopped the request it answered"
        );
    }

    #[test]
    fn a_stamp_is_only_current_for_its_own_kind() {
        let mut sequencer = RequestSequencer::new();
        let page = sequencer.issue(Kind::Page);

        assert!(!sequencer.accept(Kind::Count, page.stamp));
        assert!(sequencer.is_pending(Kind::Page));
    }

    #[test]
    fn cancel_all_stops_every_kind() {
        let mut sequencer = RequestSequencer::new();
        let page = sequencer.issue(Kind::Page);
        let count = sequencer.issue(Kind::Count);

        sequencer.cancel_all();

        assert!(page.cancel.is_cancelled() && count.cancel.is_cancelled());
        assert!(!sequencer.accept(Kind::Page, page.stamp));
    }

    #[test]
    fn drop_cancels_all() {
        let mut sequencer = RequestSequencer::new();
        let page = sequencer.issue(Kind::Page);
        let count = sequencer.issue(Kind::Count);

        drop(sequencer);

        assert!(page.cancel.is_cancelled());
        assert!(count.cancel.is_cancelled());
    }
}
