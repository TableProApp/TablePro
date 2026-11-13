#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    clippy::expect_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use secrecy::SecretString;
use tablepro_ffi::window_abi::{TpCursor, TpWindow, tablepro_cursor_fetch, tablepro_cursor_free};
use tablepro_ffi::{
    ColumnSort, Core, CoreError, DatabaseSession, EndpointInfo, FileOpenRequest, HostConfig, HostSecretError,
    HostSecrets, ObjectKindTag, ObjectScopeArg, QueryEditor, RunEvent, RunListener, RunOutcome, RunSettings,
    SecretItemTag, SecretKindTag, SessionHealthTag, TableName, TransactionStateTag, ValueKind,
};

struct NoSecrets;

impl HostSecrets for NoSecrets {
    fn load(&self, _: String, _: SecretKindTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store(&self, _: String, _: SecretKindTag, _: SecretString, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn relabel(&self, _: String, _: SecretKindTag, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete(&self, _: String, _: SecretKindTag) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_connection(&self, _: String) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn load_item(&self, _: SecretItemTag) -> Result<Option<SecretString>, HostSecretError> {
        Ok(None)
    }

    fn store_item(&self, _: SecretItemTag, _: SecretString) -> Result<(), HostSecretError> {
        Ok(())
    }

    fn delete_item(&self, _: SecretItemTag) -> Result<(), HostSecretError> {
        Ok(())
    }
}

#[derive(Clone, Default)]
struct Wakes(Arc<AtomicUsize>);

impl RunListener for Wakes {
    fn events_pending(&self) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

fn core() -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

fn request(path: &Path, create: bool) -> FileOpenRequest {
    FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only: false,
        create,
    }
}

async fn run(editor: &QueryEditor, sql: &str, settings: RunSettings) -> (RunOutcome, Vec<RunEvent>, Wakes) {
    let wakes = Wakes::default();
    let run = editor.run(sql.to_owned(), settings, false, Box::new(wakes.clone()));
    let outcome = run.outcome().await.unwrap();
    (outcome, run.drain_events(), wakes)
}

async fn fixture(dir: &Path) -> (Arc<Core>, Arc<DatabaseSession>, Arc<QueryEditor>) {
    let core = core();
    let session = core
        .open_file(request(&dir.join("app.sqlite"), true), None)
        .await
        .unwrap();
    let editor = session.open_editor(None).await.unwrap();
    for sql in [
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, note TEXT)",
        "INSERT INTO people (name, note) VALUES ('Ada', NULL), ('Grace', 'line one\nline two'), ('Zoë 👋', '中文')",
    ] {
        let (outcome, _, _) = run(&editor, sql, RunSettings::default()).await;
        assert!(matches!(outcome, RunOutcome::Completed { .. }), "{sql}: {outcome:?}");
    }
    (core, session, editor)
}

struct Cells {
    texts: Vec<Option<String>>,
    kinds: Vec<u8>,
    raw: Vec<i64>,
    total_rows: u64,
    rows: u32,
}

fn read(window: &TpWindow) -> Cells {
    let cells = window.row_count as usize * window.column_count as usize;
    // SAFETY: a window's arrays hold `cells` entries until the cursor's next fetch.
    unsafe {
        let offsets = std::slice::from_raw_parts(window.offsets, cells + 1);
        let text = std::slice::from_raw_parts(window.text, offsets[cells] as usize);
        let nulls = std::slice::from_raw_parts(window.nulls, cells.div_ceil(8));
        Cells {
            texts: (0..cells)
                .map(|cell| {
                    (nulls[cell / 8] & (1 << (cell % 8)) == 0).then(|| {
                        String::from_utf8(text[offsets[cell] as usize..offsets[cell + 1] as usize].to_vec()).unwrap()
                    })
                })
                .collect(),
            kinds: std::slice::from_raw_parts(window.cell_kinds, cells).to_vec(),
            raw: std::slice::from_raw_parts(window.raw, cells).to_vec(),
            total_rows: window.total_rows,
            rows: window.row_count,
        }
    }
}

fn fetch(cursor: u64, first_row: u64, rows: u32, columns: u32, max_chars: u32) -> Cells {
    let cursor = std::ptr::with_exposed_provenance_mut::<TpCursor>(cursor as usize);
    // SAFETY: the cursor is live and only this thread uses it.
    let window = unsafe { tablepro_cursor_fetch(cursor, first_row, rows, 0, columns, max_chars) };
    // SAFETY: a non-null window stays valid until the next fetch.
    read(unsafe { window.as_ref() }.expect("a window"))
}

fn free(cursor: u64) {
    // SAFETY: freed once, after its last fetch.
    unsafe { tablepro_cursor_free(std::ptr::with_exposed_provenance_mut::<TpCursor>(cursor as usize)) }
}

#[test]
fn every_engine_of_the_first_release_is_listed_and_sqlite_opens_files() {
    let drivers = core().drivers();

    assert_eq!(drivers.len(), 9);
    let sqlite = drivers.iter().find(|driver| driver.id == "sqlite").unwrap();
    assert!(matches!(&sqlite.endpoint, EndpointInfo::File { suffixes } if suffixes.contains(&"sqlite3".to_owned())));
}

#[tokio::test]
async fn the_catalog_lists_each_level_as_it_is_asked_for() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session, _editor) = fixture(dir.path()).await;

    let schemas = session.schemas(None).await.unwrap();
    let objects = session
        .refresh_objects(ObjectScopeArg::DefaultSchema, None)
        .await
        .unwrap();
    let columns = session
        .columns(
            TableName {
                schema: None,
                name: "people".to_owned(),
            },
            None,
        )
        .await
        .unwrap();

    assert!(schemas.iter().any(|schema| schema.is_default), "{schemas:?}");
    let people = objects.iter().find(|object| object.name == "people").unwrap();
    assert_eq!(people.kind, ObjectKindTag::Table);
    let names: Vec<&str> = columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "name", "note"]);
    assert_eq!(columns[0].value_kind, ValueKind::Integer);
    assert!(columns[0].primary_key);
    assert_eq!(columns[1].value_kind, ValueKind::Text);
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_query_streams_into_a_result_set_a_window_reads() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _session, editor) = fixture(dir.path()).await;
    let wakes = Wakes::default();

    let query = editor.run(
        "SELECT id, name, note FROM people ORDER BY id".to_owned(),
        RunSettings::default(),
        false,
        Box::new(wakes.clone()),
    );
    let outcome = query.outcome().await.unwrap();
    let events = query.drain_events();

    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    assert!(wakes.0.load(Ordering::SeqCst) >= 1);
    assert!(matches!(events.first(), Some(RunEvent::ResultSetStarted { set_index: 0, columns }) if columns.len() == 3));
    assert!(events.contains(&RunEvent::RowsAppended {
        set_index: 0,
        row_count: 3
    }));
    assert!(matches!(events.last(), Some(RunEvent::Finished { .. })));
    let set = query.result_set(0).unwrap();
    assert_eq!(set.row_count(), 3);
    assert!(set.is_finished());
    assert_eq!(set.cell_text(1, 2).unwrap().as_deref(), Some("line one\nline two"));

    let cursor = set.open_cursor();
    let window = fetch(cursor, 0, 50, 3, 6);
    free(cursor);

    assert_eq!((window.rows, window.total_rows), (3, 3));
    assert_eq!(
        window.texts,
        [
            Some("1".to_owned()),
            Some("2".to_owned()),
            Some("3".to_owned()),
            Some("Ada".to_owned()),
            Some("Grace".to_owned()),
            Some("Zoë 👋".to_owned()),
            None,
            Some("line o".to_owned()),
            Some("中文".to_owned()),
        ]
    );
    assert_eq!(&window.raw[..3], [1, 2, 3]);
    assert_eq!(window.kinds[0], ValueKind::Integer as u8);
}

#[tokio::test]
async fn a_cancel_stops_the_statement_on_the_engine() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _session, editor) = fixture(dir.path()).await;
    let endless = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c";

    let query = editor.run(
        endless.to_owned(),
        RunSettings::default(),
        false,
        Box::new(Wakes::default()),
    );
    tokio::time::sleep(Duration::from_millis(200)).await;
    let asked = Instant::now();
    query.cancel();
    let outcome = query.outcome().await.unwrap();

    assert_eq!(outcome, RunOutcome::Cancelled);
    assert!(asked.elapsed() < Duration::from_secs(5), "{:?}", asked.elapsed());
    let (after, _, _) = run(&editor, "SELECT 1", RunSettings::default()).await;
    assert!(matches!(after, RunOutcome::Completed { .. }), "{after:?}");
}

#[tokio::test]
async fn errors_carry_the_codes_the_app_words_them_by() {
    let dir = tempfile::tempdir().unwrap();
    let (core, _session, editor) = fixture(dir.path()).await;

    let missing = core
        .open_file(request(&dir.path().join("missing.sqlite"), false), None)
        .await
        .unwrap_err();
    let relative = core
        .open_file(request(Path::new("relative.sqlite"), false), None)
        .await
        .unwrap_err();
    let (refused, _, _) = run(&editor, "SELECT * FROM nope", RunSettings::default()).await;

    let CoreError::Failed { info } = missing else {
        panic!("{missing:?}")
    };
    assert_eq!(info.codes, ["connect.driver", "driver.file_not_found"]);
    assert!(info.path.unwrap().ends_with("missing.sqlite"));
    assert_eq!(relative.code(), "config.relative_path");
    let RunOutcome::Failed { info } = refused else {
        panic!("{refused:?}")
    };
    assert_eq!(info.code, "driver.server");
    assert!(info.server.unwrap().message.contains("no such table"));
}

#[tokio::test]
async fn a_cancelled_open_is_a_cancel() {
    let dir = tempfile::tempdir().unwrap();
    let cancel = tablepro_ffi::CancelToken::new();
    cancel.cancel();

    let error = core()
        .open_file(request(&dir.path().join("new.sqlite"), true), Some(cancel))
        .await
        .unwrap_err();

    assert_eq!(error, CoreError::Cancelled);
}

#[tokio::test]
async fn a_million_rows_stream_in_and_any_window_reads_back() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _session, editor) = fixture(dir.path()).await;
    let million = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 1000000) \
                   SELECT x, 'row ' || x, x * 0.5 FROM c";

    let wakes = Wakes::default();

    let started = Instant::now();
    let query = editor.run(
        million.to_owned(),
        RunSettings {
            row_limit: Some(1_000_000),
            timeout_ms: None,
            byte_limit: None,
        },
        false,
        Box::new(wakes.clone()),
    );
    let outcome = query.outcome().await.unwrap();
    let streamed = started.elapsed();
    let events = query.drain_events();
    let set = query.result_set(0).unwrap();
    let cursor = set.open_cursor();
    let fetching = Instant::now();
    let first = fetch(cursor, 0, 50, 3, 100);
    let middle = fetch(cursor, 500_000, 50, 3, 100);
    let last = fetch(cursor, 999_990, 50, 3, 100);
    let fetched = fetching.elapsed();
    free(cursor);

    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    assert_eq!(set.row_count(), 1_000_000);
    assert_eq!(
        wakes.0.load(Ordering::SeqCst),
        1,
        "no drain ran, so one wake covers every batch"
    );
    assert!(events.len() < 6, "rows coalesce between drains: {events:?}");
    assert_eq!(first.texts[0].as_deref(), Some("1"));
    assert_eq!(middle.texts[0].as_deref(), Some("500001"));
    assert_eq!(middle.texts[50].as_deref(), Some("row 500001"));
    assert_eq!(middle.texts[100].as_deref(), Some("250000.5"));
    assert_eq!((last.rows, last.total_rows), (10, 1_000_000));
    assert_eq!(last.texts[9].as_deref(), Some("1000000"));
    assert_eq!(last.raw[9], 1_000_000);
    eprintln!("1,000,000 rows streamed in {streamed:?}; three windows read in {fetched:?}");
}

async fn column_texts(editor: &QueryEditor, sql: &str, column: u32) -> (u32, Vec<Option<String>>) {
    let query = editor.run(
        sql.to_owned(),
        RunSettings::default(),
        false,
        Box::new(Wakes::default()),
    );
    let outcome = query.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{sql}: {outcome:?}");
    let set = query.result_set(0).unwrap();
    let width = u32::try_from(set.columns().len()).unwrap();
    let texts = (0..set.row_count())
        .map(|row| set.cell_text(row, column).unwrap())
        .collect();
    (width, texts)
}

fn texts(values: &[&str]) -> Vec<Option<String>> {
    values.iter().map(|value| Some((*value).to_owned())).collect()
}

// The width of a table's page and the texts of one of its columns, once the read has finished.
async fn page_texts(
    session: &DatabaseSession,
    table: TableName,
    sort: Option<ColumnSort>,
    limit: u64,
    offset: u64,
    column: u32,
) -> (u32, bool, u32, Vec<Option<String>>) {
    let page = session
        .read_table_page(
            table,
            sort,
            None,
            limit,
            offset,
            false,
            Box::new(Wakes::default()),
            None,
        )
        .await
        .unwrap();
    let run = page.run();
    let outcome = run.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let set = run.result_set(0).unwrap();
    let width = u32::try_from(set.columns().len()).unwrap();
    let texts = (0..set.row_count())
        .map(|row| set.cell_text(row, column).unwrap())
        .collect();
    (page.visible_columns(), page.can_seek(), width, texts)
}

#[tokio::test]
async fn a_table_page_sorts_on_the_server_and_names_the_columns_a_grid_shows() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session, editor) = fixture(dir.path()).await;
    let (outcome, _, _) = run(
        &editor,
        "CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('b'), ('a')",
        RunSettings::default(),
    )
    .await;
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let people = TableName {
        schema: None,
        name: "people".to_owned(),
    };
    let notes = TableName {
        schema: None,
        name: "notes".to_owned(),
    };
    let descending = Some(ColumnSort {
        column: 1,
        ascending: false,
    });

    let by_body = Some(ColumnSort {
        column: 0,
        ascending: true,
    });

    let (visible, _, _, names) = page_texts(&session, people.clone(), descending, 100, 0, 1).await;
    let (_, _, _, limited) = page_texts(&session, people, descending, 2, 0, 1).await;
    let (body_visible, _, width, bodies) = page_texts(&session, notes, by_body, 100, 0, 0).await;

    assert_eq!(visible, 3);
    assert_eq!(names, texts(&["Zoë 👋", "Grace", "Ada"]));
    assert_eq!(limited, texts(&["Zoë 👋", "Grace"]));
    assert_eq!(bodies, texts(&["a", "b"]));
    // A table without a key pages by its rowid, which follows the visible column.
    assert_eq!((body_visible, width), (1, 2));
}

#[tokio::test]
async fn a_query_result_sorts_by_running_its_own_statement_again() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session, editor) = fixture(dir.path()).await;
    let sorted = |sql: &str, columns: &[&str], column: u32, ascending: bool| {
        session
            .sorted_query(
                sql.to_owned(),
                columns.iter().map(|name| (*name).to_owned()).collect(),
                column,
                ascending,
            )
            .unwrap()
    };

    let by_name = sorted("SELECT name FROM people ORDER BY id LIMIT 2;", &["name"], 0, false).unwrap();
    let joined = sorted(
        "SELECT a.id, b.id FROM people a JOIN people b ON b.id = 4 - a.id",
        &["id", "id"],
        1,
        true,
    )
    .unwrap();
    let computed = sorted("SELECT name, id * 10 FROM people", &["name", "id * 10"], 1, false).unwrap();
    let (_, names) = column_texts(&editor, &by_name, 0).await;
    let (_, left_ids) = column_texts(&editor, &joined, 0).await;
    let (_, by_number) = column_texts(&editor, &computed, 0).await;

    assert_eq!(by_name, "SELECT name FROM people ORDER BY \"name\" DESC LIMIT 2");
    assert_eq!(names, texts(&["Zoë 👋", "Grace"]));
    assert_eq!(
        joined,
        "SELECT a.id, b.id FROM people a JOIN people b ON b.id = 4 - a.id ORDER BY 2 ASC"
    );
    assert_eq!(left_ids, texts(&["3", "2", "1"]));
    assert_eq!(computed, "SELECT name, id * 10 FROM people ORDER BY 2 DESC");
    assert_eq!(by_number, texts(&["Zoë 👋", "Grace", "Ada"]));
    assert_eq!(sorted("DELETE FROM people", &["name"], 0, true), None);
    assert_eq!(sorted("SELECT 1; SELECT 2", &["1"], 0, true), None);
    assert_eq!(sorted("SELECT name FROM people", &["name"], 4, true), None);
}

#[tokio::test]
async fn a_result_that_cannot_run_again_sorts_the_rows_it_holds() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _session, editor) = fixture(dir.path()).await;
    let run = editor.run(
        "SELECT name, note, id * 10 FROM people".to_owned(),
        RunSettings::default(),
        false,
        Box::new(Wakes::default()),
    );
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    let set = run.result_set(0).unwrap();

    let by_note = set.sorted(1, true).unwrap();
    let by_number = set.sorted(2, false).unwrap();
    let notes: Vec<_> = (0..by_note.row_count())
        .map(|row| by_note.cell_text(row, 1).unwrap())
        .collect();
    let cursor = by_number.open_cursor();
    let numbers = fetch(cursor, 0, 10, 3, 64);
    free(cursor);

    assert_eq!(
        notes,
        [None, Some("line one\nline two".to_owned()), Some("中文".to_owned())]
    );
    assert_eq!(numbers.texts[..3], texts(&["Zoë 👋", "Grace", "Ada"]));
    assert_eq!(numbers.texts[6..], texts(&["30", "20", "10"]));
    assert_eq!(
        set.cell_text(0, 0).unwrap().as_deref(),
        Some("Ada"),
        "the set itself keeps its order"
    );
    assert!(set.sorted(3, true).is_err());
}

#[tokio::test]
async fn a_table_pages_past_its_first_rows_and_counts_them_all() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session, _editor) = fixture(dir.path()).await;
    let people = TableName {
        schema: None,
        name: "people".to_owned(),
    };
    let by_name = Some(ColumnSort {
        column: 1,
        ascending: true,
    });

    let (_, can_seek, _, ids) = page_texts(&session, people.clone(), None, 2, 2, 0).await;
    let (_, _, _, names) = page_texts(&session, people.clone(), by_name, 2, 1, 1).await;
    let count = session.table_row_count(people, None, None).await.unwrap();

    assert!(can_seek);
    assert_eq!(ids, texts(&["3"]));
    assert_eq!(names, texts(&["Grace", "Zoë 👋"]));
    assert_eq!(count, 3);
}

#[tokio::test]
async fn a_run_reports_the_transaction_it_leaves_open() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, _session, editor) = fixture(dir.path()).await;
    let finished = |events: &[RunEvent]| match events.last() {
        Some(RunEvent::Finished { transaction, .. }) => *transaction,
        other => panic!("the run did not finish: {other:?}"),
    };

    let (_, began, _) = run(&editor, "BEGIN", RunSettings::default()).await;
    let lost = editor.is_lost();
    let (_, rolled_back, _) = run(&editor, "ROLLBACK", RunSettings::default()).await;

    assert_eq!(finished(&began), TransactionStateTag::InTransaction);
    assert_eq!(finished(&rolled_back), TransactionStateTag::Idle);
    assert!(!lost);
}

#[tokio::test]
async fn an_open_file_is_online_and_a_cancel_ends_the_wait_for_a_change() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session, _editor) = fixture(dir.path()).await;
    let cancel = tablepro_ffi::CancelToken::new();
    cancel.cancel();

    let health = session.health();
    let ended = tokio::time::timeout(
        Duration::from_secs(10),
        session.health_change(SessionHealthTag::Online, Some(cancel)),
    )
    .await;

    assert_eq!(health, SessionHealthTag::Online);
    assert!(matches!(ended, Ok(Err(CoreError::Cancelled))), "{ended:?}");
}
