use crate::error::StorageError;

use super::Entry;

const HISTORY_CSV_HEADER: [&str; 10] = [
    "executed_at",
    "connection",
    "driver",
    "duration_ms",
    "rows_affected",
    "success",
    "cancelled",
    "pinned",
    "query",
    "error",
];

pub(super) fn history_csv(entries: &[Entry]) -> Result<String, StorageError> {
    let records: Vec<Vec<String>> = entries.iter().map(history_record).collect();
    let options = tablepro_core::export::CsvOptions::default();
    Ok(tablepro_core::export::render_text_csv(
        &HISTORY_CSV_HEADER,
        &records,
        &options,
    )?)
}

fn history_record(entry: &Entry) -> Vec<String> {
    vec![
        chrono::DateTime::<chrono::Utc>::from(entry.executed_at).to_rfc3339(),
        entry.connection_name.clone(),
        entry.driver_id.clone(),
        entry.duration_ms.map(|n| n.to_string()).unwrap_or_default(),
        entry.rows_affected.map(|n| n.to_string()).unwrap_or_default(),
        flag(entry.success),
        flag(entry.cancelled),
        flag(entry.pinned),
        entry.query.clone(),
        entry.error.clone().unwrap_or_default(),
    ]
}

fn flag(value: bool) -> String {
    if value { "1" } else { "0" }.to_string()
}

pub(super) fn outcome_summary(entry: &Entry) -> String {
    if entry.cancelled {
        "cancelled".into()
    } else if entry.success {
        match (entry.rows_affected, entry.duration_ms) {
            (Some(rows), Some(ms)) => format!("ok · {rows} row(s) · {ms} ms"),
            (Some(rows), None) => format!("ok · {rows} row(s)"),
            (None, Some(ms)) => format!("ok · {ms} ms"),
            (None, None) => "ok".into(),
        }
    } else {
        "error".into()
    }
}
