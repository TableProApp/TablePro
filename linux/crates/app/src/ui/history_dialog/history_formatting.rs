use std::time::SystemTime;

use tablepro_storage::query_history::Entry;

use crate::i18n::{gettext, ngettext_f};
use crate::ui::format::{format_thousands, plural_count};

const TITLE_CHARS: usize = 80;
const ERROR_CHARS: usize = 48;

/// The first line that says something, cut to fit one row.
pub(super) fn preview_title(query: &str) -> String {
    let first_line = query
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with("--"))
        .unwrap_or("");
    if first_line.is_empty() {
        return gettext("Empty query");
    }
    truncated(first_line, TITLE_CHARS)
}

pub(super) fn subtitle(entry: &Entry, now: SystemTime) -> String {
    let mut parts = vec![
        entry.connection_name.clone(),
        entry.driver_id.clone(),
        relative_time(entry.executed_at, now),
    ];
    if let Some(ms) = entry.duration_ms {
        parts.push(format!("{} ms", format_thousands(u64::try_from(ms).unwrap_or(0))));
    }
    if entry.cancelled {
        parts.push(gettext("cancelled"));
    } else if let Some(error) = &entry.error {
        parts.push(truncated(error, ERROR_CHARS));
    } else if let Some(rows) = entry.rows_affected {
        let rows = u64::try_from(rows).unwrap_or(0);
        parts.push(ngettext_f(
            "{n} row",
            "{n} rows",
            plural_count(rows),
            &[("n", &format_thousands(rows))],
        ));
    }
    parts.join(" · ")
}

/// What the status icon stands for, for a screen reader.
pub(super) fn outcome_label(entry: &Entry) -> String {
    if entry.cancelled {
        gettext("Cancelled")
    } else if entry.success {
        gettext("Succeeded")
    } else {
        gettext("Failed")
    }
}

pub(super) fn outcome_icon(entry: &Entry) -> &'static str {
    if entry.cancelled {
        crate::ui::icons::PROCESS_STOP
    } else if entry.success {
        crate::ui::icons::SUCCESS
    } else {
        crate::ui::icons::DIALOG_ERROR
    }
}

fn relative_time(when: SystemTime, now: SystemTime) -> String {
    let secs = now.duration_since(when).unwrap_or_default().as_secs();
    let count = |n: u64| (plural_count(n), n.to_string());
    if secs < 60 {
        gettext("just now")
    } else if secs < 3_600 {
        let (n, text) = count(secs / 60);
        ngettext_f("{n} minute ago", "{n} minutes ago", n, &[("n", &text)])
    } else if secs < 86_400 {
        let (n, text) = count(secs / 3_600);
        ngettext_f("{n} hour ago", "{n} hours ago", n, &[("n", &text)])
    } else if secs < 30 * 86_400 {
        let (n, text) = count(secs / 86_400);
        ngettext_f("{n} day ago", "{n} days ago", n, &[("n", &text)])
    } else {
        chrono::DateTime::<chrono::Local>::from(when)
            .format("%Y-%m-%d")
            .to_string()
    }
}

fn truncated(text: &str, limit: usize) -> String {
    let mut chars = text.chars();
    let kept: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{kept}…")
    } else {
        kept
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use uuid::Uuid;

    use super::*;

    fn entry(executed_at: SystemTime) -> Entry {
        Entry {
            id: 1,
            query: "SELECT 1".to_owned(),
            driver_id: "postgres".to_owned(),
            connection_id: Uuid::nil(),
            connection_name: "local".to_owned(),
            executed_at,
            duration_ms: Some(12),
            rows_affected: Some(2),
            success: true,
            cancelled: false,
            pinned: false,
            error: None,
        }
    }

    #[test]
    fn the_title_skips_blank_and_comment_lines() {
        assert_eq!(preview_title("\n-- yesterday\n  SELECT 1\nFROM t"), "SELECT 1");
    }

    #[test]
    fn a_long_title_is_cut_on_a_character_boundary() {
        let title = preview_title(&"é".repeat(100));

        assert_eq!(title.chars().count(), TITLE_CHARS + 1);
        assert!(title.ends_with('…'));
    }

    #[test]
    fn a_query_of_only_comments_is_called_empty() {
        assert_eq!(preview_title("-- nothing\n\n"), "Empty query");
    }

    #[test]
    fn the_subtitle_names_where_when_and_what_came_back() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);

        let text = subtitle(&entry(now - Duration::from_secs(120)), now);

        assert_eq!(text, "local · postgres · 2 minutes ago · 12 ms · 2 rows");
    }

    #[test]
    fn a_failed_run_shows_its_error_cut_short() {
        let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_800_000_000);
        let mut failed = entry(now);
        failed.success = false;
        failed.error = Some("x".repeat(60));

        let text = subtitle(&failed, now);

        assert!(text.ends_with(&format!("{}…", "x".repeat(ERROR_CHARS))), "{text}");
        assert_eq!(outcome_icon(&failed), crate::ui::icons::DIALOG_ERROR);
        assert_eq!(outcome_label(&failed), "Failed");
    }
}
