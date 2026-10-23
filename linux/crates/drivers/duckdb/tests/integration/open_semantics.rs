//! What opening a path does: open what is there, create only when asked,
//! replace atomically, and keep one database per file in the process.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};

use tablepro_core::{
    BusyReason, DriverError, EditorSessionState, FileEndpoint, ReadOnlyRefusal, ReadStatement, RunEnd, ServerCode,
    UserSql, Value, WorkspaceSettings,
};

use crate::support::{Collected, TestFile, apply, call, connect, query, run, session, writable};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_missing_file_is_not_found_and_not_created() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("missing.duckdb");

    let opened = connect(FileEndpoint::open_existing(path.clone()).unwrap(), writable()).await;

    assert!(
        matches!(&opened, Err(DriverError::FileNotFound { path: missing }) if *missing == path),
        "{:?}",
        opened.err()
    );
    assert!(!path.exists(), "opening a missing path created a database");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_new_database_replaces_the_file_and_its_log() {
    let file = TestFile::new();
    let old = file.open().await;
    apply(old.as_ref(), &["CREATE TABLE old_table (a INTEGER)"])
        .await
        .unwrap();
    old.close().await.unwrap();
    drop(old);
    let wal = format!("{}.wal", file.path.display());
    std::fs::write(&wal, b"a log left from the replaced database").unwrap();

    let created = connect(FileEndpoint::create_new(file.path.clone()).unwrap(), writable())
        .await
        .unwrap();

    let tables = query(created.as_ref(), "SELECT count(*) FROM duckdb_tables()").await;
    assert_eq!(tables.rows[0][0], Value::Int(0), "the old tables survived the replace");
    let mode = std::fs::metadata(&file.path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    created.close().await.unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_that_is_no_database_says_so() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("notes.duckdb");
    std::fs::write(&path, "plain text that is long enough to hold a database header").unwrap();

    let opened = connect(FileEndpoint::open_existing(path.clone()).unwrap(), writable()).await;

    assert_eq!(opened.err(), Some(DriverError::NotADatabase { path }));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_read_only_connection_is_refused_by_duckdb_itself() {
    let file = TestFile::new();
    let writer = file.open().await;
    apply(writer.as_ref(), &["CREATE TABLE t (a INTEGER)"]).await.unwrap();
    writer.close().await.unwrap();
    drop(writer);
    let reader = connect(file.endpoint(), WorkspaceSettings::workspace(true))
        .await
        .unwrap();
    let editor = session(reader.as_ref()).await;

    let saved = apply(reader.as_ref(), &["INSERT INTO t VALUES (1)"]).await;
    let (summary, _) = run(editor.as_ref(), "INSERT INTO t VALUES (1)").await;

    assert_eq!(saved.err(), Some(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard)));
    assert!(
        matches!(
            &summary.end,
            RunEnd::Failed(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
        ),
        "{:?}",
        summary.end
    );
    editor.close().await;
    reader.close().await.unwrap();
}

/// Two windows on one file share the database DuckDB keeps for it: a
/// second instance would keep a catalogue and a log of its own.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_workspaces_on_one_file_share_its_database() {
    let file = TestFile::new();
    let first = file.open().await;
    let second = file.open().await;

    apply(
        first.as_ref(),
        &["CREATE TABLE shared (a INTEGER)", "INSERT INTO shared VALUES (7)"],
    )
    .await
    .unwrap();
    let read = query(second.as_ref(), "SELECT a FROM shared").await;
    let read_only = connect(file.endpoint(), WorkspaceSettings::workspace(true)).await;

    assert_eq!(read.rows, vec![vec![Value::Int(7)]]);
    assert_eq!(read_only.err(), Some(DriverError::Busy(BusyReason::FileLocked)));
    first.close().await.unwrap();
    second.close().await.unwrap();
}

/// An editor tab keeps its connection after the workspace closes, and
/// the file is let go once both are gone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_editor_session_outlives_its_workspace() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    connection.close().await.unwrap();
    drop(connection);

    let (summary, collected) = run(editor.as_ref(), "SELECT 42 AS answer").await;
    assert_eq!(summary.end, RunEnd::Completed);
    assert_eq!(collected.rows(), vec![vec![Value::Int(42)]]);
    editor.close().await;
    assert_eq!(editor.state(), EditorSessionState::Lost);
    drop(editor);

    let replaced = connect(FileEndpoint::create_new(file.path.clone()).unwrap(), writable()).await;
    assert!(replaced.is_ok(), "the file was still held: {:?}", replaced.err());
}

/// The app makes no requests of its own, so DuckDB fetches and loads no
/// extension by itself.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn extensions_are_never_installed_or_loaded_on_their_own() {
    let file = TestFile::new();
    let connection = file.open().await;

    let settings = query(
        connection.as_ref(),
        "SELECT current_setting('autoinstall_known_extensions'), current_setting('autoload_known_extensions')",
    )
    .await;

    assert_eq!(settings.rows, vec![vec![Value::Bool(false), Value::Bool(false)]]);
    connection.close().await.unwrap();
}

/// An export of the user's SQL runs in a read-only transaction, which
/// holds only while that SQL leaves the transaction alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_exported_query_cannot_write() {
    let file = TestFile::new();
    let connection = file.open().await;
    apply(connection.as_ref(), &["CREATE TABLE t (a INTEGER)"])
        .await
        .unwrap();
    let export = |sql: &str| {
        let read = ReadStatement::User(UserSql::new(sql));
        let connection = connection.clone();
        async move { connection.stream_read(&read, Collected::default().sink(), call()).await }
    };

    let committed = export("SELECT 1; COMMIT; INSERT INTO t VALUES (1)").await;
    let inserted = export("INSERT INTO t VALUES (2)").await;
    let read = export("SELECT 'COMMIT' AS word").await;

    assert_eq!(
        committed.err(),
        Some(DriverError::ReadOnly(ReadOnlyRefusal::ClientGuard))
    );
    assert!(
        matches!(
            &inserted,
            Err(DriverError::ReadOnly(ReadOnlyRefusal::ServerRejected(_)))
        ),
        "{inserted:?}"
    );
    assert_eq!(read.unwrap().rows, 1);
    let rows = query(connection.as_ref(), "SELECT count(*) FROM t").await;
    assert_eq!(rows.rows, vec![vec![Value::Int(0)]]);
    connection.close().await.unwrap();
}

/// A hard link is the same file, so it joins the database already open.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_second_name_for_the_file_shares_its_database() {
    let file = TestFile::new();
    let linked = file.path.with_file_name("linked.duckdb");
    std::fs::hard_link(&file.path, &linked).unwrap();
    let first = file.open().await;
    let second = connect(FileEndpoint::open_existing(linked).unwrap(), writable())
        .await
        .unwrap();

    apply(first.as_ref(), &["CREATE TABLE shared (a INTEGER)"])
        .await
        .unwrap();
    let read = query(second.as_ref(), "SELECT count(*) FROM shared").await;

    assert_eq!(read.rows, vec![vec![Value::Int(0)]]);
    first.close().await.unwrap();
    second.close().await.unwrap();
}

/// An editor tab attaching a file another window has open would make a
/// second database on it, and so would a window opening a file a tab
/// has attached.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_open_in_one_place_is_not_opened_in_another() {
    let file = TestFile::new();
    let other = TestFile::new();
    let spare = TestFile::new();
    let connection = file.open().await;
    let opened = other.open().await;
    let editor = session(connection.as_ref()).await;

    let (attaching_open, _) = run(editor.as_ref(), &format!("ATTACH '{}' AS o", other.path.display())).await;
    let (attaching_spare, _) = run(editor.as_ref(), &format!("ATTACH '{}' AS s", spare.path.display())).await;
    let (attaching_again, _) = run(
        editor.as_ref(),
        &format!("ATTACH IF NOT EXISTS '{}' AS s", spare.path.display()),
    )
    .await;
    let unrelated = TestFile::new();
    let (no_op, _) = run(
        editor.as_ref(),
        &format!("ATTACH IF NOT EXISTS '{}' AS s", unrelated.path.display()),
    )
    .await;
    let spare_link = spare.path.with_file_name("spare-link.duckdb");
    std::fs::hard_link(&spare.path, &spare_link).unwrap();
    let own_link = file.path.with_file_name("own-link.duckdb");
    std::fs::hard_link(&file.path, &own_link).unwrap();
    let mut through_links = Vec::new();
    for (alias, link) in [("s2", &spare_link), ("me", &own_link)] {
        let (summary, _) = run(
            editor.as_ref(),
            &format!("ATTACH IF NOT EXISTS '{}' AS {alias}", link.display()),
        )
        .await;
        through_links.push(summary.end);
    }
    let opening_attached = connect(spare.endpoint(), writable()).await;
    // DuckDB follows a link before it looks for the file among its own,
    // so a link to one it has open is refused by DuckDB itself.
    let spare_symlink = spare.path.with_file_name("spare-symlink.duckdb");
    std::os::unix::fs::symlink(&spare.path, &spare_symlink).unwrap();
    let (through_symlink, _) = run(editor.as_ref(), &format!("ATTACH '{}' AS s3", spare_symlink.display())).await;
    let hidden = TestFile::new();
    let (attaching_hidden, _) = run(
        editor.as_ref(),
        &format!("ATTACH '{}' AS h (HIDDEN)", hidden.path.display()),
    )
    .await;

    assert_eq!(
        attaching_open.end,
        RunEnd::Failed(DriverError::Busy(BusyReason::FileLocked))
    );
    assert_eq!(attaching_spare.end, RunEnd::Completed);
    assert!(
        matches!(&through_symlink.end, RunEnd::Failed(DriverError::Server(diagnostics)) if diagnostics.message.contains("already attached")),
        "{:?}",
        through_symlink.end
    );
    assert_eq!(
        attaching_again.end,
        RunEnd::Completed,
        "the tab's own database has the file, which DuckDB finds itself"
    );
    assert_eq!(no_op.end, RunEnd::Completed);
    assert!(
        !tablepro_core::claimed_by_another(&unrelated.path, "sqlite"),
        "an ATTACH under a taken alias opened nothing to claim"
    );
    assert!(tablepro_core::claimed_by_another(&spare.path, "sqlite"));
    assert_eq!(
        through_links,
        [
            RunEnd::Failed(DriverError::Busy(BusyReason::FileLocked)),
            RunEnd::Failed(DriverError::Busy(BusyReason::FileLocked))
        ],
        "DuckDB finds its own files by path, so a hard link would open one twice"
    );
    assert_eq!(opening_attached.err(), Some(DriverError::Busy(BusyReason::FileLocked)));
    assert_eq!(
        attaching_hidden.end,
        RunEnd::Failed(DriverError::Unsupported {
            feature: tablepro_core::UnsupportedFeature::HiddenAttach
        }),
        "DuckDB lists a HIDDEN database nowhere another window could see it"
    );
    assert!(!tablepro_core::held_by_this_process(&hidden.path));
    editor.close().await;
    opened.close().await.unwrap();
    connection.close().await.unwrap();
}

/// DuckDB reads an ATTACH path in every string form it has, and each
/// spelling of a file another window has open names that file. A
/// `U&'...'` string and a `\u` escape DuckDB refuses itself, as it
/// refuses an expression.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_spelling_of_an_open_file_is_refused() {
    let file = TestFile::new();
    let other = TestFile::new();
    let connection = file.open().await;
    let opened = other.open().await;
    let editor = session(connection.as_ref()).await;
    let path = other.path.display().to_string();
    let (directory, name) = path.rsplit_once('/').unwrap();
    let spellings = [
        format!("ATTACH E'{}' AS o", path.replace('/', "\\x2f")),
        format!("ATTACH '{directory}/'\n'{name}' AS o"),
        format!("ATTACH 'file://{path}' AS o"),
        format!("ATTACH 'duckdb:{path}' AS o"),
        format!("ATTACH IF NOT EXISTS $p${path}$p$ -- why\n AS o"),
        format!("ATTACH '{directory}/missing/../{name}' AS o"),
    ];

    for sql in &spellings {
        let (summary, _) = run(editor.as_ref(), sql).await;
        assert_eq!(
            summary.end,
            RunEnd::Failed(DriverError::Busy(BusyReason::FileLocked)),
            "{sql}"
        );
    }
    for sql in [
        "ATTACH 40 + 2 AS o".to_owned(),
        format!("ATTACH U&'{path}' AS o"),
        format!("ATTACH E'{}' AS o", path.replace('/', "\\u002f")),
    ] {
        let (malformed, _) = run(editor.as_ref(), &sql).await;
        assert!(
            matches!(
                &malformed.end,
                RunEnd::Failed(DriverError::Server(diagnostics))
                    if diagnostics.code == Some(ServerCode::DuckDb { error_type: "Parser".to_owned() })
            ),
            "{sql}: {:?}",
            malformed.end
        );
    }
    editor.close().await;
    opened.close().await.unwrap();
    connection.close().await.unwrap();
}

const HOLDER: &str = "TABLEPRO_DUCKDB_TEST_HOLD";
/// What the other process prints once it holds the file. The test
/// harness prints the test's name on the same line before it.
const HELD: &str = "tablepro-duckdb-test-held";

/// The other process of `a_file_another_process_has_open_is_not_replaced`:
/// it opens the file it is given and keeps it until its input closes.
#[test]
#[ignore = "the other process of a_file_another_process_has_open_is_not_replaced, which starts it"]
fn hold_a_file_open() {
    let Some(path) = std::env::var_os(HOLDER) else {
        return;
    };
    let connection = duckdb::Connection::open(path).unwrap();
    writeln!(std::io::stdout(), "{HELD}").unwrap();
    std::io::stdout().flush().unwrap();
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    drop(connection);
}

/// A database another process has open keeps its lock, and replacing it
/// would leave that process writing a log beside the new file.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_file_another_process_has_open_is_not_replaced() {
    let file = TestFile::new();
    let mut holder = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "open_semantics::hold_a_file_open",
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(HOLDER, &file.path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut output = BufReader::new(holder.stdout.take().unwrap());
    let mut line = String::new();
    while !line.contains(HELD) {
        line.clear();
        assert!(
            output.read_line(&mut line).unwrap() > 0,
            "the other process never opened the file"
        );
    }

    let replaced = connect(FileEndpoint::create_new(file.path.clone()).unwrap(), writable()).await;

    drop(holder.stdin.take());
    let _ = std::io::copy(&mut output, &mut std::io::sink());
    holder.wait().unwrap();
    assert_eq!(replaced.err(), Some(DriverError::Busy(BusyReason::FileLocked)));
    let kept = file.open().await;
    let tables = query(kept.as_ref(), "SELECT count(*) FROM duckdb_tables()").await;
    assert_eq!(tables.rows, vec![vec![Value::Int(0)]]);
    kept.close().await.unwrap();
}

/// An ATTACH of a FIFO would wait for a writer, with every open in the
/// process waiting behind it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_attach_of_a_fifo_is_refused() {
    let file = TestFile::new();
    let connection = file.open().await;
    let editor = session(connection.as_ref()).await;
    let fifo = file.path.with_file_name("pipe.duckdb");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );

    let (attached, _) = run(
        editor.as_ref(),
        &format!("ATTACH '{}' AS p (READ_ONLY)", fifo.display()),
    )
    .await;

    assert_eq!(attached.end, RunEnd::Failed(DriverError::NotADatabase { path: fifo }));
    editor.close().await;
    connection.close().await.unwrap();
}
