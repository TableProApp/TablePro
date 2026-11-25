use std::time::Duration;

use super::*;
use crate::{QueryHistory, StoragePaths};

async fn history(root: &tempfile::TempDir) -> QueryHistory {
    QueryHistory::open(&StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro"))
        .await
        .expect("open")
}

fn at(millis: u64) -> SystemTime {
    SystemTime::UNIX_EPOCH + Duration::from_millis(millis)
}

fn id(text: &str) -> Uuid {
    Uuid::parse_str(text).expect("a UUID")
}

fn pulled(id: Uuid, name: &str, connection: Option<Uuid>, created_at: SystemTime) -> SavedQuery {
    SavedQuery {
        id,
        name: name.to_owned(),
        query: format!("SELECT '{name}'"),
        connection_id: connection,
        connection_name: String::new(),
        keyword: None,
        folder_id: None,
        order: 0,
        created_at,
        updated_at: created_at,
    }
}

fn pulled_folder(id: Uuid, name: &str, parent: Option<Uuid>, created_at: SystemTime) -> SavedQueryFolder {
    SavedQueryFolder {
        id,
        connection_id: None,
        name: name.to_owned(),
        parent_id: parent,
        order: 0,
        created_at,
        updated_at: created_at,
    }
}

async fn names(store: &SavedQueries) -> Vec<(Uuid, String)> {
    let mut held: Vec<(Uuid, String)> = store
        .list(None)
        .await
        .expect("list")
        .into_iter()
        .map(|query| (query.id, query.name))
        .collect();
    held.sort();
    held
}

#[tokio::test]
async fn a_pulled_query_keeps_its_id_and_fields_and_with_no_connection_shows_in_every_one() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let folder = Uuid::new_v4();
    let mut query = pulled(Uuid::new_v4(), "Daily", None, at(1_700_000_000_123));
    query.keyword = Some("dl".to_owned());
    query.folder_id = Some(folder);
    query.order = 7;
    query.updated_at = at(1_700_000_000_456);

    let settled = store.put(std::slice::from_ref(&query)).await.expect("put");

    assert!(settled.is_empty());
    assert_eq!(store.get(query.id).await.expect("get"), Some(query.clone()));
    for connection in [Uuid::new_v4(), Uuid::new_v4()] {
        let shown = store.snapshot(connection).await.expect("snapshot").queries;
        assert_eq!(shown, std::slice::from_ref(&query));
    }
}

#[tokio::test]
async fn the_query_created_first_keeps_the_name_and_the_other_takes_the_first_free_one() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let connection = Some(Uuid::new_v4());
    let local = pulled(Uuid::new_v4(), "Daily", connection, at(2_000));
    let taken = pulled(Uuid::new_v4(), "Daily (2)", connection, at(500));
    store.put(&[local.clone(), taken.clone()]).await.expect("local rows");

    let earlier = pulled(Uuid::new_v4(), "Daily", connection, at(1_000));
    assert_eq!(store.put(std::slice::from_ref(&earlier)).await.expect("put"), [local.id]);
    let later = pulled(Uuid::new_v4(), "Daily", connection, at(3_000));
    assert_eq!(store.put(std::slice::from_ref(&later)).await.expect("put"), [later.id]);
    let elsewhere = pulled(Uuid::new_v4(), "Daily", None, at(4_000));
    assert!(store.put(&[elsewhere.clone()]).await.expect("put").is_empty());

    let mut expected = vec![
        (earlier.id, "Daily".to_owned()),
        (taken.id, "Daily (2)".to_owned()),
        (local.id, "Daily (3)".to_owned()),
        (later.id, "Daily (4)".to_owned()),
        (elsewhere.id, "Daily".to_owned()),
    ];
    expected.sort();
    assert_eq!(names(&store).await, expected);
    let renamed = store.get(local.id).await.expect("get").expect("the local query");
    assert!(renamed.updated_at > at(2_000), "the rename is this device's own edit");
}

// 0052, Consequences: two records created in one second whose ids sort the other way.
#[tokio::test]
async fn records_created_in_one_second_are_ordered_by_their_milliseconds_then_by_id_bytes() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let connection = Some(Uuid::new_v4());
    let high = id("FFFFFFFF-0000-4000-8000-000000000001");
    let low = id("00000000-0000-4000-8000-000000000001");
    let tie = id("0000000A-0000-4000-8000-000000000001");

    let settled = store
        .put(&[
            pulled(low, "Report", connection, at(1_000_900)),
            pulled(high, "Report", connection, at(1_000_100)),
        ])
        .await
        .expect("put");
    assert_eq!(settled, [low]);
    let settled = store
        .put(&[pulled(tie, "Report", connection, at(1_000_100))])
        .await
        .expect("put");
    assert_eq!(settled, [high], "the lower id holds first at the same millisecond");

    let named = |id| {
        let store = store.clone();
        async move { store.get(id).await.expect("get").expect("query").name }
    };
    assert_eq!(named(tie).await, "Report");
    assert_eq!(named(high).await, "Report (3)");
    assert_eq!(named(low).await, "Report (2)");
}

#[tokio::test]
async fn one_batch_settles_the_same_way_in_any_order() {
    let ids = [Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4()];
    let records = |connection| {
        ids.iter()
            .enumerate()
            .map(|(index, id)| pulled(*id, "Same", connection, at(10 * (3 - index as u64))))
            .collect::<Vec<_>>()
    };
    let connection = Some(Uuid::new_v4());
    let mut outcomes = Vec::new();
    for reversed in [false, true] {
        let root = tempfile::tempdir().expect("tempdir");
        let store = history(&root).await.saved_queries();
        let mut batch = records(connection);
        if reversed {
            batch.reverse();
        }
        store.put(&batch).await.expect("put");
        outcomes.push(names(&store).await);
    }
    assert_eq!(outcomes[0], outcomes[1]);
    let named: std::collections::HashMap<Uuid, String> = outcomes[0].iter().cloned().collect();
    assert_eq!(
        [&named[&ids[2]], &named[&ids[1]], &named[&ids[0]]],
        ["Same", "Same (2)", "Same (3)"]
    );
}

#[tokio::test]
async fn a_keyword_is_settled_against_every_query_it_expands_beside() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let (first, second) = (Some(Uuid::new_v4()), Some(Uuid::new_v4()));
    let keyed = |name: &str, connection, created| {
        let mut query = pulled(Uuid::new_v4(), name, connection, at(created));
        query.keyword = Some("Rev".to_owned());
        query
    };
    let older = keyed("older", first, 1_000);
    let newer = keyed("newer", second, 3_000);
    store.put(&[older.clone(), newer.clone()]).await.expect("one keyword in two connections");

    let everywhere = keyed("everywhere", None, 2_000);
    assert_eq!(store.put(&[everywhere.clone()]).await.expect("put"), [everywhere.id]);
    let keyword = |id| {
        let store = store.clone();
        async move { store.get(id).await.expect("get").expect("query").keyword }
    };
    assert_eq!(keyword(everywhere.id).await, None);
    assert_eq!(keyword(newer.id).await.as_deref(), Some("Rev"));

    let mut first_of_all = keyed("first of all", None, 500);
    first_of_all.keyword = Some("rev".to_owned());
    let mut settled = store.put(&[first_of_all.clone()]).await.expect("put");
    settled.sort();
    let mut expected = vec![older.id, newer.id];
    expected.sort();
    assert_eq!(settled, expected, "a keyword with no connection takes it from every connection");
    assert_eq!(keyword(first_of_all.id).await.as_deref(), Some("rev"));
}

#[tokio::test]
async fn a_put_over_a_held_id_replaces_that_row_and_names_can_swap_in_one_batch() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let store = history.saved_queries();
    let connection = Some(Uuid::new_v4());
    let x = pulled(Uuid::new_v4(), "x", connection, at(1));
    let y = pulled(Uuid::new_v4(), "y", connection, at(2));
    store.put(&[x.clone(), y.clone()]).await.expect("put");
    let rowid = |id: Uuid| {
        let pool = store.pool.clone();
        async move {
            sqlx::query_scalar::<_, i64>("SELECT id FROM saved_queries WHERE record_id = ?")
                .bind(id.to_string())
                .fetch_one(&pool)
                .await
                .expect("rowid")
        }
    };
    let before = (rowid(x.id).await, rowid(y.id).await);

    let swapped = [
        SavedQuery {
            name: "y".to_owned(),
            ..x.clone()
        },
        SavedQuery {
            name: "x".to_owned(),
            ..y.clone()
        },
    ];
    assert!(store.put(&swapped).await.expect("swap").is_empty());

    assert_eq!((rowid(x.id).await, rowid(y.id).await), before, "the copies match rows by rowid");
    let mut expected = vec![(x.id, "y".to_owned()), (y.id, "x".to_owned())];
    expected.sort();
    assert_eq!(names(&store).await, expected);
}

#[tokio::test]
async fn a_record_listed_twice_is_written_once_as_its_last_version() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let first = pulled(Uuid::new_v4(), "first", None, at(1));
    let last = SavedQuery {
        name: "last".to_owned(),
        ..first.clone()
    };

    assert!(store.put(&[first, last.clone()]).await.expect("put").is_empty());

    assert_eq!(store.list(None).await.expect("list"), [last]);
}

#[tokio::test]
async fn a_pulled_query_that_breaks_the_stores_limits_writes_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let good = pulled(Uuid::new_v4(), "good", None, at(1));
    let blank = pulled(Uuid::new_v4(), "  ", None, at(1));

    assert!(matches!(
        store.put(&[good, blank]).await,
        Err(StorageError::EmptyName)
    ));
    assert!(store.list(None).await.expect("list").is_empty());
}

#[tokio::test]
async fn pulled_folders_settle_names_in_their_place_in_any_case() {
    let root = tempfile::tempdir().expect("tempdir");
    let folders = history(&root).await.saved_query_folders();
    let parent = Uuid::new_v4();
    let local = pulled_folder(Uuid::new_v4(), "Reports", None, at(2_000));
    let nested = pulled_folder(Uuid::new_v4(), "reports", Some(parent), at(500));
    folders.put(&[local.clone(), nested.clone()]).await.expect("local folders");

    let earlier = pulled_folder(Uuid::new_v4(), "REPORTS", None, at(1_000));
    assert_eq!(folders.put(&[earlier.clone()]).await.expect("put"), [local.id]);

    let shown = folders.list(Uuid::new_v4()).await.expect("list");
    let name = |id| shown.iter().find(|folder| folder.id == id).expect("folder").name.clone();
    assert_eq!(name(earlier.id), "REPORTS");
    assert_eq!(name(local.id), "Reports (2)");
    assert_eq!(name(nested.id), "reports", "another parent is another place");
}

#[tokio::test]
async fn a_pulled_folder_cycle_is_refused_and_a_missing_parent_is_kept() {
    let root = tempfile::tempdir().expect("tempdir");
    let folders = history(&root).await.saved_query_folders();
    let (a, b) = (Uuid::new_v4(), Uuid::new_v4());
    let missing = Uuid::new_v4();

    assert!(matches!(
        folders
            .put(&[
                pulled_folder(a, "A", Some(b), at(1)),
                pulled_folder(b, "B", Some(a), at(2))
            ])
            .await,
        Err(StorageError::FolderCycle { .. })
    ));
    folders
        .put(&[pulled_folder(a, "A", Some(missing), at(1))])
        .await
        .expect("a parent that has not arrived");
    assert_eq!(
        folders.list(Uuid::new_v4()).await.expect("list")[0].parent_id,
        Some(missing)
    );
}

#[tokio::test]
async fn a_query_with_no_connection_holds_its_own_names_and_its_keyword_everywhere() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = history(&root).await.saved_queries();
    let (first, second) = (Uuid::new_v4(), Uuid::new_v4());
    let new = |name: &str, connection| NewSavedQuery {
        name: name.to_owned(),
        query: "SELECT 1".to_owned(),
        connection_id: connection,
        connection_name: String::new(),
    };
    let everywhere = store.save(new("Daily", None)).await.expect("save").id;
    let scoped = store.save(new("Daily", Some(first))).await.expect("save");
    assert!(!scoped.replaced, "a connection's names are not those of no connection");
    let other = store.save(new("Other", Some(second))).await.expect("save").id;

    store
        .set_keyword(scoped.id, Some("rev"))
        .await
        .expect("a connection's keyword");
    store
        .set_keyword(other, Some("rev"))
        .await
        .expect("another connection may hold it");
    assert!(matches!(
        store.set_keyword(everywhere, Some("REV")).await,
        Err(StorageError::KeywordTaken)
    ));
    store.set_keyword(other, None).await.expect("clear");
    store.set_keyword(scoped.id, None).await.expect("clear");
    store
        .set_keyword(everywhere, Some("rev"))
        .await
        .expect("free everywhere");
    assert!(matches!(
        store.set_keyword(other, Some("Rev")).await,
        Err(StorageError::KeywordTaken)
    ));
    assert_eq!(store.snapshot(second).await.expect("snapshot").queries.len(), 2);
}

#[tokio::test]
async fn a_query_is_filed_only_in_a_folder_that_shows_wherever_it_does() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let (store, folders) = (history.saved_queries(), history.saved_query_folders());
    let connection = Uuid::new_v4();
    let scoped_folder = folders.create(Some(connection), "Mine", None).await.expect("folder");
    let shared_folder = folders.create(None, "Shared", None).await.expect("folder");
    let new = |name: &str, connection| NewSavedQuery {
        name: name.to_owned(),
        query: "SELECT 1".to_owned(),
        connection_id: connection,
        connection_name: String::new(),
    };
    let everywhere = store.save(new("Everywhere", None)).await.expect("save").id;
    let scoped = store.save(new("Scoped", Some(connection))).await.expect("save").id;

    assert!(matches!(
        store.move_to_folder(everywhere, Some(scoped_folder), None).await,
        Err(StorageError::NotFound)
    ));
    assert!(matches!(
        folders.create(None, "Inside", Some(scoped_folder)).await,
        Err(StorageError::NotFound)
    ));
    store
        .move_to_folder(everywhere, Some(shared_folder), None)
        .await
        .expect("shared into shared");
    store
        .move_to_folder(scoped, Some(shared_folder), Some(everywhere))
        .await
        .expect("scoped into shared, before a shared query");
    let filed: Vec<Uuid> = store
        .snapshot(connection)
        .await
        .expect("snapshot")
        .queries
        .into_iter()
        .filter(|query| query.folder_id == Some(shared_folder))
        .map(|query| query.id)
        .collect();
    assert_eq!(filed, [scoped, everywhere]);
}

#[tokio::test]
async fn deleting_a_connection_keeps_what_has_no_connection_and_unfiles_it() {
    let root = tempfile::tempdir().expect("tempdir");
    let history = history(&root).await;
    let (store, folders) = (history.saved_queries(), history.saved_query_folders());
    let connection = Uuid::new_v4();
    let going = folders.create(Some(connection), "Going", None).await.expect("folder");
    let mut shared = pulled(Uuid::new_v4(), "Shared", None, at(1));
    shared.folder_id = Some(going);
    store.put(&[shared.clone()]).await.expect("a pulled query in the folder");

    store.delete_for_connection(connection).await.expect("delete");

    let kept = store.get(shared.id).await.expect("get").expect("the shared query");
    assert_eq!(kept.folder_id, None);
    assert!(folders.list(connection).await.expect("list").is_empty());
}

#[tokio::test]
async fn a_shared_folder_lifted_out_of_a_deleted_connection_takes_a_free_name() {
    let root = tempfile::tempdir().expect("tempdir");
    let folders = history(&root).await.saved_query_folders();
    let connection = Uuid::new_v4();
    let going = folders.create(Some(connection), "Going", None).await.expect("folder");
    let also = folders.create(Some(connection), "Also going", None).await.expect("folder");
    folders.create(None, "Reports", None).await.expect("a shared folder");
    let inside = [
        pulled_folder(Uuid::new_v4(), "Reports", Some(going), at(1)),
        pulled_folder(Uuid::new_v4(), "reports", Some(also), at(2)),
    ];
    assert!(
        folders.put(&inside).await.expect("pulled into the going folders").is_empty(),
        "two parents are two places"
    );

    history(&root)
        .await
        .saved_queries()
        .delete_for_connection(connection)
        .await
        .expect("delete");

    let mut names: Vec<String> = folders
        .list(Uuid::new_v4())
        .await
        .expect("list")
        .into_iter()
        .map(|folder| folder.name)
        .collect();
    names.sort();
    assert_eq!(names, ["Reports", "Reports (2)", "reports (3)"], "in the order their parents were made");
}
