use async_trait::async_trait;

use crate::call_options::CallOptions;
use crate::error::DriverError;
use crate::result_event::RunSummary;
use crate::result_sink::ResultSink;
use crate::run_options::RunOptions;
use crate::transaction_state::TransactionState;
use crate::user_sql::UserSql;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct EditorSessionId(uuid::Uuid);

impl EditorSessionId {
    pub fn new() -> Self {
        Self(uuid::Uuid::new_v4())
    }
}

impl Default for EditorSessionId {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Display for EditorSessionId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EditorSessionState {
    Ready,
    Running,
    /// The connection is gone. An editor session is never silently
    /// reopened, because an open transaction and its temporary tables
    /// would not come back with it.
    Lost,
}

/// How an editor session is opened.
#[derive(Debug, Clone, Default)]
pub struct EditorSessionOptions {
    pub statement_timeout: Option<std::time::Duration>,
    /// The database to open the session in, where the engine binds a
    /// session's database when it connects. Elsewhere the session opens in
    /// the connection's and `EditorSession::use_database` moves it.
    pub database: Option<String>,
}

/// One editor tab's own connection to the server.
///
/// A tab holds its session for as long as it is open, because the state
/// a user builds up there is on that connection and nowhere else: an
/// open transaction, a temporary table, a session setting. Sharing a
/// pooled connection between tabs would lose all of it between runs.
#[async_trait]
pub trait EditorSession: Send + Sync {
    fn id(&self) -> EditorSessionId;

    fn state(&self) -> EditorSessionState;

    /// Run the text as the user wrote it, streaming what comes back.
    ///
    /// An error here is the session itself failing, not the SQL: a
    /// statement the server refused ends in a `RunSummary` whose end is
    /// `Failed`, which is what the results list shows.
    async fn run(
        &self,
        sql: UserSql,
        options: RunOptions,
        sink: Box<dyn ResultSink>,
    ) -> Result<RunSummary, DriverError>;

    async fn transaction_state(&self, options: CallOptions) -> Result<TransactionState, DriverError>;

    /// The database an unqualified name resolves to now, as the server
    /// last said. `None` where the driver does not follow it: the session
    /// is still in the database it opened in.
    fn database(&self) -> Option<String> {
        None
    }

    /// Move the session to the server's database `database`, keeping
    /// what it holds. Unsupported where the engine binds a session's
    /// database when it connects.
    async fn use_database(&self, _database: &str, _options: CallOptions) -> Result<(), DriverError> {
        Err(DriverError::Unsupported {
            feature: crate::UnsupportedFeature::DatabaseSwitching,
        })
    }

    async fn close(&self);
}
