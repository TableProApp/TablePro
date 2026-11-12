use std::sync::Arc;

use async_trait::async_trait;
use tokio_util::sync::CancellationToken;

use crate::capabilities::DriverCapabilities;
use crate::connect_options::ConnectOptions;
use crate::connection::Connection;
use crate::engine_category::EngineCategory;
use crate::error::DriverError;

/// One database engine, before any connection to it exists.
#[async_trait]
pub trait DatabaseDriver: Send + Sync {
    fn id(&self) -> &'static str;

    fn display_name(&self) -> &'static str;

    /// What the engine can do, for the connect dialog and the save
    /// paths to decide what to offer before a connection is open.
    fn capabilities(&self) -> &'static DriverCapabilities;

    /// The family the engine is listed under.
    fn category(&self) -> EngineCategory {
        EngineCategory::of(self.capabilities().data_model)
    }

    /// Open a connection. `cancel` aborts the connect itself, including a
    /// login the server is slow to answer.
    async fn connect(
        &self,
        options: ConnectOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn Connection>, DriverError>;
}
