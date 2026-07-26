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

    async fn connect(&self, opts: ConnectOptions) -> Result<Box<dyn Connection>, DriverError>;
}
