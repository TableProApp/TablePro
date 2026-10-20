use tablepro_core::TransactionState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpenTransaction {
    Open,
    /// A statement failed inside it, so the server refuses all but a
    /// rollback.
    Failed,
}

/// Whether closing the tab would throw away work the server holds for
/// it: an open transaction, or one that failed and still needs a
/// rollback. A lost session holds nothing any more. `Unknown` counts
/// once something ran, because the engine cannot say what that left.
pub fn transaction_dirty(lost: bool, state: Option<TransactionState>, has_run: bool) -> bool {
    if lost {
        return false;
    }
    match state {
        Some(TransactionState::InTransaction | TransactionState::Failed) => true,
        Some(TransactionState::Unknown) => has_run,
        Some(TransactionState::Idle) | None => false,
    }
}

/// A lost session has none, whatever its last run said before it went.
/// `Unknown` names nothing: the engine cannot say one is open.
pub fn open_transaction(lost: bool, state: Option<TransactionState>) -> Option<OpenTransaction> {
    if lost {
        return None;
    }
    match state {
        Some(TransactionState::InTransaction) => Some(OpenTransaction::Open),
        Some(TransactionState::Failed) => Some(OpenTransaction::Failed),
        Some(TransactionState::Idle | TransactionState::Unknown) | None => None,
    }
}

/// The line above the results that says a transaction is still open.
pub fn transaction_label(lost: bool, state: Option<TransactionState>) -> Option<String> {
    open_transaction(lost, state).map(|open| match open {
        OpenTransaction::Open => crate::i18n::gettext("Transaction open"),
        OpenTransaction::Failed => crate::i18n::gettext("Transaction failed, roll back to continue"),
    })
}

/// A failed transaction can only be rolled back.
pub fn offers_commit(lost: bool, state: Option<TransactionState>) -> bool {
    open_transaction(lost, state) == Some(OpenTransaction::Open)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transaction_dirty_cleared_when_lost() {
        for state in [TransactionState::InTransaction, TransactionState::Failed] {
            assert!(transaction_dirty(false, Some(state), true));
            assert!(!transaction_dirty(true, Some(state), true), "{state:?}");
        }
    }

    #[test]
    fn transaction_dirty_unknown_needs_a_run() {
        assert!(!transaction_dirty(false, Some(TransactionState::Unknown), false));
        assert!(transaction_dirty(false, Some(TransactionState::Unknown), true));
        assert!(!transaction_dirty(false, Some(TransactionState::Idle), true));
        assert!(!transaction_dirty(false, None, true));
    }

    #[test]
    fn only_an_open_or_failed_transaction_is_labelled() {
        assert!(transaction_label(false, Some(TransactionState::InTransaction)).is_some());
        assert!(transaction_label(false, Some(TransactionState::Failed)).is_some());
        assert_eq!(transaction_label(false, Some(TransactionState::Idle)), None);
        assert_eq!(transaction_label(false, Some(TransactionState::Unknown)), None);
    }

    #[test]
    fn a_lost_session_shows_no_open_transaction() {
        for state in [TransactionState::InTransaction, TransactionState::Failed] {
            assert_eq!(transaction_label(true, Some(state)), None, "{state:?}");
            assert_eq!(open_transaction(true, Some(state)), None, "{state:?}");
        }
    }

    #[test]
    fn an_open_transaction_is_told_from_a_failed_one() {
        assert_eq!(
            open_transaction(false, Some(TransactionState::InTransaction)),
            Some(OpenTransaction::Open)
        );
        assert_eq!(
            open_transaction(false, Some(TransactionState::Failed)),
            Some(OpenTransaction::Failed)
        );
        assert_eq!(open_transaction(false, Some(TransactionState::Unknown)), None);
        assert_eq!(open_transaction(false, None), None);
    }

    #[test]
    fn only_an_open_transaction_offers_commit() {
        assert!(offers_commit(false, Some(TransactionState::InTransaction)));
        assert!(!offers_commit(false, Some(TransactionState::Failed)));
        assert!(!offers_commit(true, Some(TransactionState::InTransaction)));
        for state in [TransactionState::Idle, TransactionState::Unknown] {
            assert!(!offers_commit(false, Some(state)), "{state:?}");
        }
        assert!(!offers_commit(false, None));
    }
}
