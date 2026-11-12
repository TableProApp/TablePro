use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tablepro_core::sql_syntax::HistoryRecording;
use tablepro_session::Session;
use tablepro_session::runtime::Tasks;
use tablepro_storage::query_history::{
    Entry, HistoryCursor, HistoryPageRequest, HistoryQuery, MAX_PAGE_SIZE, MAX_QUERY_BYTES, NewEntry, Outcome,
};
use tablepro_storage::{QueryHistory, StoragePaths};
use uuid::Uuid;

use crate::error::CoreError;
use crate::library::parse_id;
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

#[derive(uniffi::Object)]
pub struct QueryHistoryStore {
    history: QueryHistory,
    tasks: Tasks,
}

// A run as the editor saw it end. Times are milliseconds from the Unix epoch; the store keeps whole seconds.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryRun {
    pub sql: String,
    pub executed_at_ms: i64,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: HistoryOutcomeTag,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum HistoryOutcomeTag {
    Succeeded,
    Failed { message: String },
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryEntryInfo {
    pub id: i64,
    pub sql: String,
    // None for a run stored without one.
    pub connection_id: Option<String>,
    pub connection_name: String,
    pub driver_id: String,
    pub executed_at_ms: i64,
    pub duration_ms: Option<i64>,
    pub rows_affected: Option<i64>,
    pub outcome: HistoryOutcomeTag,
    pub pinned: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HistoryPageInfo {
    pub entries: Vec<HistoryEntryInfo>,
    // None on the last page.
    pub next: Option<HistoryCursorArg>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HistoryCursorArg {
    pub pinned: bool,
    pub executed_at_secs: i64,
    pub id: i64,
}

impl QueryHistoryStore {
    // The prune keeps every entry however old and drops the oldest past the store's cap.
    pub(crate) async fn open(paths: StoragePaths, tasks: Tasks) -> Result<Arc<Self>, CoreError> {
        let history = QueryHistory::open(&paths).await?;
        match history.prune(0).await {
            Ok(report) if report.removed_anything() => {
                tracing::info!(over_cap = report.over_cap, "pruned the query history");
            }
            Ok(_) => {}
            Err(error) => tracing::warn!(%error, "could not prune the query history"),
        }
        Ok(Arc::new(Self { history, tasks }))
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

    // Every word of `text` appears in the entry, in any case. Pinned entries first, then newest.
    pub async fn search(
        &self,
        text: String,
        connection_id: Option<String>,
        after: Option<HistoryCursorArg>,
        limit: u32,
    ) -> Result<HistoryPageInfo, CoreError> {
        let mut query = HistoryQuery::from_input(&text);
        query.connection = connection_id
            .as_deref()
            .filter(|id| !id.trim().is_empty())
            .map(parse_id)
            .transpose()?;
        let request = HistoryPageRequest {
            after: after.as_ref().map(HistoryCursorArg::cursor),
            limit: usize::try_from(limit).unwrap_or(MAX_PAGE_SIZE).min(MAX_PAGE_SIZE),
        };
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            let page = history.search_page(&query, request).await?;
            let next = page.next.and(page.entries.last()).map(HistoryCursorArg::after);
            Ok(HistoryPageInfo {
                entries: page.entries.into_iter().map(HistoryEntryInfo::from).collect(),
                next,
            })
        })
        .await
    }

    pub async fn delete(&self, ids: Vec<i64>) -> Result<(), CoreError> {
        let history = self.history.clone();
        on_runtime(&self.tasks, async move {
            history.delete_returning(&ids).await?;
            Ok(())
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
}

// Without a dialect nobody can say which statements hold a secret, so nothing is kept.
fn kept(session: &Session, run: HistoryRun) -> Option<NewEntry> {
    let connection = session.id();
    let Some(dialect) = session.current_dialect() else {
        tracing::debug!(%connection, "no dialect, so the run is not recorded");
        return None;
    };
    // The store refuses it anyway, and reading it for secrets would lex it once per way the server may read it.
    if run.sql.len() > MAX_QUERY_BYTES {
        tracing::debug!(%connection, "a run too large for the history was not recorded");
        return None;
    }
    if let HistoryRecording::Withhold(reason) = dialect.history_recording(&run.sql) {
        tracing::debug!(%connection, ?reason, "a run was kept out of the history");
        return None;
    }
    let metadata = session.metadata();
    Some(NewEntry {
        query: run.sql,
        driver_id: metadata.driver_id.clone(),
        connection_id: metadata.id,
        connection_name: metadata.name.clone(),
        executed_at: from_millis(run.executed_at_ms),
        duration_ms: run.duration_ms,
        rows_affected: run.rows_affected,
        outcome: run.outcome.into(),
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
            query: String::new(),
            driver_id: String::new(),
            connection_id: Uuid::nil(),
            connection_name: String::new(),
            executed_at: from_seconds(self.executed_at_secs),
            duration_ms: None,
            rows_affected: None,
            success: true,
            cancelled: false,
            pinned: self.pinned,
            error: None,
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
            sql: entry.query,
            connection_id: (!entry.connection_id.is_nil()).then(|| entry.connection_id.to_string()),
            connection_name: entry.connection_name,
            driver_id: entry.driver_id,
            executed_at_ms: millis(entry.executed_at),
            duration_ms: entry.duration_ms,
            rows_affected: entry.rows_affected,
            outcome,
            pinned: entry.pinned,
        }
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
fn from_millis(millis: i64) -> SystemTime {
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

fn millis(time: SystemTime) -> i64 {
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
