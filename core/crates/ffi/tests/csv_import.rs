#![cfg(feature = "engines")]
#![expect(
    clippy::unwrap_used,
    reason = "the setup helpers fail a test the way the test functions themselves do"
)]

use std::path::Path;
use std::sync::Arc;

use secrecy::SecretString;
use tablepro_ffi::{
    ConnectionRecord, ConnectionSecrets, Core, CsvDelimiterTag, CsvImportCheck, CsvImportOutcome, CsvReadOptions,
    DatabaseSession, FileOpenRequest, HostConfig, HostSecretError, HostSecrets, ResultSet, RunListener, RunOutcome,
    RunSettings, SafeModeTag, SaveGate, SecretItemTag, SecretKindTag, TableName, TlsModeTag, TlsSettings,
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

fn core(dir: &Path) -> Arc<Core> {
    Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: Some(dir.display().to_string()),
        },
        Box::new(NoSecrets),
    )
    .unwrap()
}

fn people() -> TableName {
    TableName {
        schema: None,
        name: "people".to_owned(),
    }
}

fn comma() -> CsvReadOptions {
    CsvReadOptions {
        delimiter: CsvDelimiterTag::Comma,
        has_header: true,
        null_text: String::new(),
    }
}

async fn run(session: &DatabaseSession, sql: &str) -> Option<Arc<ResultSet>> {
    let editor = session.open_editor(None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), Box::new(Quiet));
    assert!(matches!(run.outcome().await.unwrap(), RunOutcome::Completed { .. }));
    let set = run.result_set(0);
    editor.close().await.unwrap();
    set
}

async fn open(core: &Core, path: &Path) -> Arc<DatabaseSession> {
    let request = FileOpenRequest {
        path: path.display().to_string(),
        driver_id: None,
        read_only: false,
        create: !path.exists(),
    };
    core.open_file(request, None).await.unwrap()
}

async fn seeded(core: &Core, path: &Path) -> Arc<DatabaseSession> {
    let session = open(core, path).await;
    run(
        &session,
        "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, \
         joined TEXT NOT NULL DEFAULT 'today', initials TEXT GENERATED ALWAYS AS (substr(name, 1, 1)) VIRTUAL)",
    )
    .await;
    session
}

async fn rows(session: &DatabaseSession) -> Vec<Vec<Option<String>>> {
    let set = run(session, "SELECT id, name, age, joined FROM people ORDER BY id")
        .await
        .unwrap();
    (0..set.row_count())
        .map(|row| (0..4).map(|column| set.cell_text(row, column).unwrap()).collect())
        .collect()
}

fn row(values: [Option<&str>; 4]) -> Vec<Option<String>> {
    values.iter().map(|value| value.map(str::to_owned)).collect()
}

// The plan a Ready check names, which run takes; 0 names none, so a run of anything else is refused.
fn plan_of(check: &CsvImportCheck) -> u64 {
    match check {
        CsvImportCheck::Ready { plan, .. } => *plan,
        CsvImportCheck::Empty | CsvImportCheck::RowRefused { .. } => 0,
    }
}

fn write(dir: &Path, name: &str, text: &str) -> String {
    let path = dir.join(name);
    std::fs::write(&path, text).unwrap();
    path.display().to_string()
}

#[tokio::test]
async fn a_file_lands_in_the_table_by_the_mapping_its_headers_suggest() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let session = seeded(&core, &dir.path().join("people.sqlite")).await;
    let csv = write(
        dir.path(),
        "people.csv",
        "Name, AGE ,id,joined\nAda,36,1,\nGrace,,2,1906\n",
    );
    let import = session.open_csv_import(people(), None).await.unwrap();

    let columns = import.columns();
    let preview = import.preview(csv.clone(), comma()).await.unwrap();
    let mapping = import.suggest_mapping(preview.headers.clone());
    let check = import.plan(csv, comma(), mapping.clone()).await.unwrap();
    let outcome = import.run(plan_of(&check), false, None).await.unwrap();

    let names: Vec<(&str, bool)> = columns
        .iter()
        .map(|column| (column.name.as_str(), column.server_filled))
        .collect();
    assert_eq!(
        names,
        [
            ("id", false),
            ("name", false),
            ("age", false),
            ("joined", false),
            ("initials", true)
        ]
    );
    assert!(columns[3].has_default && !columns[3].nullable);
    assert!(
        columns[1].takes_empty && !columns[2].takes_empty,
        "text takes an empty value, an integer does not"
    );
    assert_eq!(preview.headers, ["Name", " AGE ", "id", "joined"]);
    assert_eq!(preview.rows.len(), 2);
    assert!(!preview.truncated);
    assert_eq!(mapping, [Some(2), Some(0), Some(1), Some(3), None]);
    let CsvImportCheck::Ready {
        rows: 2,
        statements,
        gate,
        ..
    } = &check
    else {
        panic!("{check:?}")
    };
    assert!(!statements.is_empty());
    assert_eq!(*gate, SaveGate::Run);
    assert_eq!(outcome, CsvImportOutcome::Imported { rows: 2 });
    // An empty field is an empty text in a text column and NULL in a number column.
    assert_eq!(
        rows(&session).await,
        [
            row([Some("1"), Some("Ada"), Some("36"), Some("")]),
            row([Some("2"), Some("Grace"), None, Some("1906")]),
        ]
    );
    let again = import.run(plan_of(&check), false, None).await.unwrap_err();
    assert_eq!(again.code(), "import.not_planned");
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_field_the_column_cannot_read_names_its_line_and_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let session = seeded(&core, &dir.path().join("people.sqlite")).await;
    let csv = write(dir.path(), "bad.csv", "id;name;age\n1;Ada;36\n2;Grace;old\n");
    let options = CsvReadOptions {
        delimiter: CsvDelimiterTag::Semicolon,
        ..comma()
    };
    let import = session.open_csv_import(people(), None).await.unwrap();

    let check = import
        .plan(csv, options, vec![Some(0), Some(1), Some(2), None, None])
        .await
        .unwrap();
    let unplanned = import.run(1, false, None).await.unwrap_err();

    let CsvImportCheck::RowRefused { fault } = check else {
        panic!("{check:?}")
    };
    assert_eq!(
        (fault.line, fault.column.as_str(), fault.text.as_str()),
        (3, "age", "old")
    );
    assert!(fault.reason.starts_with("edit."), "{}", fault.reason);
    assert_eq!(unplanned.code(), "import.not_planned");
    assert!(rows(&session).await.is_empty());
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_row_the_table_refuses_rolls_the_whole_file_back_and_names_its_lines() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let session = seeded(&core, &dir.path().join("people.sqlite")).await;
    run(&session, "INSERT INTO people (id, name) VALUES (2, 'Taken')").await;
    let csv = write(dir.path(), "clash.csv", "1,Ada\n2,Grace\n");
    let options = CsvReadOptions {
        has_header: false,
        ..comma()
    };
    let import = session.open_csv_import(people(), None).await.unwrap();

    let preview = import.preview(csv.clone(), options.clone()).await.unwrap();
    let check = import
        .plan(csv, options, vec![Some(0), Some(1), None, None, None])
        .await
        .unwrap();
    let outcome = import.run(plan_of(&check), false, None).await.unwrap();

    assert_eq!(preview.headers, ["", ""], "a file with no header names no field");
    assert!(matches!(check, CsvImportCheck::Ready { rows: 2, .. }), "{check:?}");
    let CsvImportOutcome::RolledBack { lines: Some(lines), .. } = outcome else {
        panic!("{outcome:?}")
    };
    assert_eq!((lines.first, lines.last), (1, 2));
    assert_eq!(
        rows(&session).await,
        [row([Some("2"), Some("Taken"), None, Some("today")])]
    );
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_file_that_is_not_csv_text_or_has_no_rows_is_told_apart() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let session = seeded(&core, &dir.path().join("people.sqlite")).await;
    let import = session.open_csv_import(people(), None).await.unwrap();
    let binary = dir.path().join("binary.csv");
    std::fs::write(&binary, b"id,name\n1,\xff\xfe\n").unwrap();
    let header_only = write(dir.path(), "empty.csv", "id,name\n");
    let mapping = vec![Some(0), Some(1), None, None, None];

    let not_text = import.preview(binary.display().to_string(), comma()).await.unwrap_err();
    let missing = import
        .preview(dir.path().join("gone.csv").display().to_string(), comma())
        .await
        .unwrap_err();
    let empty = import.plan(header_only.clone(), comma(), mapping).await.unwrap();
    let short = import
        .plan(header_only.clone(), comma(), vec![Some(0)])
        .await
        .unwrap_err();
    let past = import
        .plan(header_only, comma(), vec![Some(5), None, None, None, None])
        .await
        .unwrap_err();
    let gone = session
        .open_csv_import(
            TableName {
                schema: None,
                name: "nowhere".to_owned(),
            },
            None,
        )
        .await;

    assert_eq!(not_text.code(), "import.not_utf8");
    assert_eq!(missing.code(), "import.unreadable");
    assert_eq!(empty, CsvImportCheck::Empty);
    assert_eq!(short.code(), "import.mapping_invalid");
    assert_eq!(past.code(), "import.mapping_invalid");
    assert!(gone.is_err());
    session.close().await.unwrap();
}

#[tokio::test]
async fn confirm_writes_asks_first_and_read_only_refuses() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("people.sqlite");
    let core = core(dir.path());
    seeded(&core, &path).await.close().await.unwrap();
    let csv = write(dir.path(), "people.csv", "id,name\n1,Ada\n");
    let mapping = vec![Some(0), Some(1), None, None, None];
    let library = core.library().unwrap();
    let record = ConnectionRecord {
        id: String::new(),
        name: "people".to_owned(),
        driver_id: "sqlite".to_owned(),
        host: String::new(),
        port: 0,
        database: path.display().to_string(),
        username: String::new(),
        integrated_auth: false,
        tls: TlsSettings {
            mode: TlsModeTag::Disable,
            ca_file: None,
            client_certificate: None,
            client_key: None,
            server_name: None,
        },
        ssh: None,
        safe_mode: SafeModeTag::ConfirmWrites,
        query_timeout_secs: None,
        color: None,
        group_id: None,
        last_opened_ms: None,
        tags: Vec::new(),
    };
    let saved = library.save(record, ConnectionSecrets::default()).await.unwrap();
    let session = core
        .connect_saved(
            saved.id,
            ConnectionSecrets::default(),
            ConnectionSecrets::default(),
            None,
            None,
        )
        .await
        .unwrap();
    let import = session.open_csv_import(people(), None).await.unwrap();

    let check = import.plan(csv.clone(), comma(), mapping.clone()).await.unwrap();
    let unanswered = import.run(plan_of(&check), false, None).await.unwrap_err();
    let answered = import.run(plan_of(&check), true, None).await.unwrap();
    session.close().await.unwrap();
    let read_only = core
        .open_file(
            FileOpenRequest {
                path: path.display().to_string(),
                driver_id: None,
                read_only: true,
                create: false,
            },
            None,
        )
        .await
        .unwrap();
    let import = read_only.open_csv_import(people(), None).await.unwrap();
    let refused = import.plan(csv, comma(), mapping).await.unwrap();

    assert!(
        matches!(
            check,
            CsvImportCheck::Ready {
                gate: SaveGate::Confirm,
                ..
            }
        ),
        "{check:?}"
    );
    assert_eq!(unanswered.code(), "import.not_confirmed");
    assert_eq!(answered, CsvImportOutcome::Imported { rows: 1 });
    assert!(
        matches!(
            refused,
            CsvImportCheck::Ready {
                gate: SaveGate::Refuse,
                ..
            }
        ),
        "{refused:?}"
    );
    assert_eq!(
        import.run(plan_of(&refused), true, None).await.unwrap_err().code(),
        "edit.read_only_connection"
    );
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_plan_made_later_replaces_the_one_before_it() {
    let dir = tempfile::tempdir().unwrap();
    let core = core(dir.path());
    let session = seeded(&core, &dir.path().join("people.sqlite")).await;
    let first = write(dir.path(), "first.csv", "id,name\n1,Ada\n");
    let second = write(dir.path(), "second.csv", "id,name\n2,Grace\n");
    let mapping = vec![Some(0), Some(1), None, None, None];
    let import = session.open_csv_import(people(), None).await.unwrap();

    let earlier = import.plan(first, comma(), mapping.clone()).await.unwrap();
    let later = import.plan(second, comma(), mapping).await.unwrap();
    let replaced = import.run(plan_of(&earlier), false, None).await.unwrap_err();
    let outcome = import.run(plan_of(&later), false, None).await.unwrap();

    assert_ne!(plan_of(&earlier), plan_of(&later));
    assert_eq!(replaced.code(), "import.not_planned");
    assert_eq!(outcome, CsvImportOutcome::Imported { rows: 1 });
    assert_eq!(
        rows(&session).await,
        [row([Some("2"), Some("Grace"), None, Some("today")])]
    );
    session.close().await.unwrap();
}
