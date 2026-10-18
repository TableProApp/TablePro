use std::sync::atomic::{AtomicBool, Ordering};

use sqlx::Executor as _;
use sqlx::mysql::MySqlConnection;
use tablepro_core::{TransactionState, Value};

use crate::decode::decode_row;
use crate::errors::{map_error, server_number};
use crate::flavour::MySqlFlavour;
use crate::mysql_timestamp_mode::MySqlTimestampMode;
use crate::mysql_wire_format::MySqlWireFormat;

/// MariaDB keeps the answer in a session variable.
const MARIADB_SQL: &str = "SELECT @@in_transaction";

/// MySQL has no such variable; performance_schema's current
/// transaction event for this thread says whether one is open.
const MYSQL_SQL: &str = "SELECT COUNT(*) FROM performance_schema.events_transactions_current \
     WHERE THREAD_ID = PS_CURRENT_THREAD_ID() AND STATE = 'ACTIVE'";

/// ER_TABLEACCESS_DENIED_ERROR, ER_NO_SUCH_TABLE and ER_SP_DOES_NOT_EXIST:
/// the login cannot read performance_schema, it is off, or the server is
/// older than PS_CURRENT_THREAD_ID (8.0.16).
const UNAVAILABLE: [u16; 3] = [1142, 1146, 1305];

/// Asks an editor session's server whether a transaction is open.
#[derive(Debug)]
pub(crate) struct TransactionProbe {
    flavour: MySqlFlavour,
    /// Set once the server said the question cannot be asked, so a login
    /// without access is not refused again after every run.
    unavailable: AtomicBool,
}

impl TransactionProbe {
    pub(crate) fn new(flavour: MySqlFlavour) -> Self {
        Self {
            flavour,
            unavailable: AtomicBool::new(false),
        }
    }

    pub(crate) async fn state(&self, connection: &mut MySqlConnection) -> TransactionState {
        if self.unavailable.load(Ordering::SeqCst) {
            return TransactionState::Unknown;
        }
        let sql = match self.flavour {
            MySqlFlavour::MySql => MYSQL_SQL,
            MySqlFlavour::MariaDb => MARIADB_SQL,
        };
        let row = match connection.fetch_one(sqlx::raw_sql(sql)).await {
            Ok(row) => row,
            Err(error) => {
                let mapped = map_error(&error, self.flavour);
                if server_number(&mapped).is_some_and(|number| UNAVAILABLE.contains(&number)) {
                    self.unavailable.store(true, Ordering::SeqCst);
                }
                return TransactionState::Unknown;
            }
        };
        let values = decode_row(&row, MySqlWireFormat::Text, MySqlTimestampMode::SessionLocal);
        state_of(values.first())
    }
}

fn state_of(value: Option<&Value>) -> TransactionState {
    match value.and_then(Value::as_exact_u64) {
        Some(0) => TransactionState::Idle,
        Some(_) => TransactionState::InTransaction,
        None => TransactionState::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_count_or_flag_reads_as_the_state() {
        assert_eq!(state_of(Some(&Value::Int(0))), TransactionState::Idle);
        assert_eq!(state_of(Some(&Value::Int(1))), TransactionState::InTransaction);
        assert_eq!(state_of(Some(&Value::Null)), TransactionState::Unknown);
        assert_eq!(state_of(None), TransactionState::Unknown);
    }
}
