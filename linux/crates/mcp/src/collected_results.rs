use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use serde_json::value::RawValue;
use tablepro_core::column::ResultColumn;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow, Truncation, Value};

use crate::tool_error::ToolError;

/// Notices kept from one run. A procedure that raises one per row would
/// otherwise fill the answer with them.
const MAX_NOTICES: usize = 20;

#[derive(Debug, Default)]
pub struct CollectedResults {
    pub sets: Vec<CollectedSet>,
    pub rows_affected: Option<u64>,
    pub notices: Vec<String>,
    pub stopped_at_limit: bool,
    /// A value the driver could not decode, sent as null.
    pub undecodable: bool,
}

#[derive(Debug)]
pub struct CollectedSet {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

/// Keeps at most `limit` rows of each result set.
///
/// A streamed read has no limit of its own, so with `stop_at_limit` the
/// row past the limit ends it. An editor run is limited by the driver
/// and keeps going for what it writes.
pub struct ResultCollector {
    state: Arc<Mutex<CollectedResults>>,
    limit: usize,
    stop_at_limit: bool,
}

impl ResultCollector {
    pub fn new(state: Arc<Mutex<CollectedResults>>, limit: usize, stop_at_limit: bool) -> Self {
        Self {
            state,
            limit,
            stop_at_limit,
        }
    }

    fn accept_now(&self, event: ResultEvent) -> SinkFlow {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        match event {
            ResultEvent::ResultSetStarted { columns } => state.sets.push(CollectedSet {
                columns,
                rows: Vec::new(),
                truncated: false,
            }),
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if let Some(set) = state.sets.get_mut(set_index) {
                    set.columns = columns;
                }
            }
            ResultEvent::Rows(rows) => return self.keep_rows(&mut state, rows),
            ResultEvent::RowLimitReached { .. } => {
                if let Some(set) = state.sets.last_mut() {
                    set.truncated = true;
                }
            }
            ResultEvent::ResultSetFinished { truncation, .. } => {
                if truncation != Truncation::Complete
                    && let Some(set) = state.sets.last_mut()
                {
                    set.truncated = true;
                }
            }
            ResultEvent::CommandCompleted { rows_affected } => {
                if let Some(rows) = rows_affected {
                    state.rows_affected = Some(state.rows_affected.unwrap_or(0).saturating_add(rows));
                }
            }
            ResultEvent::Notice(notice) => {
                if state.notices.len() < MAX_NOTICES {
                    state.notices.push(format!("{}: {}", notice.severity, notice.message));
                }
            }
        }
        SinkFlow::Continue
    }

    fn keep_rows(&self, state: &mut CollectedResults, rows: Vec<Vec<Value>>) -> SinkFlow {
        let mut undecodable = false;
        let limit = self.limit;
        let Some(set) = state.sets.last_mut() else {
            return SinkFlow::Continue;
        };
        for mut row in rows {
            if set.rows.len() >= limit {
                set.truncated = true;
                break;
            }
            for value in &mut row {
                if matches!(value, Value::Undecodable(_)) {
                    *value = Value::Null;
                    undecodable = true;
                }
            }
            set.rows.push(row);
        }
        let past_limit = set.truncated;
        state.undecodable |= undecodable;
        if past_limit && self.stop_at_limit {
            state.stopped_at_limit = true;
            return SinkFlow::ConsumerGone;
        }
        SinkFlow::Continue
    }
}

#[async_trait]
impl ResultSink for ResultCollector {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        self.accept_now(event)
    }
}

#[derive(Serialize)]
struct ResultsDocument<'a> {
    result_sets: Vec<SetDocument<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rows_affected: Option<u64>,
    #[serde(skip_serializing_if = "<[String]>::is_empty")]
    notices: &'a [String],
    execution_time_ms: u128,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    notes: Vec<&'static str>,
}

#[derive(Serialize)]
struct SetDocument<'a> {
    columns: Vec<ColumnDocument<'a>>,
    rows: Box<RawValue>,
    row_count: usize,
    truncated: bool,
}

#[derive(Serialize)]
struct ColumnDocument<'a> {
    name: &'a str,
    #[serde(rename = "type")]
    type_name: &'a str,
}

impl CollectedResults {
    /// The answer as JSON text. Rows go out through the JSON export's
    /// encoder, so a number keeps the digits the server sent.
    pub fn to_json(&self, elapsed: Duration, extra_notes: &[&'static str]) -> Result<String, ToolError> {
        let mut sets = Vec::with_capacity(self.sets.len());
        for set in &self.sets {
            let rows = tablepro_core::export::render_json(&set.columns, &set.rows)
                .map_err(|error| ToolError::Internal(error.to_string()))?;
            let rows = RawValue::from_string(rows).map_err(|error| ToolError::Internal(error.to_string()))?;
            sets.push(SetDocument {
                columns: set
                    .columns
                    .iter()
                    .map(|column| ColumnDocument {
                        name: &column.name,
                        type_name: &column.column_type.name,
                    })
                    .collect(),
                rows,
                row_count: set.rows.len(),
                truncated: set.truncated,
            });
        }
        let mut notes = extra_notes.to_vec();
        if self.undecodable {
            notes.push("Some values could not be decoded by TablePro and are shown as null.");
        }
        if self.sets.iter().any(|set| set.truncated) {
            notes.push(
                "A result set has more rows than the limit; ask for fewer with a WHERE clause or raise max_rows.",
            );
        }
        let document = ResultsDocument {
            result_sets: sets,
            rows_affected: self.rows_affected,
            notices: &self.notices,
            execution_time_ms: elapsed.as_millis(),
            notes,
        };
        serde_json::to_string(&document).map_err(|error| ToolError::Internal(error.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnType;

    use super::*;

    fn columns() -> Arc<[ResultColumn]> {
        vec![ResultColumn::new("n", ColumnType::untyped_text("bigint"))].into()
    }

    fn rows(count: i64) -> Vec<Vec<Value>> {
        (0..count).map(|n| vec![Value::Int(n)]).collect()
    }

    #[tokio::test]
    async fn a_streamed_read_stops_at_the_row_past_the_limit() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), 3, true);

        sink.accept(ResultEvent::ResultSetStarted { columns: columns() }).await;
        let first = sink.accept(ResultEvent::Rows(rows(2))).await;
        let second = sink.accept(ResultEvent::Rows(rows(2))).await;

        assert_eq!(first, SinkFlow::Continue);
        assert_eq!(second, SinkFlow::ConsumerGone);
        let state = state.lock().unwrap();
        assert!(state.stopped_at_limit);
        assert_eq!(state.sets[0].rows.len(), 3);
        assert!(state.sets[0].truncated);
    }

    #[tokio::test]
    async fn a_run_keeps_going_past_the_limit_for_what_it_writes() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), 1, false);

        sink.accept(ResultEvent::ResultSetStarted { columns: columns() }).await;
        let flow = sink.accept(ResultEvent::Rows(rows(5))).await;
        sink.accept(ResultEvent::CommandCompleted { rows_affected: Some(2) })
            .await;
        sink.accept(ResultEvent::CommandCompleted { rows_affected: Some(3) })
            .await;

        assert_eq!(flow, SinkFlow::Continue);
        let state = state.lock().unwrap();
        assert!(!state.stopped_at_limit);
        assert_eq!(state.rows_affected, Some(5));
    }

    #[tokio::test]
    async fn the_answer_keeps_exact_digits_and_column_order() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), 10, true);
        let columns: Arc<[ResultColumn]> = vec![
            ResultColumn::new("z", ColumnType::untyped_text("bigint")),
            ResultColumn::new("a", ColumnType::untyped_text("text")),
        ]
        .into();
        sink.accept(ResultEvent::ResultSetStarted { columns }).await;
        sink.accept(ResultEvent::Rows(vec![vec![
            Value::UInt(18_446_744_073_709_551_615),
            Value::Text("x".to_owned()),
        ]]))
        .await;

        let json = state
            .lock()
            .unwrap()
            .to_json(Duration::from_millis(7), &[])
            .expect("JSON");

        assert!(json.contains(r#"{"z":18446744073709551615,"a":"x"}"#), "{json}");
        assert!(json.contains(r#""execution_time_ms":7"#), "{json}");
        assert!(!json.contains("rows_affected"), "{json}");
    }
}
