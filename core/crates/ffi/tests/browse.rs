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
    ColumnSort, CombinatorTag, Core, CoreError, DatabaseSession, FileOpenRequest, FilterOpTag, FilterRuleArg,
    FilterValueArg, FollowedReference, HostConfig, HostSecretError, HostSecrets, ObjectEntry, ObjectKindTag,
    ObjectScopeArg, ReferenceRefusal, RowEstimate, RowReferenceChoice, RunEvent, RunListener, RunOutcome, RunSettings,
    SecretItemTag, SecretKindTag, TableFilterArg, TableName, TablePageRead, TransactionStateTag, TruncationTag,
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

const PEOPLE: &str = "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER); \
    INSERT INTO people (id, name, age) VALUES (1, 'Ada', 36), (2, 'Grace', 45), (3, 'Linus', 21), \
    (4, 'Edsger', 72), (5, 'Barbara', 50), (6, '50% off', NULL), (7, '500 units', NULL)";

const LEAGUE: &str = "CREATE TABLE teams (id INTEGER PRIMARY KEY, name TEXT NOT NULL); \
    CREATE TABLE players (id INTEGER PRIMARY KEY, team_id INTEGER REFERENCES teams (id) ON DELETE CASCADE, \
    name TEXT NOT NULL DEFAULT 'anon', score REAL); \
    CREATE INDEX players_by_score ON players (score DESC, name); \
    CREATE VIEW top_players AS SELECT name, score FROM players; \
    CREATE TRIGGER players_scored AFTER INSERT ON players \
    BEGIN UPDATE players SET score = 0 WHERE id = new.id AND score IS NULL; END";

async fn fixture(dir: &Path, sql: &str) -> (Arc<Core>, Arc<DatabaseSession>) {
    let core = Core::new(
        HostConfig {
            client_version: "test".to_owned(),
            storage_dir: None,
        },
        Box::new(NoSecrets),
    )
    .unwrap();
    let request = FileOpenRequest {
        path: dir.join("browse.sqlite").display().to_string(),
        driver_id: None,
        read_only: false,
        create: true,
    };
    let session = core.open_file(request, None).await.unwrap();
    execute(&session, sql).await;
    (core, session)
}

// On an editor of its own, closed before the test reads through the session.
async fn execute(session: &DatabaseSession, sql: &str) {
    let editor = session.open_editor(None).await.unwrap();
    let run = editor.run(sql.to_owned(), RunSettings::default(), Box::new(Quiet));
    let outcome = run.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    editor.close().await.unwrap();
}

fn table(name: &str) -> TableName {
    TableName {
        schema: None,
        name: name.to_owned(),
    }
}

fn rule(column: &str, op: FilterOpTag, value: Option<&str>) -> FilterRuleArg {
    FilterRuleArg {
        column: column.to_owned(),
        op,
        value: value.map(|value| FilterValueArg::Single {
            value: value.to_owned(),
        }),
    }
}

fn all(rules: Vec<FilterRuleArg>) -> Option<TableFilterArg> {
    Some(TableFilterArg {
        combinator: CombinatorTag::And,
        rules,
        raw_sql: None,
    })
}

fn raw(sql: &str) -> Option<TableFilterArg> {
    Some(TableFilterArg {
        combinator: CombinatorTag::And,
        rules: Vec::new(),
        raw_sql: Some(sql.to_owned()),
    })
}

async fn read(
    session: &DatabaseSession,
    sort: Option<ColumnSort>,
    filter: Option<TableFilterArg>,
    limit: u64,
    offset: u64,
) -> Result<Arc<TablePageRead>, CoreError> {
    session
        .read_table_page(table("people"), sort, filter, limit, offset, Box::new(Quiet), None)
        .await
}

// The page's texts in one column, once its read has finished.
async fn column(page: &TablePageRead, column: u32) -> Vec<Option<String>> {
    let run = page.run();
    let outcome = run.outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    let set = run.result_set(0).unwrap();
    (0..set.row_count())
        .map(|row| set.cell_text(row, column).unwrap())
        .collect()
}

fn texts(values: &[&str]) -> Vec<Option<String>> {
    values.iter().map(|value| Some((*value).to_owned())).collect()
}

#[tokio::test]
async fn a_page_s_view_sql_selects_every_page_with_its_filter_written_in() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;
    let filter = all(vec![
        rule("age", FilterOpTag::Gt, Some("40")),
        rule("name", FilterOpTag::Contains, Some("a")),
    ]);
    let by_name = Some(ColumnSort {
        column: 1,
        ascending: false,
    });

    let page = read(&session, by_name, filter, 1, 1).await.unwrap();
    let names = column(&page, 1).await;
    let sql = page.view_sql().unwrap();
    let editor = session.open_editor(None).await.unwrap();
    let run = editor.run(sql.clone(), RunSettings::default(), Box::new(Quiet));
    let outcome = run.outcome().await.unwrap();
    let set = run.result_set(0).unwrap();
    let every: Vec<Option<String>> = (0..set.row_count()).map(|row| set.cell_text(row, 1).unwrap()).collect();
    editor.close().await.unwrap();
    session.close().await.unwrap();

    assert_eq!(names, texts(&["Barbara"]));
    assert_eq!(
        sql,
        r#"SELECT "id", "name", "age" FROM "people" WHERE "age" > 40 AND "name" LIKE '%a%' ESCAPE '!' ORDER BY "people"."name" DESC, "people"."id" ASC"#
    );
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    assert_eq!(every, texts(&["Grace", "Barbara"]));
}

#[tokio::test]
async fn a_filtered_page_reads_only_the_matching_rows_and_counts_them() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;
    let older = all(vec![rule("age", FilterOpTag::Gt, Some("40"))]);

    let page = read(&session, None, older.clone(), 100, 0).await.unwrap();
    let run = page.run();
    let outcome = run.outcome().await.unwrap();
    let events = run.drain_events();
    let ids = column(&page, 0).await;
    let count = session.table_row_count(table("people"), older, None).await.unwrap();
    let everyone = session.table_row_count(table("people"), None, None).await.unwrap();
    session.close().await.unwrap();

    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    assert_eq!((page.visible_columns(), page.can_seek()), (3, true));
    assert_eq!(ids, texts(&["2", "4", "5"]));
    assert_eq!((count, everyone), (3, 7));
    assert!(
        matches!(&events[0], RunEvent::ResultSetStarted { set_index: 0, columns } if columns.len() == 3),
        "{events:?}"
    );
    assert_eq!(
        events[1..],
        [
            RunEvent::RowsAppended {
                set_index: 0,
                row_count: 3
            },
            RunEvent::ResultSetFinished {
                set_index: 0,
                row_count: 3,
                total_rows: None,
                truncation: TruncationTag::Complete,
            },
            RunEvent::Finished {
                outcome,
                transaction: TransactionStateTag::Idle,
            },
        ]
    );
}

#[tokio::test]
async fn contains_finds_a_percent_sign_as_typed_and_like_keeps_the_users_wildcards() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;

    let contains = read(
        &session,
        None,
        all(vec![rule("name", FilterOpTag::Contains, Some("50%"))]),
        100,
        0,
    )
    .await
    .unwrap();
    let like = read(
        &session,
        None,
        all(vec![rule("name", FilterOpTag::Like, Some("50%"))]),
        100,
        0,
    )
    .await
    .unwrap();
    let contained = column(&contains, 1).await;
    let liked = column(&like, 1).await;
    session.close().await.unwrap();

    assert_eq!(contained, texts(&["50% off"]));
    assert_eq!(liked, texts(&["50% off", "500 units"]));
}

#[tokio::test]
async fn a_tables_estimate_is_unknown_until_analyze_writes_its_statistics() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;

    let before = session.table_row_estimate(table("people"), None).await.unwrap();
    // ANALYZE writes sqlite_stat1, whose row for the index starts with the table's row count.
    execute(&session, "CREATE INDEX people_by_age ON people (age); ANALYZE").await;
    let after = session.table_row_estimate(table("people"), None).await.unwrap();
    session.close().await.unwrap();

    assert_eq!(before, RowEstimate::Unknown);
    assert_eq!(after, RowEstimate::Approximate { rows: 7 });
}

#[tokio::test]
async fn a_filter_on_a_column_the_table_lacks_is_refused_before_any_read() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;
    let salary = all(vec![rule("salary", FilterOpTag::Gt, Some("1000"))]);

    let refused = read(&session, None, salary.clone(), 100, 0).await.unwrap_err();
    let uncounted = session
        .table_row_count(table("people"), salary, None)
        .await
        .unwrap_err();
    session.close().await.unwrap();

    // The call fails itself: no run was started, so nothing went to the server.
    assert_eq!(refused.code(), "filter.unknown_column");
    assert!(refused.to_string().contains("salary"), "{refused}");
    assert_eq!(uncounted.code(), "filter.unknown_column");
}

#[tokio::test]
async fn a_raw_predicate_of_two_statements_is_refused_and_the_table_stays() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;

    let refused = read(&session, None, raw("1=1; DROP TABLE people"), 100, 0)
        .await
        .unwrap_err();
    let uncounted = session
        .table_row_count(table("people"), raw("1=1; DROP TABLE people"), None)
        .await
        .unwrap_err();
    let count = session.table_row_count(table("people"), None, None).await.unwrap();
    let long_names = read(&session, None, raw("length(name) > 6"), 100, 0).await.unwrap();
    let ids = column(&long_names, 0).await;
    session.close().await.unwrap();

    assert_eq!(refused.code(), "filter.raw_predicate");
    assert_eq!(uncounted.code(), "filter.raw_predicate");
    assert_eq!(count, 7);
    assert_eq!(ids, texts(&["5", "6", "7"]));
}

#[tokio::test]
async fn a_value_the_column_cannot_hold_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;

    let refused = read(
        &session,
        None,
        all(vec![rule("age", FilterOpTag::Eq, Some("forty"))]),
        100,
        0,
    )
    .await
    .unwrap_err();
    let missing = read(&session, None, all(vec![rule("age", FilterOpTag::Eq, None)]), 100, 0)
        .await
        .unwrap_err();
    session.close().await.unwrap();

    assert_eq!(refused.code(), "edit.invalid_integer");
    assert!(refused.to_string().contains("age"), "{refused}");
    assert_eq!(missing.code(), "filter.missing_value");
}

#[tokio::test]
async fn a_filtered_page_sorts_and_pages_past_its_first_rows() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;
    let with_age = || all(vec![rule("age", FilterOpTag::IsNotNull, None)]);
    let by_name = Some(ColumnSort {
        column: 1,
        ascending: true,
    });
    let oldest_first = Some(ColumnSort {
        column: 2,
        ascending: false,
    });

    let sorted = read(
        &session,
        oldest_first,
        all(vec![rule("age", FilterOpTag::Lt, Some("50"))]),
        100,
        0,
    )
    .await
    .unwrap();
    let second_by_name = read(&session, by_name, with_age(), 2, 2).await.unwrap();
    let past_three = read(&session, None, with_age(), 2, 3).await.unwrap();
    let names = column(&sorted, 1).await;
    let second_names = column(&second_by_name, 1).await;
    let ids = column(&past_three, 0).await;
    session.close().await.unwrap();

    assert_eq!(names, texts(&["Grace", "Ada", "Linus"]));
    assert_eq!(second_names, texts(&["Edsger", "Grace"]));
    assert_eq!(ids, texts(&["4", "5"]));
}

#[tokio::test]
async fn a_cancel_stops_a_page_read_on_the_engine() {
    let dir = tempfile::tempdir().unwrap();
    let endless = "CREATE VIEW endless AS \
                   WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) AS n FROM c";
    let (_core, session) = fixture(dir.path(), &format!("{PEOPLE}; {endless}")).await;

    let page = session
        .read_table_page(table("endless"), None, None, 100, 0, Box::new(Quiet), None)
        .await
        .unwrap();
    let run = page.run();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let asked = Instant::now();
    run.cancel();
    let outcome = run.outcome().await.unwrap();
    let stopped = asked.elapsed();
    let after = session.table_row_count(table("people"), None, None).await.unwrap();
    session.close().await.unwrap();

    assert_eq!(outcome, RunOutcome::Cancelled);
    assert!(stopped < Duration::from_secs(5), "{stopped:?}");
    assert_eq!(after, 7);
}

#[tokio::test]
async fn the_choices_are_what_the_engine_evaluates_on_each_column() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;

    let choices = session.filter_choices(table("people"), None).await.unwrap();
    session.close().await.unwrap();

    let names: Vec<&str> = choices.columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "name", "age"]);
    assert!(choices.columns[0].operators.contains(&FilterOpTag::Between));
    assert!(!choices.columns[0].operators.contains(&FilterOpTag::Contains));
    assert!(choices.columns[1].operators.contains(&FilterOpTag::Contains));
    assert_eq!(choices.combinators, [CombinatorTag::And, CombinatorTag::Or]);
    assert!(choices.accepts_raw_sql);
}

#[tokio::test]
async fn a_tables_structure_lists_its_columns_index_foreign_key_and_create_text() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), LEAGUE).await;

    let players = session
        .table_structure(table("players"), ObjectKindTag::Table, None)
        .await
        .unwrap();
    let view = session
        .table_structure(table("top_players"), ObjectKindTag::View, None)
        .await
        .unwrap();
    // A tab restored from a session saved before tabs kept their kind says Table for every object. The fixture
    // made its objects after the session read the catalog, so it is read again, as the tree reads it.
    session
        .refresh_objects(ObjectScopeArg::DefaultSchema, None)
        .await
        .unwrap();
    let view_as_table = session
        .table_structure(table("top_players"), ObjectKindTag::Table, None)
        .await
        .unwrap();
    let in_schema = TableName {
        schema: Some("main".to_owned()),
        name: "top_players".to_owned(),
    };
    let view_in_schema = session
        .table_structure(in_schema, ObjectKindTag::Table, None)
        .await
        .unwrap();
    session.close().await.unwrap();

    let names: Vec<&str> = players.columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(names, ["id", "team_id", "name", "score"]);
    assert!(players.columns[0].primary_key);
    assert!(!players.columns[2].nullable);
    assert_eq!(players.columns[2].default_value.as_deref(), Some("'anon'"));
    assert_eq!(players.columns[3].default_value, None);
    let index = players
        .indexes
        .iter()
        .find(|index| index.name == "players_by_score")
        .unwrap();
    assert_eq!(index.keys, ["score DESC", "name"]);
    assert!(!index.unique && !index.primary);
    let [key] = players.foreign_keys.as_slice() else {
        unreachable!("one foreign key: {:?}", players.foreign_keys)
    };
    assert_eq!(key.columns, ["team_id"]);
    assert_eq!(key.ref_table, "teams");
    assert_eq!(key.ref_columns, ["id"]);
    assert_eq!(key.on_delete.as_deref(), Some("CASCADE"));
    let ddl = players.ddl.unwrap();
    assert!(ddl.contains("CREATE TABLE"), "{ddl}");
    assert!(ddl.contains("players_by_score"), "{ddl}");
    let view_names: Vec<&str> = view.columns.iter().map(|column| column.name.as_str()).collect();
    assert_eq!(view_names, ["name", "score"]);
    assert_eq!(view.ddl, None, "a view is not made by CREATE TABLE");
    assert_eq!(view_as_table.ddl, None, "the catalog's kind wins over the app's");
    assert_eq!(
        view_in_schema.ddl, None,
        "a schema the table names is the catalog's scope"
    );
}

#[tokio::test]
async fn a_trigger_reads_back_and_a_function_is_unsupported_on_sqlite() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), LEAGUE).await;
    let entry = |name: &str, kind| ObjectEntry {
        schema: None,
        name: name.to_owned(),
        kind,
        parent_table: None,
    };

    let objects = session
        .refresh_objects(ObjectScopeArg::DefaultSchema, None)
        .await
        .unwrap();
    let trigger = objects
        .iter()
        .find(|object| object.kind == ObjectKindTag::Trigger)
        .unwrap()
        .clone();
    let source = session.object_definition(trigger.clone(), None).await.unwrap().unwrap();
    let function = session
        .object_definition(entry("total", ObjectKindTag::Function), None)
        .await
        .unwrap_err();
    let key = session
        .object_definition(entry("total", ObjectKindTag::Key), None)
        .await
        .unwrap_err();
    session.close().await.unwrap();

    assert_eq!(trigger.name, "players_scored");
    assert_eq!(trigger.parent_table.as_deref(), Some("players"));
    assert!(source.sql.contains("CREATE TRIGGER"), "{}", source.sql);
    assert!(source.sql.contains("players_scored"), "{}", source.sql);
    assert!(source.opens_in_editor);
    assert_eq!(source.database, None);
    let CoreError::Failed { info } = function else {
        unreachable!("a function was read: {function:?}")
    };
    assert_eq!(info.codes, ["operation.driver", "driver.unsupported"]);
    assert_eq!(key.code(), "ffi.no_definition");
}

#[tokio::test]
async fn an_editor_moves_to_a_database_only_where_the_engine_switches_one() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), PEOPLE).await;
    let editor = session.open_editor(None).await.unwrap();

    // SQLite binds its database to the file it opened, so a definition from elsewhere cannot run there.
    let refused = editor.use_database("shop".to_owned(), None).await.unwrap_err();
    editor.close().await.unwrap();
    session.close().await.unwrap();

    assert_eq!(refused.code(), "driver.unsupported");
}

const REFERENCES: &str = "CREATE TABLE parent (code TEXT NOT NULL, region INTEGER NOT NULL, \
    PRIMARY KEY (code, region)); \
    CREATE TABLE child (id INTEGER PRIMARY KEY, parent_code TEXT, parent_region INTEGER, \
    FOREIGN KEY (parent_code, parent_region) REFERENCES parent(code, region)); \
    INSERT INTO parent VALUES ('x'' OR 1=1 --', 7), ('x'' OR 1=1 --', 8), ('', 9); \
    INSERT INTO child VALUES (1, 'x'' OR 1=1 --', 7), (2, 'x'' OR 1=1 --', 8), (3, NULL, 7), (4, '', 9)";

async fn page_rows(
    session: &DatabaseSession,
    name: &str,
    filter: Option<TableFilterArg>,
) -> Arc<tablepro_ffi::ResultSet> {
    let page = session
        .read_table_page(table(name), None, filter, 100, 0, Box::new(Quiet), None)
        .await
        .unwrap();
    let outcome = page.run().outcome().await.unwrap();
    assert!(matches!(outcome, RunOutcome::Completed { .. }), "{outcome:?}");
    page.run().result_set(0).unwrap()
}

fn followed(
    keys: &tablepro_ffi::TableKeys,
    rows: Arc<tablepro_ffi::ResultSet>,
    row: u64,
    choice: &RowReferenceChoice,
) -> FollowedReference {
    keys.follow_reference(rows, row, choice.referencing, choice.key)
        .unwrap()
}

// None for a refusal, which the test unwraps.
fn filter_of(followed: FollowedReference) -> Option<(TableName, TableFilterArg)> {
    match followed {
        FollowedReference::Rows { table, filter } => Some((table, filter)),
        FollowedReference::Refused { .. } => None,
    }
}

#[tokio::test]
async fn a_composite_key_leads_to_its_row_and_back_with_every_value_bound() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), REFERENCES).await;
    let children = page_rows(&session, "child", None).await;
    let keys = session.table_keys(table("child"), None).await.unwrap();

    let from_child = keys
        .row_references(children.clone(), 0, Some("parent_region".to_owned()))
        .unwrap();
    let [choice] = from_child.referenced.as_slice() else {
        panic!("one composite key: {from_child:?}")
    };
    assert_eq!(choice.table, table("parent"));
    assert_eq!(choice.columns, ["parent_code", "parent_region"]);
    assert!(!choice.referencing);
    assert!(from_child.referencing.is_empty());
    assert!(
        keys.row_references(children.clone(), 0, Some("id".to_owned()))
            .unwrap()
            .referenced
            .is_empty(),
        "a column outside the key offers it not"
    );
    let (target, filter) = filter_of(followed(&keys, children, 0, choice)).unwrap();
    assert_eq!(target, table("parent"));
    assert_eq!(filter.combinator, CombinatorTag::And);
    assert_eq!(filter.raw_sql, None);
    assert_eq!(
        filter.rules,
        [
            rule("code", FilterOpTag::Eq, Some("x' OR 1=1 --")),
            rule("region", FilterOpTag::Eq, Some("7")),
        ]
    );

    let parents = page_rows(&session, "parent", Some(filter)).await;
    assert_eq!(parents.row_count(), 1);
    let parent_keys = session.table_keys(table("parent"), None).await.unwrap();
    let back = parent_keys.row_references(parents.clone(), 0, None).unwrap();
    assert!(back.referenced.is_empty());
    let [incoming] = back.referencing.as_slice() else {
        panic!("one key points at parent: {back:?}")
    };
    assert_eq!(incoming.table, table("child"));
    assert_eq!(incoming.columns, ["parent_code", "parent_region"]);
    let (_, filter) = filter_of(followed(&parent_keys, parents, 0, incoming)).unwrap();
    let child = session
        .read_table_page(table("child"), None, Some(filter), 100, 0, Box::new(Quiet), None)
        .await
        .unwrap();
    assert_eq!(column(&child, 0).await, texts(&["1"]));
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_null_part_leads_nowhere_an_empty_text_is_a_value_and_a_sorted_set_reads_its_own_row() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(dir.path(), REFERENCES).await;
    let children = page_rows(&session, "child", None).await;
    let keys = session.table_keys(table("child"), None).await.unwrap();

    assert!(
        keys.row_references(children.clone(), 2, None)
            .unwrap()
            .referenced
            .is_empty()
    );
    // Descending by id, so the sorted set's first row is the last one read.
    let sorted = children.sorted(0, false).unwrap();
    let first = keys.row_references(sorted.clone(), 0, None).unwrap();
    let (_, filter) = filter_of(followed(&keys, sorted, 0, &first.referenced[0])).unwrap();
    assert_eq!(filter.rules[0], rule("code", FilterOpTag::Eq, Some("")));
    assert_eq!(
        keys.row_references(children.clone(), 99, None).unwrap_err().code(),
        "ffi.out_of_range"
    );
    assert_eq!(
        keys.follow_reference(children.clone(), 2, false, 0).unwrap_err().code(),
        "ffi.out_of_range",
        "a key the row holds NULL in was never offered"
    );
    assert_eq!(
        keys.follow_reference(children, 0, true, 5).unwrap_err().code(),
        "ffi.out_of_range"
    );
    session.close().await.unwrap();
}

#[tokio::test]
async fn keys_that_compare_otherwise_or_hold_an_inexact_or_long_value_are_offered_and_refused() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(
        dir.path(),
        "CREATE TABLE parent (code TEXT COLLATE NOCASE PRIMARY KEY); \
         CREATE TABLE child (code TEXT REFERENCES parent(code)); \
         CREATE TABLE scale (weight REAL PRIMARY KEY); \
         CREATE TABLE measured (id INTEGER PRIMARY KEY, weight REAL REFERENCES scale(weight)); \
         CREATE TABLE big (code TEXT PRIMARY KEY); CREATE TABLE small (code TEXT REFERENCES big(code)); \
         INSERT INTO parent VALUES ('ABC'); INSERT INTO child VALUES ('abc'); \
         INSERT INTO scale VALUES (0.5); INSERT INTO measured VALUES (1, 0.5); \
         INSERT INTO big VALUES (printf('%.9000c', 'x')); INSERT INTO small SELECT code FROM big",
    )
    .await;
    let refusal = |table_name: &'static str, column: Option<&'static str>| {
        let session = session.clone();
        async move {
            let rows = page_rows(&session, table_name, None).await;
            let keys = session.table_keys(table(table_name), None).await.unwrap();
            let references = keys.row_references(rows.clone(), 0, column.map(str::to_owned)).unwrap();
            let choice = references
                .referenced
                .first()
                .or(references.referencing.first())
                .unwrap()
                .clone();
            match followed(&keys, rows, 0, &choice) {
                FollowedReference::Refused { refusal } => refusal,
                rows => panic!("followed: {rows:?}"),
            }
        }
    };

    assert_eq!(
        refusal("parent", None).await,
        ReferenceRefusal::ComparedOtherwise {
            table: "child".to_owned()
        }
    );
    assert_eq!(
        refusal("measured", Some("weight")).await,
        ReferenceRefusal::NoFilterText {
            column: "weight".to_owned()
        }
    );
    assert_eq!(
        refusal("big", None).await,
        ReferenceRefusal::NoFilterText {
            column: "code".to_owned()
        },
        "a key too long to filter on is refused before it is copied"
    );
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_menu_lists_at_most_64_keys_each_way() {
    let dir = tempfile::tempdir().unwrap();
    let children: String = (0..70)
        .map(|index| format!("CREATE TABLE child_{index} (code TEXT REFERENCES parent(code)); "))
        .collect();
    let (_core, session) = fixture(
        dir.path(),
        &format!("CREATE TABLE parent (code TEXT PRIMARY KEY); {children} INSERT INTO parent VALUES ('a')"),
    )
    .await;
    let parents = page_rows(&session, "parent", None).await;

    let references = session
        .table_keys(table("parent"), None)
        .await
        .unwrap()
        .row_references(parents, 0, None)
        .unwrap();

    assert_eq!(references.referencing.len(), 64);
    session.close().await.unwrap();
}

#[tokio::test]
async fn a_cell_reads_its_start_and_a_binary_cell_its_first_bytes_with_its_length() {
    let dir = tempfile::tempdir().unwrap();
    let (_core, session) = fixture(
        dir.path(),
        "CREATE TABLE files (id INTEGER PRIMARY KEY, body BLOB, note TEXT); \
         INSERT INTO files VALUES (1, X'89504E47', 'line one' || char(10) || 'line two'), (2, NULL, NULL)",
    )
    .await;
    let rows = page_rows(&session, "files", None).await;

    let whole = rows.cell_bytes(0, 1, 100).unwrap().unwrap();
    assert_eq!((whole.bytes, whole.length), (vec![0x89, 0x50, 0x4e, 0x47], 4));
    let first = rows.cell_bytes(0, 1, 2).unwrap().unwrap();
    assert_eq!((first.bytes, first.length), (vec![0x89, 0x50], 4));
    assert_eq!(rows.cell_bytes(0, 2, 100).unwrap(), None);
    assert_eq!(rows.cell_bytes(1, 1, 100).unwrap(), None);
    assert_eq!(rows.cell_bytes(5, 1, 100).unwrap_err().code(), "ffi.out_of_range");

    let note = rows.cell_text_head(0, 2, 100).unwrap().unwrap();
    assert_eq!((note.text.as_str(), note.cut), ("line one\nline two", false));
    let cut = rows.cell_text_head(0, 2, 4).unwrap().unwrap();
    assert_eq!((cut.text.as_str(), cut.cut), ("line", true));
    let hex = rows.cell_text_head(0, 1, 6).unwrap().unwrap();
    assert_eq!((hex.text.as_str(), hex.cut), ("0x8950", true));
    assert_eq!(rows.cell_text_head(1, 2, 100).unwrap(), None);
    session.close().await.unwrap();
}
