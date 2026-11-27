use tablepro_core::{DriverError, ReadOnlyRefusal, UnsupportedFeature};

use super::statement_class::StatementClass;
use super::transaction_tracker::KnownState;

/// How one editor statement goes to the server.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Flight {
    /// Refused before anything is sent.
    Refuse(DriverError),
    /// The simple protocol, as psql sends a statement.
    Simple(Wrap),
    /// A cursor that fetches one row past the limit, so a large result
    /// stops on the server instead of crossing the wire.
    Cursor(CursorOwner),
}

/// What surrounds a simple statement in a read-only session. Read-only
/// is set per transaction, never per session, so nothing outlives the
/// statement on a server connection a pooler shares.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Wrap {
    None,
    /// START TRANSACTION READ ONLY, the statement, COMMIT.
    ReadOnlyTransaction,
    /// The user's BEGIN, then SET TRANSACTION READ ONLY.
    ReadOnlyAfterStart,
}

/// Whose transaction the cursor lives in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CursorOwner {
    /// The session is idle, so the driver opens a transaction for the
    /// cursor and ends it after the fetch.
    Driver { read_only: bool },
    /// The user's transaction is open, so the cursor sits behind a
    /// savepoint that a refused DECLARE can roll back to.
    Savepoint,
}

/// The flight for one statement, from its class, the session's tracked
/// status and whether the connection is read-only.
pub(crate) fn plan(class: StatementClass, state: KnownState, read_only: bool) -> Flight {
    match class {
        StatementClass::CopyFromStdin => {
            return Flight::Refuse(DriverError::Unsupported {
                feature: UnsupportedFeature::CopyFromStdinInEditor,
            });
        }
        StatementClass::CopyToStdout => {
            return Flight::Refuse(DriverError::Unsupported {
                feature: UnsupportedFeature::CopyToStdoutInEditor,
            });
        }
        StatementClass::TwoPhase if read_only => {
            return Flight::Refuse(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard));
        }
        _ => {}
    }
    match (state, class) {
        // An aborted block refuses everything but its own end, so there
        // is nothing to wrap and no cursor to open.
        (KnownState::Failed, _) => Flight::Simple(Wrap::None),
        (KnownState::Idle, StatementClass::RowSource) => Flight::Cursor(CursorOwner::Driver { read_only }),
        (KnownState::InTransaction, StatementClass::RowSource) => Flight::Cursor(CursorOwner::Savepoint),
        (KnownState::Idle, StatementClass::TransactionStart) if read_only => Flight::Simple(Wrap::ReadOnlyAfterStart),
        (KnownState::Idle, StatementClass::Other { .. } | StatementClass::Undetermined) if read_only => {
            Flight::Simple(Wrap::ReadOnlyTransaction)
        }
        _ => Flight::Simple(Wrap::None),
    }
}

/// How a `COPY ... FROM STDIN` with its rows goes to the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CopyFlight {
    /// In a transaction of the driver's own, so the statement tokio-postgres
    /// prepares under a name and the Bind that runs it reach the same
    /// server connection behind a transaction pooler. A COPY on its own
    /// is atomic already, so the wrap changes nothing else. A read-only
    /// session starts it READ ONLY, and the server refuses the COPY as it
    /// refuses any other write.
    Wrapped { read_only: bool },
    /// Inside the session's transaction, which a read-only session started
    /// READ ONLY, or its failed one, which refuses the COPY itself.
    Plain,
}

pub(crate) fn copy_plan(state: KnownState, read_only: bool) -> CopyFlight {
    match state {
        KnownState::Idle => CopyFlight::Wrapped { read_only },
        KnownState::InTransaction | KnownState::Failed => CopyFlight::Plain,
    }
}

/// The plan for a row source whose DECLARE was refused, which then runs
/// as a plain statement under the same read-only rule.
pub(crate) fn fallback(owner: CursorOwner) -> Wrap {
    match owner {
        CursorOwner::Driver { read_only: true } => Wrap::ReadOnlyTransaction,
        CursorOwner::Driver { read_only: false } | CursorOwner::Savepoint => Wrap::None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_only_plan_per_class_and_status() {
        use KnownState::{Failed, Idle, InTransaction};

        let other = StatementClass::Other { reports_rows: true };
        let commit = StatementClass::TransactionEnd {
            rollback: false,
            chain: false,
        };
        let cases = [
            (other, Idle, true, Flight::Simple(Wrap::ReadOnlyTransaction)),
            (other, Idle, false, Flight::Simple(Wrap::None)),
            (other, InTransaction, true, Flight::Simple(Wrap::None)),
            (other, Failed, true, Flight::Simple(Wrap::None)),
            (
                StatementClass::Undetermined,
                Idle,
                true,
                Flight::Simple(Wrap::ReadOnlyTransaction),
            ),
            (
                StatementClass::TransactionStart,
                Idle,
                true,
                Flight::Simple(Wrap::ReadOnlyAfterStart),
            ),
            (
                StatementClass::TransactionStart,
                Idle,
                false,
                Flight::Simple(Wrap::None),
            ),
            (commit, InTransaction, true, Flight::Simple(Wrap::None)),
            (
                StatementClass::RowSource,
                Idle,
                true,
                Flight::Cursor(CursorOwner::Driver { read_only: true }),
            ),
            (
                StatementClass::RowSource,
                InTransaction,
                true,
                Flight::Cursor(CursorOwner::Savepoint),
            ),
            (StatementClass::RowSource, Failed, false, Flight::Simple(Wrap::None)),
            (
                StatementClass::TwoPhase,
                Idle,
                true,
                Flight::Refuse(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)),
            ),
            (StatementClass::TwoPhase, Idle, false, Flight::Simple(Wrap::None)),
        ];
        for (class, state, read_only, expected) in cases {
            assert_eq!(
                plan(class, state, read_only),
                expected,
                "{class:?} {state:?} {read_only}"
            );
        }
    }

    #[test]
    fn a_copy_is_wrapped_when_idle_and_read_only_when_the_session_is() {
        use KnownState::{Failed, Idle, InTransaction};

        let cases = [
            (Idle, false, CopyFlight::Wrapped { read_only: false }),
            (Idle, true, CopyFlight::Wrapped { read_only: true }),
            (InTransaction, false, CopyFlight::Plain),
            (InTransaction, true, CopyFlight::Plain),
            (Failed, false, CopyFlight::Plain),
        ];
        for (state, read_only, expected) in cases {
            assert_eq!(copy_plan(state, read_only), expected, "{state:?} {read_only}");
        }
    }

    #[test]
    fn copy_from_stdin_is_refused_before_anything_is_sent() {
        assert!(matches!(
            plan(StatementClass::CopyFromStdin, KnownState::Idle, false),
            Flight::Refuse(DriverError::Unsupported { .. })
        ));
        assert_eq!(
            fallback(CursorOwner::Driver { read_only: true }),
            Wrap::ReadOnlyTransaction
        );
        assert_eq!(fallback(CursorOwner::Savepoint), Wrap::None);
    }
}
