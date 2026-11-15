#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

use secrecy::SecretString;
use tablepro_ffi::{
    CancelToken, ColumnSort, CombinatorTag, Core, CoreError, DatabaseSession, ExportFormatTag, FileOpenRequest,
    FilterOpTag, FilterRuleArg, FilterValueArg, HostConfig, HostSecretError, HostSecrets, ResultSet, RunListener,
    RunOutcome, RunSettings, SecretItemTag, SecretKindTag, TableFilterArg, TableName,
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

struct Quiet;

impl RunListener for Quiet {
    fn events_pending(&self) {}
}

fn table(name: &str) -> TableName {
    TableName {
        schema: None,
        name: name.to_owned(),
    }
}

async fn run(session: &DatabaseSession, sql: &str) -> Option<Arc<ResultSet>> {
    let editor = session.open_editor(None, None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), Box::new(Quiet));
    let outcome = run.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let set = run.result_set(0);
    editor.close().await.unwrap();
    set
}

async fn fixture(dir: &Path) -> (Arc<Core>, Arc<DatabaseSession>) {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap();
    let request = FileOpenRequest {
        path: dir.join("app.sqlite").display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let session = core.open_file(request, None).await.unwrap();
    run(
        &session,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL, note TEXT); \
         INSERT INTO people VALUES (1, 'Ada', 1.5, NULL), (2, 'Grace, \"Amazing\"', 2.25, 'line one\nline two')",
    )
    .await;
    (core, session)
}

fn text(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap()
}

fn named(dir: &Path, part: &str) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.contains(part))
        .collect();
    names.sort();
    names
}

fn spelled(path: &Path) -> String {
    path.display().to_string()
}

#[tokio::test]
async fn csv_and_json_of_a_result_set_hold_exactly_its_rows() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    let set = run(&session, "SELECT id, name, score, note FROM people ORDER BY id")
        .await
        .unwrap();
    let csv = dir.path().join("people.csv");
    let json = dir.path().join("people.json");
    std::fs::write(&csv, "an older export").unwrap();

    let csv_rows = session
        .export_rows(set.clone(), 4, ExportFormatTag::Csv, None, spelled(&csv), None)
        .await
        .unwrap();
    let json_rows = session
        .export_rows(set, 4, ExportFormatTag::Json, None, spelled(&json), None)
        .await
        .unwrap();

    assert_eq!((csv_rows, json_rows), (2, 2));
    assert_eq!(
        text(&csv),
        "id,name,score,note\n1,Ada,1.5,\n2,\"Grace, \"\"Amazing\"\"\",2.25,\"line one\nline two\"\n"
    );
    assert_eq!(
        text(&json),
        concat!(
            "[\n",
            r#"{"id":1,"name":"Ada","score":1.5,"note":null}"#,
            ",\n",
            r#"{"id":2,"name":"Grace, \"Amazing\"","score":2.25,"note":"line one\nline two"}"#,
            "\n]"
        )
    );
    assert_eq!(named(dir.path(), "people."), ["people.csv", "people.json"]);
}

#[tokio::test]
async fn an_excel_export_is_a_workbook() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    let set = run(&session, "SELECT id, name, score, note FROM people ORDER BY id")
        .await
        .unwrap();
    let path = dir.path().join("people.xlsx");

    let rows = session
        .export_rows(set, 4, ExportFormatTag::Excel, None, spelled(&path), None)
        .await
        .unwrap();

    assert_eq!(rows, 2);
    assert!(
        std::fs::read(&path).unwrap().starts_with(b"PK"),
        "a workbook is a zip archive"
    );
}

#[tokio::test]
async fn a_page_exports_only_its_visible_columns() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    run(
        &session,
        "CREATE TABLE notes (body TEXT); INSERT INTO notes VALUES ('first'), ('second')",
    )
    .await;
    let page = session
        .read_table_page(table("notes"), None, None, 100, 0, None, Box::new(Quiet), None)
        .await
        .unwrap();
    let read = page.run();
    let outcome = read.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let set = read.result_set(0).unwrap();
    let visible = page.visible_columns();
    assert!(
        set.columns().len() > visible as usize,
        "a table with no key pages by its row address"
    );
    let path = dir.path().join("notes.csv");

    let rows = session
        .export_rows(
            set,
            visible,
            ExportFormatTag::Csv,
            Some(table("notes")),
            spelled(&path),
            None,
        )
        .await
        .unwrap();

    assert_eq!(rows, 2);
    assert_eq!(text(&path), "body\nfirst\nsecond\n");
}

#[tokio::test]
async fn sql_insert_of_a_table_names_it_and_leaves_out_what_the_server_computes() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    run(
        &session,
        "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, \
         loud TEXT GENERATED ALWAYS AS (upper(name)) VIRTUAL); \
         INSERT INTO items (name) VALUES ('pen'), ('ink')",
    )
    .await;
    let path = dir.path().join("items.sql");

    let rows = session
        .export_table(
            table("items"),
            None,
            None,
            ExportFormatTag::SqlInsert,
            spelled(&path),
            None,
        )
        .await
        .unwrap();

    assert_eq!(rows, 2);
    assert_eq!(
        text(&path),
        "INSERT INTO \"items\" (\"id\", \"name\") VALUES (1, 'pen');\n\
         INSERT INTO \"items\" (\"id\", \"name\") VALUES (2, 'ink');\n"
    );
}

#[tokio::test]
async fn sql_insert_without_a_table_is_refused_before_any_file() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    let set = run(&session, "SELECT id, name FROM people").await.unwrap();
    let path = dir.path().join("people.sql");

    let error = session
        .export_rows(set, 2, ExportFormatTag::SqlInsert, None, spelled(&path), None)
        .await
        .unwrap_err();

    assert_eq!(error.code(), "ffi.export_needs_table");
    assert_eq!(named(dir.path(), "people.sql"), Vec::<String>::new());
}

#[tokio::test]
async fn a_table_export_writes_every_row_the_filter_selects_in_the_sort_order() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    run(
        &session,
        "CREATE TABLE numbers (n INTEGER PRIMARY KEY, label TEXT); \
         WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000) \
         INSERT INTO numbers (n, label) SELECT x, 'n' || x FROM c",
    )
    .await;
    let filter = TableFilterArg {
        combinator: CombinatorTag::And,
        rules: vec![FilterRuleArg {
            column: "n".to_owned(),
            op: FilterOpTag::Gt,
            value: Some(FilterValueArg::Single {
                value: "1000".to_owned(),
            }),
        }],
        raw_sql: None,
    };
    let newest_first = ColumnSort {
        column: 0,
        ascending: false,
    };
    let path = dir.path().join("numbers.csv");

    let rows = session
        .export_table(
            table("numbers"),
            Some(newest_first),
            Some(filter),
            ExportFormatTag::Csv,
            spelled(&path),
            None,
        )
        .await
        .unwrap();

    let written = text(&path);
    let lines: Vec<&str> = written.lines().collect();
    assert_eq!(rows, 2_000);
    assert_eq!(lines.len(), 2_001);
    assert_eq!(lines[0], "n,label");
    assert_eq!(lines[1], "3000,n3000");
    assert_eq!(lines[2_000], "1001,n1001");
}

#[tokio::test]
async fn a_cancelled_export_leaves_no_file_and_no_part_file() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    run(
        &session,
        "CREATE VIEW endless AS WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c",
    )
    .await;
    let path = spelled(&dir.path().join("endless.csv"));
    let cancel = CancelToken::new();
    let export = session.export_table(
        table("endless"),
        None,
        None,
        ExportFormatTag::Csv,
        path,
        Some(cancel.clone()),
    );
    // Cancelled once its part file is on disk, so the cancel lands mid-write.
    let watch = async {
        let started = Instant::now();
        while named(dir.path(), "endless.csv").is_empty() {
            assert!(started.elapsed() < Duration::from_secs(10), "the export never wrote");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        cancel.cancel();
    };
    let (exported, ()) = tokio::join!(export, watch);
    let error = exported.unwrap_err();

    assert_eq!(error, CoreError::Cancelled);
    assert_eq!(named(dir.path(), "endless.csv"), Vec::<String>::new());
}

#[tokio::test]
async fn a_failed_export_keeps_the_file_it_would_have_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    run(&session, "INSERT INTO people VALUES (3, 'bell' || char(7), NULL, NULL)").await;
    let set = run(&session, "SELECT id, name FROM people ORDER BY id").await.unwrap();
    let path = dir.path().join("people.xml");
    std::fs::write(&path, "an older export").unwrap();

    let error = session
        .export_rows(set, 2, ExportFormatTag::Xml, None, spelled(&path), None)
        .await
        .unwrap_err();

    assert_eq!(error.code(), "ffi.export_not_xml_text");
    assert_eq!(text(&path), "an older export");
    assert_eq!(named(dir.path(), "people.xml"), ["people.xml"]);
}

#[tokio::test]
async fn rows_still_arriving_are_not_exported() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path()).await;
    let editor = session.open_editor(None, None).await.unwrap();
    let settings = RunSettings {
        row_limit: Some(u64::MAX),
        timeout_ms: None,
        byte_limit: Some(u64::MAX),
    };
    let run = editor.run(
        "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT x FROM c".to_owned(),
        settings,
        Box::new(Quiet),
    );
    let started = Instant::now();
    let set = loop {
        if let Some(set) = run.result_set(0) {
            break set;
        }
        assert!(started.elapsed() < Duration::from_secs(10), "no set started");
        tokio::time::sleep(Duration::from_millis(5)).await;
    };
    let path = spelled(&dir.path().join("endless.csv"));

    let refused = session
        .export_rows(set, 1, ExportFormatTag::Csv, None, path, None)
        .await
        .unwrap_err();
    run.cancel();
    let _ended = run.outcome().await;
    editor.close().await.unwrap();

    assert_eq!(refused.code(), "ffi.export_unfinished");
    assert_eq!(named(dir.path(), "endless.csv"), Vec::<String>::new());
}
