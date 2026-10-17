//! What a crash leaves behind for the user to send, and how the next
//! launch finds it.

use std::backtrace::Backtrace;
use std::panic::PanicHookInfo;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use tablepro_storage::StorageError;

use crate::config;

/// GTK calls the app back through C, which a panic cannot unwind, so a
/// panic on the GTK thread ends the process. A panic on a runtime thread
/// is caught there and shown as a failed task, so only these are
/// crashes.
const GTK_THREAD: &str = "main";

const REPORT_PREFIX: &str = "crash-";
const REPORT_SUFFIX: &str = ".txt";
/// Holds the name of the newest report the user was told about.
const ANNOUNCED: &str = "announced";
/// A launch that crashes every time leaves one report each, so the
/// oldest go once there are more than this.
const KEPT_REPORTS: usize = 20;

/// Keep the default hook, which writes the panic to stderr and so to
/// the journal, and also write it with a backtrace to a file of its own
/// in `dir`. A GTK callback that panics panics a second time when it
/// cannot unwind, and that goes in the same file.
pub fn install(dir: PathBuf) {
    let report = OnceLock::new();
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        default_hook(info);
        if std::thread::current().name() != Some(GTK_THREAD) {
            return;
        }
        let path = report.get_or_init(|| dir.join(report_name(chrono::Utc::now(), std::process::id())));
        let text = report_text(info, &Backtrace::force_capture(), chrono::Utc::now());
        if let Err(error) = tablepro_storage::fs::append_private_blocking(path, text.as_bytes()) {
            tracing::error!(%error, "could not save the crash report");
        }
    }));
}

/// Names sort by time, so the newest report is the last name.
fn report_name(now: chrono::DateTime<chrono::Utc>, pid: u32) -> String {
    format!("{REPORT_PREFIX}{}-{pid}{REPORT_SUFFIX}", now.format("%Y%m%dT%H%M%SZ"))
}

fn report_text(info: &PanicHookInfo<'_>, backtrace: &Backtrace, now: chrono::DateTime<chrono::Utc>) -> String {
    let message = info.payload_as_str().unwrap_or("(no message)");
    let location = info
        .location()
        .map_or_else(|| "an unknown place".to_owned(), ToString::to_string);
    let build = if cfg!(debug_assertions) { "debug" } else { "release" };
    format!(
        "TablePro {version}\n\
         Application ID: {app_id}\n\
         Profile: {profile}\n\
         Build: {build}\n\
         Time: {time}\n\
         \n\
         Panicked at {location}:\n\
         {message}\n\
         \n\
         Backtrace:\n\
         {backtrace}\n\n",
        version = config::VERSION,
        app_id = config::APP_ID,
        profile = config::PROFILE,
        time = now.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    )
}

/// The newest report the user has not been told about, marked as told.
/// Runs at startup, before this run could have written one, and drops
/// the oldest reports past `KEPT_REPORTS`.
pub fn take_unannounced(dir: &Path) -> Result<Option<PathBuf>, StorageError> {
    let mut reports = match std::fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(Result::ok)
            .filter_map(|entry| entry.file_name().into_string().ok())
            .filter(|name| name.starts_with(REPORT_PREFIX) && name.ends_with(REPORT_SUFFIX))
            .collect::<Vec<_>>(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(source) => {
            return Err(StorageError::Io {
                path: dir.to_owned(),
                source,
            });
        }
    };
    reports.sort_unstable();
    let surplus = reports.len().saturating_sub(KEPT_REPORTS);
    for name in reports.drain(..surplus) {
        if let Err(error) = std::fs::remove_file(dir.join(&name)) {
            tracing::warn!(%error, "could not remove an old crash report");
        }
    }
    let Some(newest) = reports.pop() else {
        return Ok(None);
    };
    let marker = dir.join(ANNOUNCED);
    let announced = std::fs::read_to_string(&marker).unwrap_or_default();
    if announced.trim() >= newest.as_str() {
        return Ok(None);
    }
    tablepro_storage::fs::write_private_blocking(&marker, newest.as_bytes())?;
    Ok(Some(dir.join(newest)))
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    fn report(dir: &Path, name: &str) {
        tablepro_storage::fs::append_private_blocking(&dir.join(name), b"a report").expect("a report");
    }

    #[test]
    fn report_names_sort_by_time() {
        let earlier = chrono::Utc
            .with_ymd_and_hms(2026, 9, 30, 23, 59, 59)
            .single()
            .expect("a time");
        let later = chrono::Utc
            .with_ymd_and_hms(2026, 10, 1, 0, 0, 0)
            .single()
            .expect("a time");

        assert_eq!(report_name(later, 42), "crash-20261001T000000Z-42.txt");
        assert!(report_name(earlier, 99_999) < report_name(later, 1));
    }

    #[test]
    fn the_newest_report_is_announced_once() {
        let dir = tempfile::tempdir().expect("a directory");
        report(dir.path(), "crash-20261001T000000Z-1.txt");
        report(dir.path(), "crash-20261002T000000Z-2.txt");

        let first = take_unannounced(dir.path()).expect("a listing");

        assert_eq!(first, Some(dir.path().join("crash-20261002T000000Z-2.txt")));
        assert_eq!(take_unannounced(dir.path()).expect("a listing"), None);

        report(dir.path(), "crash-20261003T000000Z-3.txt");
        assert_eq!(
            take_unannounced(dir.path()).expect("a listing"),
            Some(dir.path().join("crash-20261003T000000Z-3.txt"))
        );
    }

    #[test]
    fn no_directory_is_no_report() {
        let dir = tempfile::tempdir().expect("a directory");

        assert_eq!(take_unannounced(&dir.path().join("crashes")).expect("a listing"), None);
    }

    #[test]
    fn only_the_newest_reports_are_kept() {
        let dir = tempfile::tempdir().expect("a directory");
        for day in 1..=KEPT_REPORTS + 3 {
            report(dir.path(), &format!("crash-202610{day:02}T000000Z-1.txt"));
        }

        take_unannounced(dir.path()).expect("a listing");

        let left = std::fs::read_dir(dir.path())
            .expect("a listing")
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().starts_with(REPORT_PREFIX))
            .count();
        assert_eq!(left, KEPT_REPORTS);
        assert!(!dir.path().join("crash-20261001T000000Z-1.txt").exists());
        assert!(
            dir.path()
                .join(format!("crash-202610{:02}T000000Z-1.txt", KEPT_REPORTS + 3))
                .exists()
        );
    }
}
