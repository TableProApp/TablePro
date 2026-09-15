use std::sync::Mutex;

use crate::commit::CommitToken;
use crate::error::DriverError;
use crate::session_fate::SessionFate;
use crate::write_report::StatementOutcome;

/// Whether an engine can undo a half-finished write.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WriteAtomicity {
    Transactional,
    /// No transaction: each statement lands on its own, and nothing
    /// takes them back.
    StatementByStatement,
}

/// What a write has sent and what the server has confirmed.
///
/// A write interrupted halfway is not one outcome but three, and which
/// one it is depends on exactly how far it got. The work records each
/// step here as it goes, so when a connection dies the answer comes
/// from what was actually sent rather than from a guess made afterwards.
#[derive(Debug)]
pub struct WriteLedger {
    atomicity: WriteAtomicity,
    state: Mutex<State>,
}

#[derive(Debug, Default)]
struct State {
    in_flight: Option<usize>,
    confirmed: usize,
    commit_sent: bool,
    token: Option<CommitToken>,
}

impl WriteLedger {
    pub fn new(atomicity: WriteAtomicity) -> Self {
        Self {
            atomicity,
            state: Mutex::new(State::default()),
        }
    }

    pub fn statement_sending(&self, index: usize) {
        self.with(|state| state.in_flight = Some(index));
    }

    pub fn statement_confirmed(&self, index: usize) {
        self.with(|state| {
            state.in_flight = None;
            state.confirmed = state.confirmed.max(index + 1);
        });
    }

    /// Called before COMMIT reaches the wire. After this the outcome of
    /// a lost connection is unknown rather than rolled back.
    pub fn commit_sending(&self, token: Option<CommitToken>) {
        self.with(|state| {
            state.commit_sent = true;
            if token.is_some() {
                state.token = token;
            }
        });
    }

    pub fn attach_token(&self, token: CommitToken) {
        self.with(|state| state.token = Some(token));
    }

    /// Whether the engine's own stop may be sent right now.
    ///
    /// A stop that races a commit, or a statement an engine cannot take
    /// back, turns a knowable outcome into an unknown one, so it is
    /// held until the write is somewhere it can survive being stopped.
    pub fn stop_permitted(&self) -> bool {
        self.read(|state| match self.atomicity {
            WriteAtomicity::Transactional => !state.commit_sent,
            WriteAtomicity::StatementByStatement => state.in_flight.is_none(),
        })
    }

    /// The outcome of a write that was stopped or lost, given what the
    /// session did afterwards.
    pub fn interrupted(&self, cause: DriverError, fate: SessionFate) -> DriverError {
        self.read(|state| match self.atomicity {
            WriteAtomicity::Transactional => self.transactional_outcome(state, cause, fate),
            WriteAtomicity::StatementByStatement => self.stepwise_outcome(state, cause),
        })
    }

    /// A statement the server definitely refused, which therefore did
    /// not apply.
    pub fn failed(&self, index: usize, source: DriverError, fate: SessionFate) -> DriverError {
        self.read(|state| match (self.atomicity, &fate) {
            (WriteAtomicity::Transactional, SessionFate::RollbackIncomplete { executed }) => {
                DriverError::PartiallyApplied {
                    applied: *executed,
                    statement_index: index,
                    failed_outcome: StatementOutcome::Failed,
                    source: Box::new(source),
                }
            }
            (WriteAtomicity::Transactional, _) => DriverError::RolledBack {
                statement_index: index,
                source: Box::new(source),
            },
            (WriteAtomicity::StatementByStatement, _) if state.confirmed == 0 => DriverError::RolledBack {
                statement_index: index,
                source: Box::new(source),
            },
            (WriteAtomicity::StatementByStatement, _) => DriverError::PartiallyApplied {
                applied: state.confirmed,
                statement_index: index,
                failed_outcome: StatementOutcome::Failed,
                source: Box::new(source),
            },
        })
    }

    /// A statement that changed a different number of rows than the one
    /// it was written for, which means the row is not the one that was
    /// read.
    pub fn guard_failed(&self, index: usize, expected: u64, actual: u64, fate: SessionFate) -> DriverError {
        let applied = self.read(|state| match (self.atomicity, &fate) {
            (WriteAtomicity::Transactional, SessionFate::RollbackIncomplete { executed }) => *executed,
            (WriteAtomicity::Transactional, _) => 0,
            (WriteAtomicity::StatementByStatement, _) => state.confirmed,
        });
        if applied == 0 {
            return DriverError::RowGuardFailed {
                statement_index: index,
                expected,
                actual,
            };
        }
        DriverError::PartiallyApplied {
            applied,
            statement_index: index,
            failed_outcome: StatementOutcome::Failed,
            source: Box::new(DriverError::RowGuardFailed {
                statement_index: index,
                expected,
                actual,
            }),
        }
    }

    fn transactional_outcome(&self, state: &State, cause: DriverError, fate: SessionFate) -> DriverError {
        if state.commit_sent {
            return DriverError::CommitOutcomeUnknown {
                token: state.token.clone(),
                source: Box::new(cause),
            };
        }
        match fate {
            // A COMMIT that was never written cannot commit once the
            // session is gone, so a discarded session leaves as little
            // behind as a clean rollback.
            SessionFate::RolledBack | SessionFate::Discarded => DriverError::RolledBack {
                statement_index: state.in_flight.unwrap_or(state.confirmed),
                source: Box::new(cause),
            },
            SessionFate::RollbackIncomplete { executed } => DriverError::PartiallyApplied {
                applied: executed,
                statement_index: state.in_flight.unwrap_or(state.confirmed),
                failed_outcome: StatementOutcome::Failed,
                source: Box::new(cause),
            },
        }
    }

    fn stepwise_outcome(&self, state: &State, cause: DriverError) -> DriverError {
        let Some(in_flight) = state.in_flight else {
            if state.confirmed == 0 {
                return DriverError::RolledBack {
                    statement_index: 0,
                    source: Box::new(cause),
                };
            }
            return DriverError::PartiallyApplied {
                applied: state.confirmed,
                statement_index: state.confirmed,
                failed_outcome: StatementOutcome::Failed,
                source: Box::new(cause),
            };
        };
        if state.token.is_some() || state.confirmed == 0 {
            return DriverError::CommitOutcomeUnknown {
                token: state.token.clone(),
                source: Box::new(cause),
            };
        }
        DriverError::PartiallyApplied {
            applied: state.confirmed,
            statement_index: in_flight,
            failed_outcome: StatementOutcome::Unknown,
            source: Box::new(cause),
        }
    }

    fn with<T>(&self, change: impl FnOnce(&mut State) -> T) -> T {
        let mut state = match self.state.lock() {
            Ok(state) => state,
            // A panic while recording a step leaves the ledger readable
            // and the write still needs its outcome.
            Err(poisoned) => poisoned.into_inner(),
        };
        change(&mut state)
    }

    fn read<T>(&self, look: impl FnOnce(&State) -> T) -> T {
        let state = match self.state.lock() {
            Ok(state) => state,
            Err(poisoned) => poisoned.into_inner(),
        };
        look(&state)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lost() -> DriverError {
        DriverError::ConnectionLost {
            during: crate::loss_phase::LossPhase::Statement,
        }
    }

    fn token() -> CommitToken {
        CommitToken::PostgresXid {
            xid: 42,
            legacy_txid: false,
        }
    }

    #[test]
    fn a_transaction_lost_before_the_commit_left_nothing_behind() {
        let ledger = WriteLedger::new(WriteAtomicity::Transactional);
        ledger.statement_confirmed(0);
        ledger.statement_sending(1);

        let outcome = ledger.interrupted(lost(), SessionFate::Discarded);

        assert!(
            matches!(outcome, DriverError::RolledBack { statement_index: 1, .. }),
            "got {outcome:?}"
        );
    }

    #[test]
    fn a_transaction_lost_after_the_commit_carries_the_token_to_ask_with() {
        let ledger = WriteLedger::new(WriteAtomicity::Transactional);
        ledger.statement_confirmed(0);
        ledger.commit_sending(Some(token()));

        let outcome = ledger.interrupted(lost(), SessionFate::Discarded);

        let DriverError::CommitOutcomeUnknown { token: carried, .. } = outcome else {
            panic!("a lost commit did not report an unknown outcome");
        };
        assert_eq!(carried, Some(token()));
    }

    #[test]
    fn a_rollback_that_did_not_finish_reports_what_may_still_be_there() {
        let ledger = WriteLedger::new(WriteAtomicity::Transactional);
        ledger.statement_confirmed(0);
        ledger.statement_confirmed(1);

        let outcome = ledger.interrupted(lost(), SessionFate::RollbackIncomplete { executed: 2 });

        assert!(
            matches!(outcome, DriverError::PartiallyApplied { applied: 2, .. }),
            "got {outcome:?}"
        );
    }

    #[test]
    fn a_stop_waits_for_the_commit_on_a_transactional_engine() {
        let ledger = WriteLedger::new(WriteAtomicity::Transactional);
        assert!(ledger.stop_permitted());

        ledger.commit_sending(None);

        assert!(!ledger.stop_permitted(), "a stop was allowed to race the commit");
    }

    #[test]
    fn a_stop_waits_for_the_statement_on_an_engine_that_cannot_undo_one() {
        let ledger = WriteLedger::new(WriteAtomicity::StatementByStatement);
        assert!(ledger.stop_permitted());

        ledger.statement_sending(0);
        assert!(!ledger.stop_permitted());

        ledger.statement_confirmed(0);
        assert!(ledger.stop_permitted());
    }

    #[test]
    fn an_engine_with_no_transaction_reports_what_already_landed() {
        let ledger = WriteLedger::new(WriteAtomicity::StatementByStatement);
        ledger.statement_confirmed(0);
        ledger.statement_confirmed(1);
        ledger.statement_sending(2);

        let outcome = ledger.interrupted(lost(), SessionFate::Discarded);

        assert!(
            matches!(
                outcome,
                DriverError::PartiallyApplied {
                    applied: 2,
                    statement_index: 2,
                    failed_outcome: StatementOutcome::Unknown,
                    ..
                }
            ),
            "got {outcome:?}"
        );
    }

    #[test]
    fn nothing_sent_yet_is_a_rollback_on_either_engine() {
        for atomicity in [WriteAtomicity::Transactional, WriteAtomicity::StatementByStatement] {
            let ledger = WriteLedger::new(atomicity);

            let outcome = ledger.interrupted(lost(), SessionFate::RolledBack);

            assert!(
                matches!(outcome, DriverError::RolledBack { .. }),
                "{atomicity:?} gave {outcome:?}"
            );
        }
    }

    #[test]
    fn a_guard_mismatch_with_nothing_applied_is_only_a_guard_mismatch() {
        let ledger = WriteLedger::new(WriteAtomicity::Transactional);
        ledger.statement_sending(0);

        let outcome = ledger.guard_failed(0, 1, 0, SessionFate::RolledBack);

        assert!(
            matches!(
                outcome,
                DriverError::RowGuardFailed {
                    statement_index: 0,
                    expected: 1,
                    actual: 0
                }
            ),
            "got {outcome:?}"
        );
    }

    #[test]
    fn a_guard_mismatch_after_a_statement_landed_says_so() {
        let ledger = WriteLedger::new(WriteAtomicity::StatementByStatement);
        ledger.statement_confirmed(0);

        let outcome = ledger.guard_failed(1, 1, 3, SessionFate::RolledBack);

        assert!(
            matches!(outcome, DriverError::PartiallyApplied { applied: 1, .. }),
            "got {outcome:?}"
        );
    }

    #[test]
    fn a_refused_statement_does_not_count_as_applied() {
        let ledger = WriteLedger::new(WriteAtomicity::StatementByStatement);
        ledger.statement_confirmed(0);
        ledger.statement_sending(1);

        let outcome = ledger.failed(1, DriverError::server("duplicate key"), SessionFate::RolledBack);

        assert!(
            matches!(
                outcome,
                DriverError::PartiallyApplied {
                    applied: 1,
                    statement_index: 1,
                    failed_outcome: StatementOutcome::Failed,
                    ..
                }
            ),
            "got {outcome:?}"
        );
    }
}
