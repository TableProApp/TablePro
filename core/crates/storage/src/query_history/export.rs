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
    // The history export has no option of its own, so it keeps neutralising rather than follow the export default.
    let options = tablepro_core::export::CsvOptions {
        sanitize_formulas: true,
        ..tablepro_core::export::CsvOptions::default()
    };
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
        entry.duration_us.map(millis_text).unwrap_or_default(),
        entry.rows_affected.map(|n| n.to_string()).unwrap_or_default(),
        flag(entry.success),
        flag(entry.cancelled),
        flag(entry.pinned),
        entry.query.clone(),
        entry.error.clone().unwrap_or_default(),
    ]
}

// The export's `duration_ms` column keeps its unit, with the fraction a run under a millisecond needs.
fn millis_text(micros: i64) -> String {
    let sign = if micros < 0 { "-" } else { "" };
    let micros = micros.unsigned_abs();
    let (whole, fraction) = (micros / 1_000, micros % 1_000);
    if fraction == 0 {
        return format!("{sign}{whole}");
    }
    let digits = format!("{fraction:03}");
    format!("{sign}{whole}.{}", digits.trim_end_matches('0'))
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
        match (entry.rows_affected, entry.duration_us) {
            (Some(rows), Some(micros)) => format!("ok · {rows} row(s) · {} ms", millis_text(micros)),
            (Some(rows), None) => format!("ok · {rows} row(s)"),
            (None, Some(micros)) => format!("ok · {} ms", millis_text(micros)),
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

    use super::super::RunDetails;
    use super::*;

    fn failed(connection_name: &str, error: &str) -> Entry {
        Entry {
            id: 1,
            record_id: Uuid::nil(),
            query: "SELECT 1".to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: Uuid::nil(),
            connection_name: connection_name.to_owned(),
            executed_at: SystemTime::UNIX_EPOCH,
            duration_us: Some(3),
            rows_affected: None,
            success: false,
            cancelled: false,
            pinned: false,
            error: Some(error.to_owned()),
            details: RunDetails::default(),
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

    #[test]
    fn a_run_under_a_millisecond_exports_its_fraction_in_milliseconds() {
        let mut quick = failed("local", "");
        quick.success = true;
        quick.error = None;
        quick.duration_us = Some(90);
        let mut slow = quick.clone();
        slow.duration_us = Some(12_000);
        slow.rows_affected = Some(2);

        let csv = history_csv(&[quick.clone(), slow]).expect("csv");
        let script = history_sql(&[quick], chrono::DateTime::UNIX_EPOCH);

        let durations: Vec<&str> = csv.lines().skip(1).filter_map(|line| line.split(',').nth(3)).collect();
        assert_eq!(durations, ["0.09", "12"], "{csv}");
        assert!(script.contains(" · ok · 0.09 ms\n"), "{script}");
        assert_eq!(millis_text(1_250), "1.25");
    }
}
