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

/// Result sets kept from one run. A SQL Server batch that selects in a
/// loop sends one per pass, each under the row limit.
const MAX_RESULT_SETS: usize = 20;

// The app holds the kept rows and their JSON at once, and a client's context takes far less.
pub const MAX_ANSWER_BYTES: usize = 4 * 1024 * 1024;

pub const MAX_VALUE_BYTES: usize = 64 * 1024;

const VALUES_CUT_NOTE: &str = "Some values were longer than 64 KB and were cut there; each one cut ends in a mark \
with its full length. Read such a value in parts with a narrower query.";

const SIZE_LIMIT_NOTE: &str = "The rows reached TablePro's 4 MB limit for one answer, so a result set marked \
truncated holds only the rows that fit; ask for fewer columns or rows.";

// Every value `encoded_len` does not measure renders to fewer bytes than this.
const SCALAR_BYTES: usize = 40;

// A cell's quotes, colon and comma, and a row's braces and comma.
const CELL_BYTES: usize = 6;
const ROW_BYTES: usize = 3;

#[derive(Debug, Default)]
pub struct CollectedResults {
    pub sets: Vec<CollectedSet>,
    pub rows_affected: Option<u64>,
    pub notices: Vec<String>,
    pub stopped_at_limit: bool,
    /// A value the driver could not decode, sent as null.
    pub undecodable: bool,
    /// The run sent more result sets than are kept; every one after the
    /// last kept is left out.
    pub sets_left_out: bool,
    // What the kept rows render to, as `encoded_len` counts it.
    pub bytes: usize,
    pub values_cut: bool,
    pub size_limited: bool,
}

#[derive(Debug)]
pub struct CollectedSet {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
    // The answer's size limit, not the row limit, ended the set.
    pub size_limited: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LongValues {
    Cut,
    // An export is data to keep exactly, so a row that does not fit is left out instead.
    Whole,
}

// `rows` is per result set, `bytes` for every set of the answer together.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Keep {
    pub rows: usize,
    pub bytes: usize,
    pub long_values: LongValues,
}

impl Keep {
    pub fn results(rows: usize) -> Self {
        Self {
            rows,
            bytes: MAX_ANSWER_BYTES,
            long_values: LongValues::Cut,
        }
    }

    pub fn export(rows: usize, bytes: usize) -> Self {
        Self {
            rows,
            bytes,
            long_values: LongValues::Whole,
        }
    }
}

// A streamed read has no limit of its own, so with `stop_at_limit` the first row it cannot keep ends it. An editor
// run keeps going for what it writes.
pub struct ResultCollector {
    state: Arc<Mutex<CollectedResults>>,
    keep: Keep,
    stop_at_limit: bool,
}

impl ResultCollector {
    pub fn new(state: Arc<Mutex<CollectedResults>>, keep: Keep, stop_at_limit: bool) -> Self {
        Self {
            state,
            keep,
            stop_at_limit,
        }
    }

    fn accept_now(&self, event: ResultEvent) -> SinkFlow {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        match event {
            ResultEvent::ResultSetStarted { columns } => {
                if state.sets.len() >= MAX_RESULT_SETS {
                    state.sets_left_out = true;
                    if self.stop_at_limit {
                        state.stopped_at_limit = true;
                        return SinkFlow::ConsumerGone;
                    }
                } else {
                    state.sets.push(CollectedSet {
                        columns,
                        rows: Vec::new(),
                        truncated: false,
                        size_limited: false,
                    });
                }
            }
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if let Some(set) = state.sets.get_mut(set_index) {
                    set.columns = columns;
                }
            }
            ResultEvent::Rows(_) if state.sets_left_out => {}
            ResultEvent::Rows(rows) => return self.keep_rows(&mut state, rows),
            ResultEvent::RowLimitReached { .. } | ResultEvent::ByteLimitReached { .. } => {
                if !state.sets_left_out
                    && let Some(set) = state.sets.last_mut()
                {
                    set.truncated = true;
                }
            }
            ResultEvent::ResultSetFinished { truncation, .. } => {
                if truncation != Truncation::Complete
                    && !state.sets_left_out
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
                    let message = match notice.message.len() > MAX_VALUE_BYTES {
                        true => cut_text(&notice.message, notice.message.len()),
                        false => notice.message,
                    };
                    state.notices.push(format!("{}: {message}", notice.severity));
                }
            }
            // The answer keeps far fewer notices than a run does.
            ResultEvent::NoticeLimitReached { .. } => {}
        }
        SinkFlow::Continue
    }

    fn keep_rows(&self, state: &mut CollectedResults, rows: Vec<Vec<Value>>) -> SinkFlow {
        let Some(set) = state.sets.last_mut() else {
            return SinkFlow::Continue;
        };
        for mut row in rows {
            // A set keeps a prefix of its rows, so once one is left out none after it is kept.
            if set.truncated {
                break;
            }
            if set.rows.len() >= self.keep.rows {
                set.truncated = true;
                break;
            }
            let (mut undecodable, mut cut) = (false, false);
            let mut size = ROW_BYTES;
            for (index, value) in row.iter_mut().enumerate() {
                if matches!(value, Value::Undecodable(_)) {
                    *value = Value::Null;
                    undecodable = true;
                }
                if self.keep.long_values == LongValues::Cut
                    && let Some(shortened) = cut_value(value)
                {
                    *value = shortened;
                    cut = true;
                }
                let name = set.columns.get(index).map_or(0, |column| column.name.len());
                size = size
                    .saturating_add(name + CELL_BYTES)
                    .saturating_add(encoded_len(value));
            }
            if state.size_limited || state.bytes.saturating_add(size) > self.keep.bytes {
                set.truncated = true;
                set.size_limited = true;
                state.size_limited = true;
                break;
            }
            state.bytes += size;
            state.undecodable |= undecodable;
            state.values_cut |= cut;
            set.rows.push(row);
        }
        if set.truncated && self.stop_at_limit {
            state.stopped_at_limit = true;
            return SinkFlow::ConsumerGone;
        }
        SinkFlow::Continue
    }
}

// Measured without rendering, since rendering a value is what the limit is there to avoid.
fn encoded_len(value: &Value) -> usize {
    match value {
        Value::Text(text) => text.len(),
        // `0x` and two hex digits a byte.
        Value::Bytes(bytes) => bytes.len().saturating_mul(2).saturating_add(2),
        Value::Json(json) => json.as_str().len(),
        Value::Other(other) => other.text.len(),
        Value::Bits(bits) => usize::try_from(bits.bit_len()).unwrap_or(usize::MAX),
        Value::Array(values) => values
            .iter()
            .fold(2, |sum, item| sum.saturating_add(encoded_len(item)).saturating_add(1)),
        _ => SCALAR_BYTES,
    }
}

// A JSON document or an array cut short is no longer one, so every cut value goes out as text.
fn cut_value(value: &Value) -> Option<Value> {
    if encoded_len(value) <= MAX_VALUE_BYTES {
        return None;
    }
    let cut = match value {
        Value::Text(text) => cut_text(text, text.len()),
        Value::Json(json) => cut_text(json.as_str(), json.as_str().len()),
        Value::Other(other) => cut_text(&other.text, other.text.len()),
        Value::Bytes(bytes) => {
            let head = bytes.get(..MAX_VALUE_BYTES / 2).unwrap_or(bytes);
            let text = tablepro_core::export::value_to_text(&Value::Bytes(head.to_vec())).unwrap_or_default();
            format!("{text}{}", cut_mark(bytes.len()))
        }
        other => {
            let text = tablepro_core::export::value_to_text(other).unwrap_or_default();
            cut_text(&text, text.len())
        }
    };
    Some(Value::Text(cut))
}

fn cut_text(text: &str, total: usize) -> String {
    let head = text
        .get(..text.floor_char_boundary(MAX_VALUE_BYTES))
        .unwrap_or_default();
    format!("{head}{}", cut_mark(total))
}

fn cut_mark(total: usize) -> String {
    format!(" [TablePro cut this value: {total} bytes in all]")
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
        if self.sets_left_out {
            notes.push("The statement sent more than 20 result sets; only the first 20 are here.");
        }
        if self.values_cut {
            notes.push(VALUES_CUT_NOTE);
        }
        if self.size_limited {
            notes.push(SIZE_LIMIT_NOTE);
        }
        if self.sets.iter().any(|set| set.truncated && !set.size_limited) {
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
    use tablepro_core::ServerNotice;
    use tablepro_core::column::ColumnType;

    use super::*;

    fn columns() -> Arc<[ResultColumn]> {
        vec![ResultColumn::new("n", ColumnType::untyped_text("bigint"))].into()
    }

    fn rows(count: i64) -> Vec<Vec<Value>> {
        (0..count).map(|n| vec![Value::Int(n)]).collect()
    }

    fn text_columns(names: &[&str]) -> Arc<[ResultColumn]> {
        names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect()
    }

    fn long_text(bytes: usize) -> Value {
        Value::Text("x".repeat(bytes))
    }

    #[tokio::test]
    async fn a_streamed_read_stops_at_the_row_past_the_limit() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(3), true);

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
        let mut sink = ResultCollector::new(state.clone(), Keep::results(1), false);

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
    async fn result_sets_past_the_cap_are_left_out_and_end_a_streamed_read() {
        for stop_at_limit in [true, false] {
            let state = Arc::new(Mutex::new(CollectedResults::default()));
            let mut sink = ResultCollector::new(state.clone(), Keep::results(5), stop_at_limit);
            let mut flows = Vec::new();

            for _ in 0..=MAX_RESULT_SETS {
                flows.push(sink.accept(ResultEvent::ResultSetStarted { columns: columns() }).await);
                sink.accept(ResultEvent::Rows(rows(1))).await;
                sink.accept(ResultEvent::RowLimitReached { retained: 1 }).await;
            }

            let state = state.lock().unwrap();
            assert_eq!(state.sets.len(), MAX_RESULT_SETS);
            assert!(state.sets_left_out);
            assert!(state.sets.iter().all(|set| set.rows.len() == 1));
            let expected = match stop_at_limit {
                true => SinkFlow::ConsumerGone,
                false => SinkFlow::Continue,
            };
            assert_eq!(flows.last(), Some(&expected));
            let json = state.to_json(Duration::ZERO, &[]).expect("JSON");
            assert!(json.contains("more than 20 result sets"), "{json}");
        }
    }

    #[tokio::test]
    async fn the_answer_keeps_exact_digits_and_column_order() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(10), true);
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

    #[tokio::test]
    async fn a_value_past_the_cap_goes_out_cut_with_its_length() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(10), true);
        // A two-byte character across the cap, so the cut has to fall before it.
        let text = format!("{}é{}", "x".repeat(MAX_VALUE_BYTES - 1), "y".repeat(10));
        sink.accept(ResultEvent::ResultSetStarted {
            columns: text_columns(&["text", "bytes", "short"]),
        })
        .await;

        let flow = sink
            .accept(ResultEvent::Rows(vec![vec![
                Value::Text(text.clone()),
                Value::Bytes(vec![0xab; MAX_VALUE_BYTES]),
                Value::Text("kept".to_owned()),
            ]]))
            .await;

        assert_eq!(flow, SinkFlow::Continue);
        let state = state.lock().unwrap();
        let row = &state.sets[0].rows[0];
        let expected = format!("{}{}", "x".repeat(MAX_VALUE_BYTES - 1), cut_mark(text.len()));
        assert_eq!(row[0], Value::Text(expected));
        let Value::Text(hex) = &row[1] else {
            panic!("the bytes were not cut to text: {:?}", row[1]);
        };
        assert!(hex.starts_with("0xabab"), "{}", &hex[..10]);
        assert!(hex.ends_with(&cut_mark(MAX_VALUE_BYTES)), "{}", &hex[hex.len() - 60..]);
        assert_eq!(hex.len(), 2 + MAX_VALUE_BYTES + cut_mark(MAX_VALUE_BYTES).len());
        assert_eq!(row[2], Value::Text("kept".to_owned()));
        assert!(state.values_cut);
        assert!(!state.sets[0].truncated);
        let json = state.to_json(Duration::ZERO, &[]).expect("JSON");
        assert!(
            json.contains(VALUES_CUT_NOTE),
            "the answer does not say values were cut"
        );
    }

    #[tokio::test]
    async fn rows_stop_at_the_answers_size_and_end_a_streamed_read() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(1_000), true);
        sink.accept(ResultEvent::ResultSetStarted {
            columns: text_columns(&["b"]),
        })
        .await;

        let flow = sink
            .accept(ResultEvent::Rows(
                (0..100).map(|_| vec![long_text(MAX_VALUE_BYTES)]).collect(),
            ))
            .await;

        assert_eq!(flow, SinkFlow::ConsumerGone);
        let state = state.lock().unwrap();
        let per_row = ROW_BYTES + "b".len() + CELL_BYTES + MAX_VALUE_BYTES;
        assert_eq!(state.sets[0].rows.len(), MAX_ANSWER_BYTES / per_row);
        assert!(state.stopped_at_limit);
        assert!(state.size_limited && state.sets[0].truncated && state.sets[0].size_limited);
        assert!(!state.values_cut, "a value at the cap was cut");
        let json = state.to_json(Duration::ZERO, &[]).expect("JSON");
        assert!(json.len() < MAX_ANSWER_BYTES, "{} bytes", json.len());
        assert!(
            json.contains(SIZE_LIMIT_NOTE),
            "the answer does not say it reached its size"
        );
        assert!(!json.contains("raise max_rows"), "the row limit is blamed for the size");
    }

    #[tokio::test]
    async fn a_write_runs_on_past_the_answers_size_and_keeps_no_row_after_it() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(1_000), false);
        sink.accept(ResultEvent::ResultSetStarted {
            columns: text_columns(&["b"]),
        })
        .await;

        let first = sink
            .accept(ResultEvent::Rows(
                (0..100).map(|_| vec![long_text(MAX_VALUE_BYTES)]).collect(),
            ))
            .await;
        let second = sink
            .accept(ResultEvent::Rows(vec![vec![Value::Text("small".to_owned())]]))
            .await;
        sink.accept(ResultEvent::CommandCompleted {
            rows_affected: Some(100),
        })
        .await;

        assert_eq!((first, second), (SinkFlow::Continue, SinkFlow::Continue));
        let state = state.lock().unwrap();
        assert!(!state.stopped_at_limit);
        assert!(state.size_limited);
        assert!(
            state.sets[0]
                .rows
                .iter()
                .all(|row| row[0] != Value::Text("small".to_owned())),
            "a row after one left out was kept"
        );
        assert_eq!(state.rows_affected, Some(100));
    }

    #[tokio::test]
    async fn an_export_keeps_values_whole_and_leaves_out_a_row_that_does_not_fit() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::export(10, 2 * MAX_VALUE_BYTES), true);
        sink.accept(ResultEvent::ResultSetStarted {
            columns: text_columns(&["b"]),
        })
        .await;

        let flow = sink
            .accept(ResultEvent::Rows(vec![
                vec![long_text(MAX_VALUE_BYTES + 1)],
                vec![long_text(MAX_VALUE_BYTES + 1)],
                vec![Value::Text("small".to_owned())],
            ]))
            .await;

        assert_eq!(flow, SinkFlow::ConsumerGone);
        let state = state.lock().unwrap();
        assert_eq!(state.sets[0].rows, vec![vec![long_text(MAX_VALUE_BYTES + 1)]]);
        assert!(!state.values_cut);
        assert!(state.size_limited && state.sets[0].truncated);
    }

    #[tokio::test]
    async fn a_long_notice_is_cut_like_a_value() {
        let state = Arc::new(Mutex::new(CollectedResults::default()));
        let mut sink = ResultCollector::new(state.clone(), Keep::results(10), true);

        sink.accept(ResultEvent::Notice(ServerNotice {
            severity: "NOTICE".to_owned(),
            message: "n".repeat(3 * MAX_VALUE_BYTES),
            code: None,
        }))
        .await;

        let state = state.lock().unwrap();
        assert_eq!(
            state.notices,
            [format!(
                "NOTICE: {}{}",
                "n".repeat(MAX_VALUE_BYTES),
                cut_mark(3 * MAX_VALUE_BYTES)
            )]
        );
    }
}
