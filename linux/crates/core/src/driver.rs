use async_trait::async_trait;

use crate::connection::{ConnectOptions, Connection};
use crate::error::DriverError;

#[async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn default_port(&self) -> u16;

    fn is_file_based(&self) -> bool {
        false
    }

    /// Whether a multi-statement DDL batch can roll back as a unit, so
    /// the structure editor's Save runs through
    /// `Connection::execute_in_transaction` instead of statement by
    /// statement. MySQL commits implicitly on every DDL statement: the
    /// transaction would end after the first one and a later failure
    /// would leave the earlier statements applied, which is worse than
    /// not opening one at all.
    fn ddl_is_transactional(&self) -> bool {
        false
    }

    /// Whether `ExecResult::rows_affected` carries a real count for
    /// UPDATE and DELETE. The inline-edit Save path reads a zero count
    /// as an optimistic-concurrency conflict, so a driver that cannot
    /// produce one must say so or every successful save reports a lost
    /// update. ClickHouse applies both as asynchronous mutations and
    /// returns no row count for either.
    fn reports_rows_affected(&self) -> bool {
        true
    }

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError>;
}
