//! Where a connection stands with a transaction.
//!
//! DuckDB's C API has no autocommit flag to read. A transaction's id
//! stays the same from one statement to the next only inside an
//! explicit transaction, since outside one each statement runs in its
//! own, and a transaction a statement failed in refuses every statement
//! until it is rolled back.

use tablepro_core::{DriverError, TransactionState};

use crate::errors::map_error;
use crate::instance::Link;

pub(crate) fn transaction_state(link: &Link) -> TransactionState {
    match (transaction_id(link), transaction_id(link)) {
        (Ok(first), Ok(second)) if first == second => TransactionState::InTransaction,
        (Ok(_), Ok(_)) => TransactionState::Idle,
        (Err(error), _) | (_, Err(error)) if is_aborted(&error) => TransactionState::Failed,
        _ => TransactionState::Unknown,
    }
}

fn transaction_id(link: &Link) -> Result<u64, DriverError> {
    link.connection
        .query_row("SELECT txid_current()", [], |row| row.get::<_, u64>(0))
        .map_err(map_error)
}

fn is_aborted(error: &DriverError) -> bool {
    matches!(error, DriverError::Server(diagnostics) if diagnostics.message.contains("transaction is aborted"))
}
