use std::sync::Arc;

use async_trait::async_trait;
use tokio_util::sync::{CancellationToken, WaitForCancellationFutureOwned};

use crate::call_options::CallOptions;
use crate::column::ColumnInfo;
use crate::commit::{CommitResolution, CommitToken};
use crate::ddl::{InboundForeignKey, OutboundForeignKey, TableDefinition};
use crate::dialect::SqlDialect;
use crate::editor_session::{EditorSession, EditorSessionOptions};
use crate::error::DriverError;
use crate::foreign_key_info::ForeignKeyInfo;
use crate::keyspace::{KeyListing, KeyPage, KeyScan, KeyWindow};
use crate::link_watch::LinkState;
use crate::meta::{IndexInfo, ObjectInfo, ObjectScope, RowIdentity, SchemaInfo, TableEstimate, TableRef};
use crate::query_result::QueryResult;
use crate::read_statement::ReadStatement;
use crate::result_sink::ResultSink;
use crate::row_limit::RowLimit;
use crate::server_info::ServerInfo;
use crate::server_page::{ServerPage, ServerPageRequest};
use crate::statement::Statement;
use crate::stream_summary::StreamSummary;
use crate::unsupported_feature::UnsupportedFeature;
use crate::write_batch::WriteBatch;
use crate::write_report::WriteReport;

/// A workspace's link to one server: the pool behind the sidebar, the
/// grid and every save.
///
/// Each call runs on a task the connection owns, not on the caller's
/// future, so dropping the caller cancels the call instead of leaving
/// the server working for nobody (`OwnedCalls`). A call returns within
/// its deadline plus the liveness policy's cancel grace.
#[async_trait]
pub trait Connection: Send + Sync {
    fn server_info(&self) -> &ServerInfo;

    /// Built from the server version at connect, so generated SQL
    /// matches what this server accepts.
    fn dialect(&self) -> Arc<dyn SqlDialect>;

    fn read_only(&self) -> bool;

    fn link_state(&self) -> LinkState;

    /// Resolves once the link is lost, for a monitor that waits on it
    /// without holding the connection busy.
    fn lost(&self) -> WaitForCancellationFutureOwned;

    /// Whether the server answers. Never waits for a pool slot: a busy
    /// pool is not a dead server, so with every slot taken the probe
    /// opens a connection of its own.
    async fn probe(&self, options: CallOptions) -> Result<(), DriverError>;

    async fn list_schemas(&self, options: CallOptions) -> Result<Vec<SchemaInfo>, DriverError>;

    async fn list_objects(&self, scope: &ObjectScope, options: CallOptions) -> Result<Vec<ObjectInfo>, DriverError>;

    async fn fetch_columns(&self, table: &TableRef, options: CallOptions) -> Result<Vec<ColumnInfo>, DriverError>;

    async fn fetch_indexes(&self, table: &TableRef, options: CallOptions) -> Result<Vec<IndexInfo>, DriverError>;

    async fn fetch_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<ForeignKeyInfo>, DriverError>;

    /// The table's own foreign keys as `fetch_foreign_keys` lists them,
    /// each with whether its two sides compare alike.
    async fn fetch_outbound_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<OutboundForeignKey>, DriverError>;

    /// The foreign keys of other tables that point at this one, as
    /// `fetch_table_definition` lists them, without the rest of the
    /// definition.
    async fn fetch_inbound_foreign_keys(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<Vec<InboundForeignKey>, DriverError>;

    /// The table as structure changes plan against it, read in one call
    /// so its columns, keys and dependents come from the same moment.
    async fn fetch_table_definition(
        &self,
        table: &TableRef,
        options: CallOptions,
    ) -> Result<TableDefinition, DriverError>;

    async fn row_identity(&self, table: &TableRef, options: CallOptions) -> Result<RowIdentity, DriverError>;

    async fn table_estimate(&self, table: &TableRef, options: CallOptions) -> Result<TableEstimate, DriverError>;

    /// Run a generated read and keep at most `limit` rows, marking the
    /// result truncated when there were more.
    async fn query_bound(
        &self,
        statement: &Statement,
        limit: RowLimit,
        options: CallOptions,
    ) -> Result<QueryResult, DriverError>;

    /// Read one page of a generated read the server pages itself, on an
    /// engine whose dialect says it does (`TablePaging::ServerState`).
    async fn query_server_page(
        &self,
        _statement: &Statement,
        _request: ServerPageRequest,
        _options: CallOptions,
    ) -> Result<ServerPage, DriverError> {
        Err(DriverError::Unsupported {
            feature: UnsupportedFeature::ServerPaging,
        })
    }

    async fn count_rows(&self, statement: &Statement, options: CallOptions) -> Result<u64, DriverError>;

    /// Stream every row of a read into `sink`, with no row limit.
    ///
    /// It runs on a connection of its own, never a pool slot, because an
    /// export can take minutes. The read is held read-only by the engine
    /// for its whole length, so user SQL that tries to write fails with
    /// a `ReadOnly` error. Each result set arrives as `ResultSetStarted`,
    /// then `Rows`, then `ResultSetFinished`, and each event is accepted
    /// before the next rows are read.
    async fn stream_read(
        &self,
        read: &ReadStatement,
        sink: Box<dyn ResultSink>,
        options: CallOptions,
    ) -> Result<StreamSummary, DriverError>;

    /// Apply a save. On an engine that cannot suspend foreign keys, a
    /// batch that asks for it fails before anything is sent.
    async fn write_batch(&self, batch: &WriteBatch, options: CallOptions) -> Result<WriteReport, DriverError>;

    /// Ask the server what became of a write whose commit was sent and
    /// never answered. A commit the engine keeps no record of is
    /// `Unresolvable`, and an engine whose `commit_resolution` is
    /// `Unavailable` keeps a record of none: neither is an error.
    async fn resolve_commit(&self, token: &CommitToken, options: CallOptions) -> Result<CommitResolution, DriverError>;

    /// Open an editor tab's own connection. It outlives this one: the
    /// tab owns it, and closing the workspace does not close it.
    async fn open_editor_session(
        &self,
        options: EditorSessionOptions,
        cancel: CancellationToken,
    ) -> Result<Arc<dyn EditorSession>, DriverError>;

    /// Stop every call and release the pool. Safe to call more than
    /// once, and it never closes an editor session.
    async fn close(&self) -> Result<(), DriverError>;

    /// A key-value engine's keys: those matching the scan's pattern, up to
    /// its limit, read in steps that never hold the server for long. A
    /// relational engine keeps this default.
    async fn scan_keys(&self, _scan: &KeyScan, _options: CallOptions) -> Result<KeyListing, DriverError> {
        Err(DriverError::Unsupported {
            feature: UnsupportedFeature::Keys,
        })
    }

    /// One window of a key's value, or `None` when the key does not
    /// exist. `key` is the name `scan_keys` listed.
    async fn read_key(
        &self,
        _key: &str,
        _window: &KeyWindow,
        _options: CallOptions,
    ) -> Result<Option<KeyPage>, DriverError> {
        Err(DriverError::Unsupported {
            feature: UnsupportedFeature::Keys,
        })
    }
}
