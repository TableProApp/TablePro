use std::collections::HashSet;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tablepro_core::dialect::SqlDialect;
use tablepro_core::sql_syntax::HistoryRecording;
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;
use tablepro_storage::query_history::{
    Entry, HistoryCursor, HistoryPageRequest, HistoryQuery, MAX_PAGE_SIZE, MAX_QUERY_BYTES, NewEntry, Outcome,
    RunDetails, RunSource, StatementType, StatusFilter,
};
use tablepro_storage::{ConnectionStore, QueryHistory, StoragePaths};
use uuid::Uuid;

use crate::error::CoreError;
use crate::export::write_whole_file;
use crate::library::{optional_id, parse_ids};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

#[derive(uniffi::Object)]
pub struct QueryHistoryStore {
    pub(crate) history: QueryHistory,
    pub(crate) tasks: Tasks,
    // Read to turn a project into its connections; None for a core with no library.
    connections: Option<ConnectionStore>,
}

// A run as the editor saw it end. Instants are milliseconds from the Unix epoch, which the store keeps as whole
// seconds; durations are microseconds, so a run under a millisecond keeps its time.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryRun {
    pub sql: String,
    pub executed_at_ms: i64,
    pub duration_us: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: HistoryOutcomeTag,
    pub details: HistoryRunDetails,
}

// What the app knew of a run beyond its outcome; None where it did not say, as for every run an older build recorded.
#[derive(Debug, Clone, Default, PartialEq, Eq, uniffi::Record)]
pub struct HistoryRunDetails {
    pub database: Option<String>,
    pub schema: Option<String>,
    pub source: Option<HistorySourceTag>,
    pub statement_type: Option<StatementTypeTag>,
    // The client's time to the first row, and the time the engine reported, where its protocol carries one.
    pub first_row_us: Option<i64>,
    pub server_us: Option<i64>,
    // The statement's shape as the app's grammar reads it. It never leaves the device, so a run another device
    // recorded comes without one (`QueryHistoryStore::entries_without_fingerprint`).
    pub fingerprint: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistorySourceTag {
    Editor,
    Explain,
    TableBrowse,
    RowEdit,
    StructureDdl,
    Import,
    Mcp,
    Script,
    Shortcuts,
    CommandLine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StatementTypeTag {
    Select,
    Insert,
    Update,
    Delete,
    Ddl,
    Other,
}

// The History pane's outcomes: Failed is every run that did not succeed, a cancelled one included.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryStatusTag {
    Any,
    Succeeded,
    Failed,
}

// What the History pane shows. Every word of `text` appears in the run, in any case. An empty list of connections or
// sources matches nothing; a run that names no source matches only None. Times are milliseconds, both ends inclusive.
// `project_id` keeps the runs of the connections that project holds now, so a run whose connection was deleted shows
// only without one; None, and an id no project holds, keep every run.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryFilterArg {
    pub text: String,
    pub connection_ids: Option<Vec<String>>,
    pub project_id: Option<String>,
    pub sources: Option<Vec<HistorySourceTag>>,
    pub status: HistoryStatusTag,
    pub executed_after_ms: Option<i64>,
    pub executed_before_ms: Option<i64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HistoryFingerprintArg {
    pub id: i64,
    pub fingerprint: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryOutcomeTag {
    Succeeded,
    Failed { message: String },
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryEntryInfo {
    // The rowid pages, pins and deletes name; it never leaves the device.
    pub id: i64,
    // The id the entry syncs under, UUID text (core ADR 0052).
    pub record_id: String,
    pub sql: String,
    // None for a run stored without one.
    pub connection_id: Option<String>,
    pub connection_name: String,
    pub driver_id: String,
    pub executed_at_ms: i64,
    pub duration_us: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: HistoryOutcomeTag,
    pub pinned: bool,
    pub details: HistoryRunDetails,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryPageInfo {
    pub entries: Vec<HistoryEntryInfo>,
    // None on the last page.
    pub next: Option<HistoryCursorArg>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryExportFormat {
    // Each run as it ran, under comments that say where and when.
    Sql,
    Csv,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HistoryCursorArg {
    pub pinned: bool,
    pub executed_at_secs: i64,
    pub id: i64,
}

impl QueryHistoryStore {
    // The prune keeps every entry however old and drops the oldest past the store's cap.
    pub(crate) async fn open(
        paths: StoragePaths,
        tasks: Tasks,
        connections: Option<ConnectionStore>,
    ) -> Result<Arc<Self>, CoreError> {
        let history = QueryHistory::open(&paths).await?;
        match history.prune(0).await {
            Ok(report) if report.removed_anything() => {
                tracing::info!(over_cap = report.over_cap, "pruned the query history");
            }
            Ok(_) => {}
            Err(error) => tracing::warn!(%error, "could not prune the query history"),
        }
        Ok(Arc::new(Self {
            history,
            tasks,
            connections,
        }))
    }
}

impl QueryHistoryStore {
    // A statement an MCP client ran, under the editor's rules.
    pub(crate) async fn record_entry(&self, entry: NewEntry, dialect: Arc<dyn SqlDialect>) {
        if withheld(entry.connection_id, &entry.query, dialect.as_ref()) {
            return;
        }
        if let Err(error) = self.history.record(entry).await {
            tracing::warn!(%error, "could not record an MCP client's statement");
        }
    }
}

#[uniffi::export]
impl QueryHistoryStore {
    // None when the engine withholds the statement, the session is offline, or the text is past the store's cap.
    pub async fn record(&self, session: Arc<DatabaseSession>, run: HistoryRun) -> Result<Option<i64>, CoreError> {
        let history = self.history.clone();
        let session = session.session().clone();
        on_runtime(&self.tasks, async move {
            let Some(entry) = kept(&session, run) else {
                return Ok(None);
            };
            Ok(Some(history.record(entry).await?))
        })
        .await
    }

    // Pinned entries first, then newest.
    pub async fn search(
        &self,
        filter: HistoryFilterArg,
        after: Option<HistoryCursorArg>,
        limit: u32,
    ) -> Result<HistoryPageInfo, CoreError> {
        let project = optional_id(filter.project_id.as_deref())?;
        let query = HistoryQuery::try_from(filter)?;
        let request = HistoryPageRequest {
            after: after.as_ref().map(HistoryCursorArg::cursor),
            limit: usize::try_from(limit).unwrap_or(MAX_PAGE_SIZE).min(MAX_PAGE_SIZE),
        };
        let history = self.history.clone();
        let connections = self.connections.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let query = within_project(query, project, connections, tasks).await?;
            let page = history.search_page(&query, request).await?;
            let next = page.next.and(page.entries.last()).map(HistoryCursorArg::after);
            Ok(HistoryPageInfo {
                entries: page.entries.into_iter().map(HistoryEntryInfo::from).collect(),
                next,
            })
        })
        .await
    }

    // The person's deletion: each entry leaves a tombstone until sync has pushed it.
    pub async fn delete(&self, ids: Vec<i64>) -> Result<(), CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            history.delete_returning(&ids).await?;
            Ok(())
        })
        .await
    }

    // The person's deletion of everything `filter` matches, as the pane clears what it shows. Returns the record ids
    // that went, in rowid order, so the app can drop the same runs from its own store.
    pub async fn delete_matching(&self, filter: HistoryFilterArg) -> Result<Vec<String>, CoreError> {
        let project = optional_id(filter.project_id.as_deref())?;
        let query = HistoryQuery::try_from(filter)?;
        let history = self.history.clone();
        let connections = self.connections.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let query = within_project(query, project, connections, tasks).await?;
            Ok(history
                .delete_matching(&query)
                .await?
                .iter()
                .map(ToString::to_string)
                .collect())
        })
        .await
    }

    // Oldest first, at most `limit`: runs a pull or an older build brought, whose shape the app reads with its grammar.
    pub async fn entries_without_fingerprint(&self, limit: u32) -> Result<Vec<HistoryEntryInfo>, CoreError> {
        let limit = usize::try_from(limit).unwrap_or(MAX_PAGE_SIZE);
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            Ok(history
                .without_fingerprint(limit)
                .await?
                .into_iter()
                .map(HistoryEntryInfo::from)
                .collect())
        })
        .await
    }

    // In one commit, by rowid.
    pub async fn set_fingerprints(&self, fingerprints: Vec<HistoryFingerprintArg>) -> Result<(), CoreError> {
        let pairs: Vec<(i64, i64)> = fingerprints.iter().map(|arg| (arg.id, arg.fingerprint)).collect();
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.set_fingerprints(&pairs).await?) }).await
    }

    // Drops unpinned entries older than `retention_days` (0 keeps every age), then the oldest past `max_entries`
    // (0 keeps the store's own cap). Returns how many went.
    pub async fn prune(&self, retention_days: u32, max_entries: u32) -> Result<u64, CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            let report = match max_entries {
                0 => history.prune(retention_days).await?,
                kept => history.prune_keeping(retention_days, kept).await?,
            };
            Ok(report.total())
        })
        .await
    }

    pub async fn clear(&self) -> Result<(), CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            history.clear_all().await?;
            Ok(())
        })
        .await
    }

    // A pinned run comes first in every search and stays through the store's pruning.
    pub async fn set_pinned(&self, id: i64, pinned: bool) -> Result<(), CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move { Ok(history.set_pinned(id, pinned).await?) }).await
    }

    // The runs `ids` names, pinned first then newest, into the file at `path`, which appears only once whole.
    pub async fn export(&self, ids: Vec<i64>, format: HistoryExportFormat, path: String) -> Result<(), CoreError> {
        let history = self.history.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let text = match format {
                HistoryExportFormat::Sql => history.export_sql(&ids).await?,
                HistoryExportFormat::Csv => history.export_csv(&ids).await?,
            };
            tasks
                .spawn_blocking_task(move || write_whole_file(&path, text.as_bytes()))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        })
        .await
    }
}

// The project's connections narrow the ones the filter picked, or stand for them when it picked none.
async fn within_project(
    mut query: HistoryQuery,
    project: Option<Uuid>,
    connections: Option<ConnectionStore>,
    tasks: Tasks,
) -> Result<HistoryQuery, CoreError> {
    let (Some(project), Some(store)) = (project, connections) else {
        return Ok(query);
    };
    let members = tasks
        .spawn_blocking_task(move || members(&store, project))
        .await
        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
    if let Some(members) = members {
        query.connections = Some(match query.connections.take() {
            Some(picked) => {
                let held: HashSet<Uuid> = members.into_iter().collect();
                picked.into_iter().filter(|id| held.contains(id)).collect()
            }
            None => members,
        });
    }
    Ok(query)
}

// None when no project holds the id, which is every connection.
fn members(store: &ConnectionStore, project: Uuid) -> Result<Option<Vec<Uuid>>, CoreError> {
    let list = store.list_blocking()?;
    Ok(list.resolved_scope(Some(project)).map(|project| {
        list.scoped(Some(project))
            .connections
            .iter()
            .map(|connection| connection.id)
            .collect()
    }))
}

// Without a dialect nobody can say which statements hold a secret, so nothing is kept.
fn kept(session: &Session, run: HistoryRun) -> Option<NewEntry> {
    let connection = session.id();
    let Some(dialect) = session.current_dialect() else {
        tracing::debug!(%connection, "no dialect, so the run is not recorded");
        return None;
    };
    if withheld(connection, &run.sql, dialect.as_ref()) {
        return None;
    }
    let metadata = session.metadata();
    Some(NewEntry {
        record_id: Uuid::new_v4(),
        query: run.sql,
        driver_id: metadata.driver_id.clone(),
        connection_id: metadata.id,
        connection_name: metadata.name.clone(),
        executed_at: from_millis(run.executed_at_ms),
        duration_us: run.duration_us,
        rows_affected: run.rows_affected,
        outcome: run.outcome.into(),
        details: run.details.into(),
    })
}

impl HistoryCursorArg {
    fn after(entry: &Entry) -> Self {
        Self {
            pinned: entry.pinned,
            executed_at_secs: seconds(entry.executed_at),
            id: entry.id,
        }
    }

    // The store makes its cursor only from an entry, so one is rebuilt from the three fields the cursor reads.
    fn cursor(&self) -> HistoryCursor {
        HistoryCursor::after(&Entry {
            id: self.id,
            record_id: Uuid::nil(),
            query: String::new(),
            driver_id: String::new(),
            connection_id: Uuid::nil(),
            connection_name: String::new(),
            executed_at: from_seconds(self.executed_at_secs),
            duration_us: None,
            rows_affected: None,
            success: true,
            cancelled: false,
            pinned: self.pinned,
            error: None,
            details: RunDetails::default(),
        })
    }
}

impl From<Entry> for HistoryEntryInfo {
    fn from(entry: Entry) -> Self {
        let outcome = match (entry.cancelled, entry.success) {
            (true, _) => HistoryOutcomeTag::Cancelled,
            (false, true) => HistoryOutcomeTag::Succeeded,
            (false, false) => HistoryOutcomeTag::Failed {
                message: entry.error.unwrap_or_default(),
            },
        };
        Self {
            id: entry.id,
            record_id: entry.record_id.to_string(),
            sql: entry.query,
            connection_id: (!entry.connection_id.is_nil()).then(|| entry.connection_id.to_string()),
            connection_name: entry.connection_name,
            driver_id: entry.driver_id,
            executed_at_ms: millis(entry.executed_at),
            duration_us: entry.duration_us,
            rows_affected: entry.rows_affected,
            outcome,
            pinned: entry.pinned,
            details: entry.details.into(),
        }
    }
}

impl From<RunDetails> for HistoryRunDetails {
    fn from(details: RunDetails) -> Self {
        Self {
            database: details.database,
            schema: details.schema,
            source: details.source.map(HistorySourceTag::from),
            statement_type: details.statement_type.map(StatementTypeTag::from),
            first_row_us: details.first_row_us,
            server_us: details.server_us,
            fingerprint: details.fingerprint,
        }
    }
}

impl From<HistoryRunDetails> for RunDetails {
    fn from(details: HistoryRunDetails) -> Self {
        Self {
            database: details.database,
            schema: details.schema,
            source: details.source.map(RunSource::from),
            statement_type: details.statement_type.map(StatementType::from),
            first_row_us: details.first_row_us,
            server_us: details.server_us,
            fingerprint: details.fingerprint,
        }
    }
}

impl From<RunSource> for HistorySourceTag {
    fn from(source: RunSource) -> Self {
        match source {
            RunSource::Editor => Self::Editor,
            RunSource::Explain => Self::Explain,
            RunSource::TableBrowse => Self::TableBrowse,
            RunSource::RowEdit => Self::RowEdit,
            RunSource::StructureDdl => Self::StructureDdl,
            RunSource::Import => Self::Import,
            RunSource::Mcp => Self::Mcp,
            RunSource::Script => Self::Script,
            RunSource::Shortcuts => Self::Shortcuts,
            RunSource::CommandLine => Self::CommandLine,
        }
    }
}

impl From<HistorySourceTag> for RunSource {
    fn from(source: HistorySourceTag) -> Self {
        match source {
            HistorySourceTag::Editor => Self::Editor,
            HistorySourceTag::Explain => Self::Explain,
            HistorySourceTag::TableBrowse => Self::TableBrowse,
            HistorySourceTag::RowEdit => Self::RowEdit,
            HistorySourceTag::StructureDdl => Self::StructureDdl,
            HistorySourceTag::Import => Self::Import,
            HistorySourceTag::Mcp => Self::Mcp,
            HistorySourceTag::Script => Self::Script,
            HistorySourceTag::Shortcuts => Self::Shortcuts,
            HistorySourceTag::CommandLine => Self::CommandLine,
        }
    }
}

impl From<StatementType> for StatementTypeTag {
    fn from(kind: StatementType) -> Self {
        match kind {
            StatementType::Select => Self::Select,
            StatementType::Insert => Self::Insert,
            StatementType::Update => Self::Update,
            StatementType::Delete => Self::Delete,
            StatementType::Ddl => Self::Ddl,
            StatementType::Other => Self::Other,
        }
    }
}

impl From<StatementTypeTag> for StatementType {
    fn from(kind: StatementTypeTag) -> Self {
        match kind {
            StatementTypeTag::Select => Self::Select,
            StatementTypeTag::Insert => Self::Insert,
            StatementTypeTag::Update => Self::Update,
            StatementTypeTag::Delete => Self::Delete,
            StatementTypeTag::Ddl => Self::Ddl,
            StatementTypeTag::Other => Self::Other,
        }
    }
}

impl TryFrom<HistoryFilterArg> for HistoryQuery {
    type Error = CoreError;

    fn try_from(filter: HistoryFilterArg) -> Result<Self, CoreError> {
        let mut query = HistoryQuery::from_input(&filter.text);
        query.connections = filter.connection_ids.as_deref().map(parse_ids).transpose()?;
        query.sources = filter
            .sources
            .map(|sources| sources.into_iter().map(RunSource::from).collect());
        query.status = match filter.status {
            HistoryStatusTag::Any => StatusFilter::Any,
            HistoryStatusTag::Succeeded => StatusFilter::Succeeded,
            HistoryStatusTag::Failed => StatusFilter::Unsuccessful,
        };
        query.executed_after = filter.executed_after_ms.map(from_millis);
        query.executed_before = filter.executed_before_ms.map(from_millis);
        Ok(query)
    }
}

impl From<HistoryOutcomeTag> for Outcome {
    fn from(outcome: HistoryOutcomeTag) -> Self {
        match outcome {
            HistoryOutcomeTag::Succeeded => Self::Success,
            HistoryOutcomeTag::Failed { message } => Self::Error(message),
            HistoryOutcomeTag::Cancelled => Self::Cancelled,
        }
    }
}

// A time past what the clock holds lands on the epoch rather than panicking.
pub(crate) fn from_millis(millis: i64) -> SystemTime {
    from_epoch(Duration::from_millis(millis.unsigned_abs()), millis < 0)
}

fn from_seconds(seconds: i64) -> SystemTime {
    from_epoch(Duration::from_secs(seconds.unsigned_abs()), seconds < 0)
}

fn from_epoch(span: Duration, before: bool) -> SystemTime {
    let time = match before {
        true => UNIX_EPOCH.checked_sub(span),
        false => UNIX_EPOCH.checked_add(span),
    };
    time.unwrap_or(UNIX_EPOCH)
}

pub(crate) fn millis(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_millis()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_millis()).map_or(i64::MIN, |value| -value),
    }
}

// As the store counts them, so a rebuilt cursor compares as the one it stands for.
fn seconds(time: SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(after) => i64::try_from(after.as_secs()).unwrap_or(i64::MAX),
        Err(before) => i64::try_from(before.duration().as_secs()).map_or(i64::MIN, |value| -value),
    }
}

impl std::fmt::Debug for QueryHistoryStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QueryHistoryStore")
            .field("path", &self.history.path())
            .finish_non_exhaustive()
    }
}

fn withheld(connection: Uuid, sql: &str, dialect: &dyn SqlDialect) -> bool {
    // The store refuses it anyway, and reading it for secrets would lex it once per way the server may read it.
    if sql.len() > MAX_QUERY_BYTES {
        tracing::debug!(%connection, "a run too large for the history was not recorded");
        return true;
    }
    if let HistoryRecording::Withhold(reason) = dialect.history_recording(sql) {
        tracing::debug!(%connection, ?reason, "a run was kept out of the history");
        return true;
    }
    false
}
