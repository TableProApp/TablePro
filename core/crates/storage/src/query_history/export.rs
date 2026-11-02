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

/// The entries as a script: each query as it ran, under `--` comments
/// that say where and how.
pub(super) fn history_sql(entries: &[Entry], generated_at: chrono::DateTime<chrono::Utc>) -> String {
    let mut out = String::new();
    out.push_str("-- TablePro query history export\n");
    out.push_str(&format!("-- Generated at {}\n", generated_at.to_rfc3339()));
    out.push_str(&format!("-- Entries: {}\n\n", entries.len()));
    for entry in entries {
        let when = chrono::DateTime::<chrono::Utc>::from(entry.executed_at).to_rfc3339();
        out.push_str(&format!(
            "-- [{}] {} · {} · {}\n",
            when,
            comment_line(&entry.connection_name),
            comment_line(&entry.driver_id),
            outcome_summary(entry),
        ));
        if let Some(err) = &entry.error {
            for line in comment_lines(err) {
                out.push_str("-- error: ");
                out.push_str(line);
                out.push('\n');
            }
        }
        out.push_str(entry.query.trim_end());
        if !entry.query.trim_end().ends_with(';') {
            out.push(';');
        }
        out.push_str("\n\n");
    }
    out
}

/// A `--` comment ends at a carriage return as well as a line feed in
/// PostgreSQL, so text that holds either would run what follows it.
const LINE_ENDS: [char; 2] = ['\r', '\n'];

fn comment_line(text: &str) -> String {
    text.replace(LINE_ENDS, " ")
}

fn comment_lines(text: &str) -> impl Iterator<Item = &str> {
    text.split(LINE_ENDS).filter(|line| !line.is_empty())
}

fn outcome_summary(entry: &Entry) -> String {
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

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use uuid::Uuid;

    use super::*;

    fn failed(connection_name: &str, error: &str) -> Entry {
        Entry {
            id: 1,
            query: "SELECT 1".to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: Uuid::nil(),
            connection_name: connection_name.to_owned(),
            executed_at: SystemTime::UNIX_EPOCH,
            duration_ms: Some(3),
            rows_affected: None,
            success: false,
            cancelled: false,
            pinned: false,
            error: Some(error.to_owned()),
        }
    }

    /// Every line PostgreSQL would read, ending at either break, is a
    /// comment or the query itself.
    #[test]
    fn a_line_break_in_a_name_or_an_error_stays_inside_its_comment() {
        let entry = failed(
            "prod\rDROP TABLE users;\nDROP TABLE orders;",
            "denied\rDROP TABLE users;\r\nhint: ask\n",
        );

        let script = history_sql(&[entry], chrono::DateTime::UNIX_EPOCH);

        let code: Vec<&str> = script
            .split(LINE_ENDS)
            .filter(|line| !line.is_empty() && !line.starts_with("--"))
            .collect();
        assert_eq!(code, ["SELECT 1;"], "{script}");
        assert!(
            script.contains(
                "-- [1970-01-01T00:00:00+00:00] prod DROP TABLE users; DROP TABLE orders; · postgres · error\n"
            ),
            "{script}"
        );
        assert!(
            script.contains("-- error: denied\n-- error: DROP TABLE users;\n-- error: hint: ask\n"),
            "{script}"
        );
    }
}
