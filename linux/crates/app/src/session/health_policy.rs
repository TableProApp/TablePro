use std::time::Duration;

use tokio::time::Instant;

use super::{
    FailureCause, LinkGeneration, MonitorAction, PendingSignals, ProbeOutcome, Reachability, ReconnectResult,
    SessionHealth,
};

/// Decides what the monitor does next, as a pure state machine.
///
/// Nothing here touches a connection, a timer or the network: the
/// caller feeds it what happened and a clock reading, and gets back one
/// action. That keeps every transition testable without a server.
#[derive(Debug)]
pub struct HealthPolicy {
    state: SessionHealth,
    generation: LinkGeneration,
    backoff: Duration,
    failures: u8,
    reachability: Reachability,
    next_deadline: Option<Instant>,
}

impl HealthPolicy {
    /// How long a healthy connection goes between probes.
    pub const PROBE_INTERVAL: Duration = Duration::from_secs(30);
    /// How soon a probe that did not answer is tried again.
    pub const PROBE_RETRY: Duration = Duration::from_secs(10);
    pub const BACKOFF_INITIAL: Duration = Duration::from_secs(5);
    pub const BACKOFF_MAX: Duration = Duration::from_secs(60);
    /// How often an offline session checks whether the endpoint came
    /// back. Long, because the answer is almost always no.
    pub const OFFLINE_RECHECK: Duration = Duration::from_secs(60);
    /// Unanswered probes before the connection counts as gone. One is
    /// a hiccup; three in a row is not.
    pub const LOST_AFTER_FAILURES: u8 = 3;
    /// A sleep longer than this outlives most idle timeouts, so the
    /// connection is probed on resume instead of trusted.
    pub const RESUME_PROBE_AFTER: Duration = Self::PROBE_INTERVAL;

    pub fn new(generation: LinkGeneration, now: Instant) -> Self {
        Self {
            state: SessionHealth::Online,
            generation,
            backoff: Self::BACKOFF_INITIAL,
            failures: 0,
            reachability: Reachability::Reachable,
            next_deadline: Some(now + Self::PROBE_INTERVAL),
        }
    }

    pub fn health(&self) -> &SessionHealth {
        &self.state
    }

    pub fn generation(&self) -> LinkGeneration {
        self.generation
    }

    pub fn next_deadline(&self) -> Option<Instant> {
        self.next_deadline
    }

    pub fn on_signals(&mut self, signals: &PendingSignals, now: Instant) -> MonitorAction {
        if let Some(reachability) = signals.reachability {
            self.reachability = reachability;
        }

        // Parked. Only the user unparks, so reachability and resume are
        // recorded above and otherwise ignored.
        if matches!(self.state, SessionHealth::Failed { .. }) {
            return match signals.retry {
                true => self.start_reconnecting(now),
                false => MonitorAction::Park,
            };
        }

        if signals.retry {
            return self.start_reconnecting(now);
        }
        if self.is_current(signals.succeeded) {
            return self.mark_online(now);
        }
        if self.is_current(signals.lost) {
            self.failures = Self::LOST_AFTER_FAILURES;
            return self.after_losing_the_connection(now);
        }
        if signals.reachability == Some(Reachability::Reachable) && self.state == SessionHealth::Offline {
            return self.start_reconnecting(now);
        }
        if self.is_current(signals.probe_requested) && self.state.is_online() {
            return MonitorAction::Probe;
        }
        if signals.resumed.is_some_and(|slept| slept > Self::RESUME_PROBE_AFTER) && self.state.is_online() {
            return MonitorAction::Probe;
        }
        MonitorAction::Wait
    }

    pub fn on_probe(&mut self, outcome: &ProbeOutcome, now: Instant) -> MonitorAction {
        match outcome {
            // A refusal is the server talking, so the connection is up.
            // The caller logs the cause; the monitor keeps probing.
            ProbeOutcome::Healthy | ProbeOutcome::Busy | ProbeOutcome::Rejected(_) => self.mark_online(now),
            ProbeOutcome::Unresponsive => {
                self.failures = self.failures.saturating_add(1);
                if self.failures >= Self::LOST_AFTER_FAILURES {
                    return self.after_losing_the_connection(now);
                }
                self.next_deadline = Some(now + Self::PROBE_RETRY);
                MonitorAction::Wait
            }
            ProbeOutcome::Lost => {
                self.failures = Self::LOST_AFTER_FAILURES;
                self.after_losing_the_connection(now)
            }
        }
    }

    pub fn on_reconnect(&mut self, result: &ReconnectResult, now: Instant) -> MonitorAction {
        match result {
            ReconnectResult::Connected(generation) => {
                self.generation = *generation;
                self.mark_online(now)
            }
            ReconnectResult::Rejected(cause) => self.park(*cause),
            ReconnectResult::Failed => {
                let attempt = match self.state {
                    SessionHealth::Reconnecting { attempt } => attempt.saturating_add(1),
                    _ => 1,
                };
                if !self.reachability.is_reachable() {
                    return self.go_offline(now);
                }
                self.state = SessionHealth::Reconnecting { attempt };
                self.next_deadline = Some(now + self.backoff);
                self.backoff = (self.backoff * 2).min(Self::BACKOFF_MAX);
                MonitorAction::Wait
            }
        }
    }

    pub fn on_deadline(&mut self, now: Instant) -> MonitorAction {
        match self.state {
            SessionHealth::Online => MonitorAction::Probe,
            SessionHealth::Reconnecting { .. } => MonitorAction::Reconnect,
            SessionHealth::Offline => {
                self.next_deadline = Some(now + Self::OFFLINE_RECHECK);
                MonitorAction::Reconnect
            }
            SessionHealth::Failed { .. } => MonitorAction::Park,
        }
    }

    /// A signal from a generation the connection has moved past says
    /// nothing about the one that replaced it.
    fn is_current(&self, generation: Option<LinkGeneration>) -> bool {
        generation == Some(self.generation)
    }

    fn mark_online(&mut self, now: Instant) -> MonitorAction {
        self.state = SessionHealth::Online;
        self.failures = 0;
        self.backoff = Self::BACKOFF_INITIAL;
        self.next_deadline = Some(now + Self::PROBE_INTERVAL);
        MonitorAction::Wait
    }

    /// Retrying a connection whose endpoint is unreachable only burns
    /// the backoff, so an unreachable session waits on the long timer
    /// instead.
    fn after_losing_the_connection(&mut self, now: Instant) -> MonitorAction {
        match self.reachability.is_reachable() {
            true => self.start_reconnecting(now),
            false => self.go_offline(now),
        }
    }

    fn start_reconnecting(&mut self, now: Instant) -> MonitorAction {
        self.state = SessionHealth::Reconnecting { attempt: 1 };
        self.backoff = Self::BACKOFF_INITIAL;
        self.failures = 0;
        self.next_deadline = Some(now + self.backoff);
        MonitorAction::Reconnect
    }

    fn go_offline(&mut self, now: Instant) -> MonitorAction {
        self.state = SessionHealth::Offline;
        self.backoff = Self::BACKOFF_INITIAL;
        self.next_deadline = Some(now + Self::OFFLINE_RECHECK);
        MonitorAction::Wait
    }

    fn park(&mut self, cause: FailureCause) -> MonitorAction {
        self.state = SessionHealth::Failed { cause };
        self.next_deadline = None;
        MonitorAction::Park
    }
}

#[cfg(test)]
mod tests {
    use super::super::MonitorSignal;
    use super::*;

    const GENERATION: LinkGeneration = LinkGeneration::FIRST;

    fn policy(now: Instant) -> HealthPolicy {
        HealthPolicy::new(GENERATION, now)
    }

    fn signals(list: &[MonitorSignal]) -> PendingSignals {
        let mut pending = PendingSignals::default();
        for signal in list {
            pending.merge(signal.clone());
        }
        pending
    }

    /// Park the policy on an authentication failure, which is the only
    /// route into Failed.
    fn parked(now: Instant) -> HealthPolicy {
        let mut policy = policy(now);
        policy.on_probe(&ProbeOutcome::Lost, now);
        policy.on_reconnect(&ReconnectResult::Rejected(FailureCause::Authentication), now);
        policy
    }

    #[tokio::test(start_paused = true)]
    async fn healthy_and_busy_stay_online() {
        let now = Instant::now();
        let mut policy = policy(now);

        for outcome in [ProbeOutcome::Healthy, ProbeOutcome::Busy] {
            assert_eq!(policy.on_probe(&outcome, now), MonitorAction::Wait, "{outcome:?}");
            assert_eq!(policy.health(), &SessionHealth::Online, "{outcome:?}");
            assert_eq!(policy.next_deadline(), Some(now + HealthPolicy::PROBE_INTERVAL));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn three_unresponsive_probes_start_reconnect() {
        let now = Instant::now();
        let mut policy = policy(now);

        for attempt in 1..=2 {
            assert_eq!(
                policy.on_probe(&ProbeOutcome::Unresponsive, now),
                MonitorAction::Wait,
                "probe {attempt}"
            );
            assert_eq!(policy.health(), &SessionHealth::Online, "probe {attempt}");
            assert_eq!(policy.next_deadline(), Some(now + HealthPolicy::PROBE_RETRY));
        }

        assert_eq!(
            policy.on_probe(&ProbeOutcome::Unresponsive, now),
            MonitorAction::Reconnect
        );
        assert_eq!(policy.health(), &SessionHealth::Reconnecting { attempt: 1 });
    }

    #[tokio::test(start_paused = true)]
    async fn lost_with_unreachable_goes_offline() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_signals(&signals(&[MonitorSignal::Reachability(Reachability::Unreachable)]), now);

        assert_eq!(policy.on_probe(&ProbeOutcome::Lost, now), MonitorAction::Wait);

        assert_eq!(policy.health(), &SessionHealth::Offline);
        assert_eq!(policy.next_deadline(), Some(now + HealthPolicy::OFFLINE_RECHECK));
    }

    #[tokio::test(start_paused = true)]
    async fn rejected_probe_stays_online_with_warning() {
        let now = Instant::now();
        let mut policy = policy(now);

        let action = policy.on_probe(&ProbeOutcome::Rejected(FailureCause::Authentication), now);

        assert_eq!(action, MonitorAction::Wait);
        assert_eq!(
            policy.health(),
            &SessionHealth::Online,
            "a refused probe parked a live connection"
        );
    }

    #[tokio::test(start_paused = true)]
    async fn reconnect_rejected_parks_failed() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_probe(&ProbeOutcome::Lost, now);

        let action = policy.on_reconnect(&ReconnectResult::Rejected(FailureCause::Tls), now);

        assert_eq!(action, MonitorAction::Park);
        assert_eq!(
            policy.health(),
            &SessionHealth::Failed {
                cause: FailureCause::Tls
            }
        );
        assert_eq!(policy.next_deadline(), None, "a parked session still has a timer");
    }

    #[tokio::test(start_paused = true)]
    async fn failed_plus_retry_reconnects() {
        let now = Instant::now();
        let mut policy = parked(now);

        let action = policy.on_signals(&signals(&[MonitorSignal::RetryNow]), now);

        assert_eq!(action, MonitorAction::Reconnect);
        assert_eq!(policy.health(), &SessionHealth::Reconnecting { attempt: 1 });
    }

    #[tokio::test(start_paused = true)]
    async fn failed_ignores_reachable_and_resumed() {
        let now = Instant::now();
        let mut policy = parked(now);

        let action = policy.on_signals(
            &signals(&[
                MonitorSignal::Reachability(Reachability::Reachable),
                MonitorSignal::Resumed {
                    slept: Duration::from_secs(3_600),
                },
            ]),
            now,
        );

        assert_eq!(action, MonitorAction::Park);
        assert_eq!(
            policy.health(),
            &SessionHealth::Failed {
                cause: FailureCause::Authentication
            }
        );
    }

    #[tokio::test(start_paused = true)]
    async fn stale_generation_signals_ignored() {
        let now = Instant::now();
        let mut policy = HealthPolicy::new(LinkGeneration::new(4), now);

        let action = policy.on_signals(
            &signals(&[MonitorSignal::ConnectionLost {
                generation: LinkGeneration::new(3),
            }]),
            now,
        );

        assert_eq!(action, MonitorAction::Wait);
        assert_eq!(policy.health(), &SessionHealth::Online);
    }

    #[tokio::test(start_paused = true)]
    async fn operation_succeeded_current_generation_goes_online() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_probe(&ProbeOutcome::Lost, now);
        assert_eq!(policy.health(), &SessionHealth::Reconnecting { attempt: 1 });

        let action = policy.on_signals(
            &signals(&[MonitorSignal::OperationSucceeded { generation: GENERATION }]),
            now,
        );

        assert_eq!(action, MonitorAction::Wait);
        assert_eq!(policy.health(), &SessionHealth::Online);
    }

    #[tokio::test(start_paused = true)]
    async fn an_operation_succeeding_clears_offline_too() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_signals(&signals(&[MonitorSignal::Reachability(Reachability::Unreachable)]), now);
        policy.on_probe(&ProbeOutcome::Lost, now);
        assert_eq!(policy.health(), &SessionHealth::Offline);

        policy.on_signals(
            &signals(&[MonitorSignal::OperationSucceeded { generation: GENERATION }]),
            now,
        );

        assert_eq!(policy.health(), &SessionHealth::Online);
    }

    #[tokio::test(start_paused = true)]
    async fn backoff_doubles_and_caps_at_60s() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_probe(&ProbeOutcome::Lost, now);

        let waits: Vec<Duration> = (0..6)
            .map(|_| {
                policy.on_reconnect(&ReconnectResult::Failed, now);
                policy.next_deadline().expect("a deadline while reconnecting") - now
            })
            .collect();

        assert_eq!(
            waits,
            vec![
                Duration::from_secs(5),
                Duration::from_secs(10),
                Duration::from_secs(20),
                Duration::from_secs(40),
                Duration::from_secs(60),
                Duration::from_secs(60),
            ]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn offline_rechecks_every_60s() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_signals(&signals(&[MonitorSignal::Reachability(Reachability::Unreachable)]), now);
        policy.on_probe(&ProbeOutcome::Lost, now);

        let later = now + HealthPolicy::OFFLINE_RECHECK;
        let action = policy.on_deadline(later);

        assert_eq!(action, MonitorAction::Reconnect);
        assert_eq!(policy.next_deadline(), Some(later + HealthPolicy::OFFLINE_RECHECK));
    }

    #[tokio::test(start_paused = true)]
    async fn reachability_coming_back_reconnects_an_offline_session() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_signals(&signals(&[MonitorSignal::Reachability(Reachability::Unreachable)]), now);
        policy.on_probe(&ProbeOutcome::Lost, now);

        let action = policy.on_signals(&signals(&[MonitorSignal::Reachability(Reachability::Reachable)]), now);

        assert_eq!(action, MonitorAction::Reconnect);
        assert_eq!(policy.health(), &SessionHealth::Reconnecting { attempt: 1 });
    }

    #[tokio::test(start_paused = true)]
    async fn a_long_sleep_probes_and_a_short_one_does_not() {
        let now = Instant::now();
        let mut policy = policy(now);

        let short = policy.on_signals(
            &signals(&[MonitorSignal::Resumed {
                slept: Duration::from_secs(5),
            }]),
            now,
        );
        let long = policy.on_signals(
            &signals(&[MonitorSignal::Resumed {
                slept: HealthPolicy::RESUME_PROBE_AFTER + Duration::from_secs(1),
            }]),
            now,
        );

        assert_eq!(short, MonitorAction::Wait);
        assert_eq!(long, MonitorAction::Probe);
    }

    #[tokio::test(start_paused = true)]
    async fn a_reconnect_adopts_the_generation_it_established() {
        let now = Instant::now();
        let mut policy = policy(now);
        policy.on_probe(&ProbeOutcome::Lost, now);
        let established = GENERATION.next();

        policy.on_reconnect(&ReconnectResult::Connected(established), now);

        assert_eq!(policy.generation(), established);
        assert_eq!(policy.health(), &SessionHealth::Online);
    }
}
