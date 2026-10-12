use std::sync::Arc;

use tablepro_core::ddl::TableDefinition;
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::{ObjectInfo, RowIdentity, SchemaInfo, TableEstimate};
use tablepro_core::{
    ColumnInfo, CommitResolution, EditorSession, ForeignKeyInfo, IndexInfo, QueryResult, ResultEvent, ServerInfo,
    WriteReport,
};

use crate::{CloseBehaviour, FakeDialect, FakeReply, Replies};

/// Everything a `FakeConnection` answers, set up before the code under
/// test gets the connection.
///
/// Each call that has no scripted answer fails with a protocol error
/// naming the method, so a test that forgot one fails rather than
/// hanging.
#[derive(Debug, Clone)]
pub struct ConnectionScript {
    pub server_info: ServerInfo,
    pub dialect: Arc<dyn SqlDialect>,
    pub read_only: bool,
    pub close: CloseBehaviour,
    pub probe: Replies<FakeReply<()>>,
    pub list_schemas: Replies<FakeReply<Vec<SchemaInfo>>>,
    pub list_objects: Replies<FakeReply<Vec<ObjectInfo>>>,
    pub fetch_columns: Replies<FakeReply<Vec<ColumnInfo>>>,
    pub fetch_indexes: Replies<FakeReply<Vec<IndexInfo>>>,
    pub fetch_foreign_keys: Replies<FakeReply<Vec<ForeignKeyInfo>>>,
    pub fetch_table_definition: Replies<FakeReply<TableDefinition>>,
    pub row_identity: Replies<FakeReply<RowIdentity>>,
    pub table_estimate: Replies<FakeReply<TableEstimate>>,
    pub query_bound: Replies<FakeReply<QueryResult>>,
    pub count_rows: Replies<FakeReply<u64>>,
    /// The events each read sends to its sink, in order.
    pub stream_read: Replies<FakeReply<Vec<ResultEvent>>>,
    pub write_batch: Replies<FakeReply<WriteReport>>,
    pub resolve_commit: Replies<FakeReply<CommitResolution>>,
    pub open_editor_session: Replies<FakeReply<Arc<dyn EditorSession>>>,
}

impl Default for ConnectionScript {
    fn default() -> Self {
        Self {
            server_info: ServerInfo::new("Fake", "1.0", 1, 0, 0),
            dialect: Arc::new(FakeDialect),
            read_only: false,
            close: CloseBehaviour::Immediate,
            probe: Replies::default(),
            list_schemas: Replies::default(),
            list_objects: Replies::default(),
            fetch_columns: Replies::default(),
            fetch_indexes: Replies::default(),
            fetch_foreign_keys: Replies::default(),
            fetch_table_definition: Replies::default(),
            row_identity: Replies::default(),
            table_estimate: Replies::default(),
            query_bound: Replies::default(),
            count_rows: Replies::default(),
            stream_read: Replies::default(),
            write_batch: Replies::default(),
            resolve_commit: Replies::default(),
            open_editor_session: Replies::default(),
        }
    }
}
