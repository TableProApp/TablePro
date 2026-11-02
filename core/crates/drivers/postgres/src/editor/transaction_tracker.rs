use tablepro_core::TransactionState;

use super::statement_class::StatementClass;

/// The session's transaction status, followed statement by statement.
///
/// tokio-postgres drops the status byte of ReadyForQuery, so the status
/// is derived from what each statement was and whether it succeeded,
/// under PostgreSQL's own rules (xact.c). Where the rules do not settle
/// it, the tracker asks for a probe instead of guessing: read-only mode
/// wraps an idle statement in a read-only transaction, and a guess of
/// "idle" inside a real transaction would commit the user's work.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TransactionTracker {
    state: KnownState,
}

/// What the tracker knows, which is never "unknown": an uncertain step
/// asks for a probe and the probe answers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum KnownState {
    Idle,
    InTransaction,
    Failed,
}

/// What a statement leaves behind.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Next {
    Known(KnownState),
    /// Run the SAVEPOINT probe to learn it.
    Probe,
}

impl Default for TransactionTracker {
    fn default() -> Self {
        Self {
            state: KnownState::Idle,
        }
    }
}

impl TransactionTracker {
    pub(crate) fn state(&self) -> KnownState {
        self.state
    }

    pub(crate) fn set(&mut self, state: KnownState) {
        self.state = state;
    }

    /// The status after `class` ran from the current status and either
    /// succeeded or failed.
    pub(crate) fn after(&self, class: StatementClass, succeeded: bool) -> Next {
        use KnownState::{Failed, Idle, InTransaction};

        let state = self.state;
        let known = Next::Known;
        match (class, state, succeeded) {
            // In an aborted block only ROLLBACK, ROLLBACK TO and COMMIT
            // (which rolls back) are accepted; the rest fail with 25P02.
            (StatementClass::TransactionEnd { chain: false, .. }, _, true) => known(Idle),
            (StatementClass::RollbackToSavepoint, Failed | InTransaction, true) => known(InTransaction),
            (_, Failed, _) if !class.ends_failed_block() => known(Failed),
            (StatementClass::TransactionStart, Idle | InTransaction, true) => known(InTransaction),
            (StatementClass::Savepoint, InTransaction, true) => known(InTransaction),
            (StatementClass::TwoPhase, Idle | InTransaction, true) => known(Idle),
            (StatementClass::RowSource | StatementClass::Other { .. }, _, true) => known(state),
            // A failed statement outside a block was its own transaction;
            // inside one it aborts the block.
            (_, Idle, false) if !class.may_change_state_on_failure() => known(Idle),
            (_, InTransaction, false) if !class.may_change_state_on_failure() => known(Failed),
            // AND CHAIN, a failed COMMIT, CALL and DO, and anything that
            // fell through: the rules leave it open, so ask.
            _ => Next::Probe,
        }
    }
}

impl StatementClass {
    fn ends_failed_block(self) -> bool {
        matches!(self, Self::TransactionEnd { .. } | Self::RollbackToSavepoint)
    }

    /// Whether a failure of this statement can leave the transaction in a
    /// state other than "aborted if in a block": a failed COMMIT has
    /// already rolled back, and CALL or DO may have committed first.
    fn may_change_state_on_failure(self) -> bool {
        matches!(
            self,
            Self::TransactionEnd { .. } | Self::RollbackToSavepoint | Self::Undetermined | Self::TwoPhase
        )
    }
}

impl From<KnownState> for TransactionState {
    fn from(state: KnownState) -> Self {
        match state {
            KnownState::Idle => Self::Idle,
            KnownState::InTransaction => Self::InTransaction,
            KnownState::Failed => Self::Failed,
        }
    }
}

/// What the SAVEPOINT probe's answer means. SAVEPOINT needs a
/// transaction block, so it fails with 25P01 outside one and with 25P02
/// in an aborted one.
pub(crate) fn probe_answer(sqlstate: Option<&str>) -> Option<KnownState> {
    match sqlstate {
        None => Some(KnownState::InTransaction),
        Some("25P01") => Some(KnownState::Idle),
        Some("25P02") => Some(KnownState::Failed),
        Some(_) => None,
    }
}

pub(crate) const PROBE_SAVEPOINT: &str = "SAVEPOINT tablepro_probe";
pub(crate) const PROBE_RELEASE: &str = "RELEASE SAVEPOINT tablepro_probe";

#[cfg(test)]
mod tests {
    use super::*;

    fn tracker(state: KnownState) -> TransactionTracker {
        let mut tracker = TransactionTracker::default();
        tracker.set(state);
        tracker
    }

    #[test]
    fn transitions_table() {
        use KnownState::{Failed, Idle, InTransaction};

        let other = StatementClass::Other { reports_rows: true };
        let commit = StatementClass::TransactionEnd {
            rollback: false,
            chain: false,
        };
        let rollback = StatementClass::TransactionEnd {
            rollback: true,
            chain: false,
        };
        let chain = StatementClass::TransactionEnd {
            rollback: false,
            chain: true,
        };
        let cases = [
            (Idle, StatementClass::TransactionStart, true, Next::Known(InTransaction)),
            (
                InTransaction,
                StatementClass::TransactionStart,
                true,
                Next::Known(InTransaction),
            ),
            (Failed, StatementClass::TransactionStart, false, Next::Known(Failed)),
            (InTransaction, commit, true, Next::Known(Idle)),
            (Failed, commit, true, Next::Known(Idle)),
            (Idle, commit, true, Next::Known(Idle)),
            (InTransaction, rollback, true, Next::Known(Idle)),
            (InTransaction, commit, false, Next::Probe),
            (InTransaction, chain, true, Next::Probe),
            (
                Failed,
                StatementClass::RollbackToSavepoint,
                true,
                Next::Known(InTransaction),
            ),
            (Failed, StatementClass::RollbackToSavepoint, false, Next::Probe),
            (
                InTransaction,
                StatementClass::Savepoint,
                true,
                Next::Known(InTransaction),
            ),
            (Idle, StatementClass::Savepoint, false, Next::Known(Idle)),
            (InTransaction, StatementClass::Savepoint, false, Next::Known(Failed)),
            (InTransaction, StatementClass::TwoPhase, true, Next::Known(Idle)),
            (Idle, other, true, Next::Known(Idle)),
            (Idle, other, false, Next::Known(Idle)),
            (InTransaction, other, true, Next::Known(InTransaction)),
            (InTransaction, other, false, Next::Known(Failed)),
            (Failed, other, false, Next::Known(Failed)),
            (InTransaction, StatementClass::RowSource, false, Next::Known(Failed)),
            (Idle, StatementClass::Undetermined, true, Next::Probe),
            (InTransaction, StatementClass::Undetermined, false, Next::Probe),
        ];
        for (from, class, succeeded, expected) in cases {
            assert_eq!(
                tracker(from).after(class, succeeded),
                expected,
                "{class:?} from {from:?}, succeeded {succeeded}"
            );
        }
    }

    #[test]
    fn savepoint_probe_25p01_idle_25p02_failed() {
        assert_eq!(probe_answer(None), Some(KnownState::InTransaction));
        assert_eq!(probe_answer(Some("25P01")), Some(KnownState::Idle));
        assert_eq!(probe_answer(Some("25P02")), Some(KnownState::Failed));
        assert_eq!(probe_answer(Some("57014")), None);
    }
}
