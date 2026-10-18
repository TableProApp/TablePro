use tablepro_core::TransactionState;

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

/// The line above the results that says a transaction is still open.
/// A lost session has none, whatever its last run said before it went.
pub fn transaction_label(lost: bool, state: Option<TransactionState>) -> Option<String> {
    if lost {
        return None;
    }
    match state {
        Some(TransactionState::InTransaction) => Some(crate::i18n::gettext("Transaction open")),
        Some(TransactionState::Failed) => Some(crate::i18n::gettext("Transaction failed, roll back to continue")),
        Some(TransactionState::Idle | TransactionState::Unknown) | None => None,
    }
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
        }
    }
}
