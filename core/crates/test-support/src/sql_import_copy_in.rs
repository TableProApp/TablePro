use std::io::{Cursor, Read};
use std::sync::Arc;
use std::time::Duration;

use tablepro_core::import::{
    SqlImportEnd, SqlImportErrorPolicy, SqlImportFault, SqlImportOptions, SqlImportReport, run_sql_import,
};
use tablepro_core::{DriverError, UserSql};
use tokio_util::sync::CancellationToken;

use crate::{FakeDialect, FakeEditorSession, FakeRun, Replies};

fn options(on_error: SqlImportErrorPolicy) -> SqlImportOptions {
    SqlImportOptions {
        on_error,
        one_transaction: false,
    }
}

async fn import(session: &FakeEditorSession, file: &str, on_error: SqlImportErrorPolicy) -> SqlImportReport {
    run_sql_import(
        session,
        &FakeDialect,
        Box::new(Cursor::new(file.as_bytes().to_vec())),
        options(on_error),
        &mut |_| {},
        &CancellationToken::new(),
    )
    .await
}

fn texts(session: &FakeEditorSession) -> Vec<String> {
    session.texts().iter().map(|text| text.as_str().to_owned()).collect()
}

fn refusing_copies() -> FakeEditorSession {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "COPY",
        FakeRun::failed(DriverError::Protocol("relation \"t\" does not exist".to_owned())),
    )
    .always(FakeRun::completed(Vec::new()));
    FakeEditorSession::new(runs)
}

#[tokio::test]
async fn copy_rows_reach_the_session_byte_exact_as_one_statement() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    let session = FakeEditorSession::new(runs);

    let report = import(
        &session,
        "CREATE TABLE t (a int, b text);\nCOPY t (a, b) FROM stdin;\n1\tone\r\n2\t\\N\n\\.\r\nSELECT 1;\n",
        SqlImportErrorPolicy::Stop,
    )
    .await;

    assert_eq!(report.end, SqlImportEnd::Completed, "{report:?}");
    assert_eq!((report.statements, report.failed), (3, 0));
    let copies = session.copies();
    assert_eq!(copies.len(), 1);
    assert_eq!(copies[0].statement, UserSql::new("COPY t (a, b) FROM stdin"));
    assert_eq!(copies[0].data, b"1\tone\r\n2\t\\N\n");
    assert!(copies[0].ended);
    assert_eq!(
        texts(&session)[1..],
        ["CREATE TABLE t (a int, b text)", "COPY t (a, b) FROM stdin", "SELECT 1"]
    );
}

#[tokio::test]
async fn a_refused_copy_under_continue_passes_over_its_rows_and_goes_on() {
    let session = refusing_copies();

    let report = import(
        &session,
        "COPY t FROM stdin;\n1\n2\n\\.\nSELECT 2;\n",
        SqlImportErrorPolicy::Continue,
    )
    .await;

    assert_eq!(report.end, SqlImportEnd::Completed, "{report:?}");
    assert_eq!((report.statements, report.failed), (1, 1));
    assert_eq!(report.failures[0].line, 1);
    assert_eq!(report.failures[0].statement, "COPY t FROM stdin");
    assert!(matches!(report.failures[0].fault, SqlImportFault::Statement(_)));
    assert_eq!(texts(&session).last().map(String::as_str), Some("SELECT 2"));
}

/// The session holds on to the rows until the server refuses, so two
/// pieces fill the queue and the refusal lands on their end.
#[tokio::test]
async fn a_copy_refused_after_its_end_was_queued_keeps_the_statement_after_it() {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "COPY",
        FakeRun::failed(DriverError::Protocol("relation \"t\" does not exist".to_owned()))
            .taking(Duration::from_millis(200)),
    )
    .always(FakeRun::completed(Vec::new()));
    let session = FakeEditorSession::new(runs);
    let rows: String = (0..60_000).map(|n| format!("{n}\n")).collect();
    assert!(
        (256 * 1024..512 * 1024).contains(&rows.len()),
        "{} bytes is not two pieces",
        rows.len()
    );

    let report = import(
        &session,
        &format!("COPY t FROM stdin;\n{rows}\\.\nSELECT 2;\n"),
        SqlImportErrorPolicy::Continue,
    )
    .await;

    assert_eq!(report.end, SqlImportEnd::Completed, "{report:?}");
    assert_eq!((report.statements, report.failed), (1, 1));
    assert_eq!(texts(&session).last().map(String::as_str), Some("SELECT 2"));
}

/// More pieces than the queue holds, so the refusal leaves rows in the
/// file for the import to pass over.
#[tokio::test]
async fn a_copy_refused_with_rows_left_passes_over_them_to_the_statement_after() {
    let mut runs = Replies::default();
    runs.when_sql_contains(
        "COPY",
        FakeRun::failed(DriverError::Protocol("relation \"t\" does not exist".to_owned()))
            .taking(Duration::from_millis(200)),
    )
    .always(FakeRun::completed(Vec::new()));
    let session = FakeEditorSession::new(runs);
    let rows: String = (0..130_000).map(|n| format!("{n}\n")).collect();
    assert!(
        rows.len() > 3 * 256 * 1024,
        "{} bytes is not over three pieces",
        rows.len()
    );

    let report = import(
        &session,
        &format!("COPY t FROM stdin;\n{rows}\\.\nSELECT 2;\n"),
        SqlImportErrorPolicy::Continue,
    )
    .await;

    assert_eq!(report.end, SqlImportEnd::Completed, "{report:?}");
    assert_eq!((report.statements, report.failed), (1, 1));
    let texts = texts(&session);
    assert_eq!(texts.last().map(String::as_str), Some("SELECT 2"));
    assert_eq!(texts.iter().filter(|text| text.as_str() == "SELECT 2").count(), 1);
    assert!(!texts.iter().any(|text| text.contains("129999")), "a row ran as SQL");
}

#[tokio::test]
async fn a_refused_copy_under_stop_ends_the_import_at_it() {
    let session = refusing_copies();

    let report = import(
        &session,
        "COPY t FROM stdin;\n1\n2\n\\.\nSELECT 2;\n",
        SqlImportErrorPolicy::Stop,
    )
    .await;

    assert_eq!(report.end, SqlImportEnd::Stopped);
    assert_eq!((report.statements, report.failed), (0, 1));
    assert!(!texts(&session).contains(&"SELECT 2".to_owned()));
}

#[tokio::test]
async fn a_binary_copy_is_refused_and_the_statements_after_its_rows_run() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    let session = FakeEditorSession::new(runs);

    let report = import(
        &session,
        "COPY t FROM stdin (FORMAT binary);\nPGCOPY\n\\.\nSELECT 3;\n",
        SqlImportErrorPolicy::Continue,
    )
    .await;

    assert_eq!((report.statements, report.failed), (1, 1));
    assert!(session.copies().is_empty());
    assert_eq!(texts(&session).last().map(String::as_str), Some("SELECT 3"));
}

/// A file whose reads stop after `head` until `gate` opens.
struct GatedFile {
    head: Cursor<Vec<u8>>,
    gate: std::sync::mpsc::Receiver<()>,
    tail: Cursor<Vec<u8>>,
}

impl Read for GatedFile {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let read = self.head.read(buffer)?;
        if read > 0 {
            return Ok(read);
        }
        // Ends when the sender sends or goes away.
        let _ = self.gate.recv();
        self.tail.read(buffer)
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelling_in_the_middle_of_a_copy_abandons_it() {
    let mut runs = Replies::default();
    runs.always(FakeRun::completed(Vec::new()));
    let session = Arc::new(FakeEditorSession::new(runs));
    let rows: String = (0..30_000).map(|n| format!("{n}\trow {n}\n")).collect();
    let (open, gate) = std::sync::mpsc::channel();
    let file = GatedFile {
        head: Cursor::new(format!("COPY t (a, b) FROM stdin;\n{rows}").into_bytes()),
        gate,
        tail: Cursor::new(b"\\.\nSELECT 1;\n".to_vec()),
    };
    let cancel = CancellationToken::new();
    let importing = {
        let session = Arc::clone(&session);
        let cancel = cancel.clone();
        tokio::spawn(async move {
            let dialect = FakeDialect;
            run_sql_import(
                session.as_ref(),
                &dialect,
                Box::new(file),
                options(SqlImportErrorPolicy::Stop),
                &mut |_| {},
                &cancel,
            )
            .await
        })
    };
    let mut waited = 0;
    while session.copies().first().is_none_or(|copy| copy.pieces == 0) {
        assert!(waited < 1_000, "no rows reached the session");
        tokio::time::sleep(Duration::from_millis(10)).await;
        waited += 1;
    }

    cancel.cancel();
    drop(open);
    let report = importing.await.expect("the import");

    assert_eq!(report.end, SqlImportEnd::Cancelled, "{report:?}");
    assert_eq!(report.statements, 0);
    let copies = session.copies();
    assert!(!copies[0].ended, "a cancelled copy was finished");
    assert!(copies[0].data.len() < rows.len());
    assert!(!texts(&session).contains(&"SELECT 1".to_owned()));
}
