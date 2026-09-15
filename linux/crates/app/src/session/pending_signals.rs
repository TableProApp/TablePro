use std::time::Duration;

use super::{LinkGeneration, MonitorSignal, Reachability};

/// Signals that arrived while the monitor was busy, merged.
///
/// A burst collapses: two losses are one loss, and only the newest
/// reachability matters. `retry` is the exception that is never merged
/// away, because the user pressed something and expects an attempt.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PendingSignals {
    pub retry: bool,
    pub lost: Option<LinkGeneration>,
    pub probe_requested: Option<LinkGeneration>,
    pub succeeded: Option<LinkGeneration>,
    pub reachability: Option<Reachability>,
    pub resumed: Option<Duration>,
}

impl PendingSignals {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// Fold one signal in. Generations keep the highest, reachability
    /// keeps the newest, and a resume keeps the longest sleep.
    pub fn merge(&mut self, signal: MonitorSignal) {
        match signal {
            MonitorSignal::RetryNow => self.retry = true,
            MonitorSignal::ConnectionLost { generation } => keep_latest(&mut self.lost, generation),
            MonitorSignal::ProbeRequested { generation } => keep_latest(&mut self.probe_requested, generation),
            MonitorSignal::OperationSucceeded { generation } => keep_latest(&mut self.succeeded, generation),
            MonitorSignal::Reachability(reachability) => self.reachability = Some(reachability),
            MonitorSignal::Resumed { slept } => {
                self.resumed = Some(self.resumed.map_or(slept, |known| known.max(slept)));
            }
        }
    }

    pub fn take(&mut self) -> Self {
        std::mem::take(self)
    }
}

fn keep_latest(slot: &mut Option<LinkGeneration>, generation: LinkGeneration) {
    *slot = Some(slot.map_or(generation, |known| known.max(generation)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_burst_keeps_the_newest_generation_of_each_kind() {
        let mut pending = PendingSignals::default();

        for generation in [2, 5, 1] {
            pending.merge(MonitorSignal::ConnectionLost {
                generation: LinkGeneration::new(generation),
            });
            pending.merge(MonitorSignal::OperationSucceeded {
                generation: LinkGeneration::new(generation),
            });
        }

        assert_eq!(pending.lost, Some(LinkGeneration::new(5)));
        assert_eq!(pending.succeeded, Some(LinkGeneration::new(5)));
    }

    #[test]
    fn reachability_keeps_the_newest_and_a_resume_keeps_the_longest() {
        let mut pending = PendingSignals::default();

        pending.merge(MonitorSignal::Reachability(Reachability::Unreachable));
        pending.merge(MonitorSignal::Reachability(Reachability::Reachable));
        pending.merge(MonitorSignal::Resumed {
            slept: Duration::from_secs(90),
        });
        pending.merge(MonitorSignal::Resumed {
            slept: Duration::from_secs(10),
        });

        assert_eq!(pending.reachability, Some(Reachability::Reachable));
        assert_eq!(pending.resumed, Some(Duration::from_secs(90)));
    }

    #[test]
    fn take_leaves_an_empty_set_behind() {
        let mut pending = PendingSignals::default();
        pending.merge(MonitorSignal::RetryNow);

        let taken = pending.take();

        assert!(taken.retry);
        assert!(pending.is_empty());
    }
}
