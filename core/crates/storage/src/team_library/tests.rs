#![expect(
    clippy::disallowed_types,
    reason = "JSON in a test is written with json!; its key order means nothing to the store"
)]

use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::journal::recording::Recording;
use crate::store_identity::StoreContinuity;

fn paths(root: &tempfile::TempDir) -> StoragePaths {
    StoragePaths::under(root.path(), "tablepro", "app.tablepro.TablePro")
}

fn owner(origin: &str, account: &str) -> TeamLibraryOwner {
    TeamLibraryOwner {
        origin: origin.to_owned(),
        account_id: account.to_owned(),
    }
}

fn item(kind: TeamLibraryKind, id: &str, name: &str) -> TeamLibraryItem {
    TeamLibraryItem {
        kind,
        id: id.to_owned(),
        fields: json!({"name": name}),
    }
}

#[test]
fn each_origin_and_account_has_a_store_of_its_own() {
    let root = tempfile::tempdir().expect("tempdir");
    let mine = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "acct_1"));
    let other_account = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "acct_2"));
    let other_server = TeamLibraryStore::new(&paths(&root), owner("https://sync.example.com/v2", "acct_1"));

    mine.put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "Revenue")])
        .expect("put");

    assert_eq!(mine.teams_blocking().expect("teams").len(), 1);
    assert!(other_account.teams_blocking().expect("teams").is_empty());
    assert!(other_server.teams_blocking().expect("teams").is_empty());
    assert_ne!(mine.path(), other_account.path());
    assert_ne!(mine.path(), other_server.path());
}

#[test]
fn a_file_of_another_account_is_refused_for_reads_and_writes() {
    let root = tempfile::tempdir().expect("tempdir");
    let theirs = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "acct_2"));
    theirs
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Folder, "f1", "Shared")])
        .expect("put");
    let mine = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "acct_1"));
    std::fs::create_dir_all(mine.path().parent().expect("parent")).expect("dir");
    std::fs::copy(theirs.path(), mine.path()).expect("copied over");
    let before = std::fs::read(mine.path()).expect("read");

    assert!(matches!(
        mine.teams_blocking(),
        Err(StorageError::StoreOwnerMismatch { .. })
    ));
    assert!(matches!(
        mine.put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q", "x")]),
        Err(StorageError::StoreOwnerMismatch { .. })
    ));
    assert_eq!(std::fs::read(mine.path()).expect("read"), before);
}

#[test]
fn the_file_name_is_a_digest_whatever_id_the_server_chose() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "../../escape"));

    let name = store.path().file_name().and_then(|name| name.to_str()).expect("a name");

    assert_eq!(
        store.path().parent(),
        Some(paths(&root).state.join("team-library").as_path())
    );
    assert_eq!(name.len(), 64 + ".json".len());
    assert!(name.trim_end_matches(".json").chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn an_item_is_replaced_by_its_exact_id_and_case() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("https://api.tablepro.app/v2", "acct_1"));

    store
        .put_items_blocking(
            "team_a",
            vec![
                item(
                    TeamLibraryKind::Connection,
                    "6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44",
                    "prod",
                ),
                item(
                    TeamLibraryKind::Connection,
                    "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44",
                    "upper",
                ),
            ],
        )
        .expect("put");
    store
        .put_items_blocking(
            "team_a",
            vec![item(
                TeamLibraryKind::Connection,
                "6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44",
                "renamed",
            )],
        )
        .expect("replace");
    let team = store.team_blocking("team_a").expect("read").expect("the team");

    assert_eq!(team.items.len(), 2);
    assert_eq!(team.items[0].fields, json!({"name": "renamed"}));
    assert_eq!(team.items[1].fields, json!({"name": "upper"}));
}

#[test]
fn fields_must_be_an_object() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));

    let refused = store.put_items_blocking(
        "team_a",
        vec![TeamLibraryItem {
            kind: TeamLibraryKind::Query,
            id: "q".to_owned(),
            fields: json!(["not", "an", "object"]),
        }],
    );

    assert!(matches!(refused, Err(StorageError::Schema(_))));
}

#[test]
fn writes_raise_the_sequence_and_a_restore_starts_a_generation() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");
    let backup = std::fs::read(store.path()).expect("a backup");
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q2", "b")])
        .expect("put");
    let seen = store.identity_blocking().expect("identity").expect("stamped");

    std::fs::write(store.path(), &backup).expect("restored by hand");
    let older = store.identity_blocking().expect("identity").expect("stamped");
    let renewed = store.start_new_generation_blocking().expect("restored by the host");

    assert_eq!(seen.sequence, 2);
    assert_eq!(older.compared_with(seen), StoreContinuity::WentBack);
    assert_eq!(renewed.compared_with(seen), StoreContinuity::NewGeneration);
}

#[test]
fn each_write_tells_the_journal_the_library_kinds_it_changed() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    let journal = Arc::new(Recording::default());
    store.set_journal(Some(journal.clone()));

    store
        .put_items_blocking(
            "team_a",
            vec![
                item(TeamLibraryKind::Query, "q1", "a"),
                item(TeamLibraryKind::Folder, "f1", "b"),
            ],
        )
        .expect("put");
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("same item");
    store
        .remove_items_blocking("team_a", &[(TeamLibraryKind::Query, "q1".to_owned())])
        .expect("remove");
    store
        .put_items_blocking("team_b", vec![item(TeamLibraryKind::Connection, "c1", "c")])
        .expect("put");
    store.remove_team_blocking("team_b").expect("left the team");

    assert_eq!(
        journal.take(),
        vec![
            vec![RecordKind::LibraryFolder, RecordKind::LibraryQuery],
            vec![RecordKind::LibraryQuery],
            vec![RecordKind::LibraryConnection],
            vec![RecordKind::LibraryConnection],
        ]
    );
}

#[test]
fn signing_out_deletes_the_accounts_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");

    store.delete_blocking().expect("deleted");

    assert!(!store.path().exists());
    assert!(store.teams_blocking().expect("teams").is_empty());
}

#[test]
fn what_only_this_device_knows_of_a_team_outlives_its_items_and_tells_the_journal_nothing() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    let journal = Arc::new(Recording::default());
    store.set_journal(Some(journal.clone()));

    store
        .update_local_blocking("team_a", |local| {
            local.name = Some("Acme".to_owned());
            local.published.push(TeamLibraryRef {
                kind: TeamLibraryKind::Query,
                id: "Q1".to_owned(),
            });
        })
        .expect("local");
    let held = store.local_blocking("team_a").expect("read");
    let unknown = store.local_blocking("team_b").expect("read");
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");
    store.remove_team_blocking("team_a").expect("left the team");

    assert_eq!(held.name.as_deref(), Some("Acme"));
    assert!(held.published[0].names(TeamLibraryKind::Query, "q1"));
    assert!(!held.published[0].names(TeamLibraryKind::Folder, "q1"));
    assert_eq!(unknown.team_id, "team_b");
    assert!(unknown.published.is_empty());
    assert!(store.locals_blocking().expect("read").is_empty());
    assert_eq!(
        journal.take(),
        vec![vec![RecordKind::LibraryQuery], vec![RecordKind::LibraryQuery]]
    );
}

#[test]
fn a_delete_cut_off_after_its_mark_keeps_the_owner_s_file_unread_until_the_mark_clears() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");

    store.mark_deleting_blocking("db1").expect("marked");
    let reopened = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    let while_marked = reopened.teams_blocking();
    let write_while_marked = reopened.put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q2", "b")]);
    reopened.delete_blocking().expect("deleted");
    reopened.store_deleted_blocking().expect("settled");
    reopened.clear_deleting_blocking("db1").expect("cleared");

    assert!(matches!(while_marked, Err(StorageError::DeletePending { .. })));
    assert!(matches!(write_while_marked, Err(StorageError::DeletePending { .. })));
    assert!(!reopened.delete_pending_blocking());
    assert!(!reopened.path().exists());
    assert!(reopened.teams_blocking().expect("teams").is_empty());
}

// One marker per state database (K8t leftover): once the file is gone the owner reads again, and each database's
// marker stays for its own rows until that database clears it; one database never clears another's.
#[test]
fn each_state_database_keeps_its_own_delete_marker() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");

    store.mark_deleting_blocking("db1").expect("marked");
    store.mark_deleting_blocking("db2").expect("marked");
    store.delete_blocking().expect("deleted");
    let before_settled = store.delete_pending_blocking();
    store.store_deleted_blocking().expect("settled");
    let after_settled = store.delete_pending_blocking();
    store.clear_deleting_blocking("db1").expect("cleared");

    assert!(before_settled);
    assert!(!after_settled);
    assert!(!store.deleting_blocking("db1"));
    assert!(store.deleting_blocking("db2"));
    assert!(!store.delete_pending_blocking());
    assert!(store.teams_blocking().expect("teams").is_empty());
    assert!(store.mark_deleting_blocking("../db").is_err());
}

#[test]
fn a_delete_takes_the_copies_a_cut_off_write_left_beside_the_file() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");
    let name = store.path().file_name().expect("name").to_string_lossy().into_owned();
    let left = store.path().with_file_name(format!(".{name}.x1y2.tmp"));
    let other = store.path().with_file_name(".someone-else.json.x1y2.tmp");
    std::fs::write(&left, b"{\"teams\": []}").expect("left");
    std::fs::write(&other, b"{}").expect("other");

    store.delete_blocking().expect("deleted");

    assert!(!store.path().exists());
    assert!(!left.exists());
    assert!(other.exists());
}

#[test]
fn another_owner_s_file_goes_and_stays_unread_while_the_kept_owner_s_stays() {
    let root = tempfile::tempdir().expect("tempdir");
    let kept = owner("https://api.tablepro.app/v2", "acct_1");
    let mine = TeamLibraryStore::new(&paths(&root), kept.clone());
    let theirs = TeamLibraryStore::new(&paths(&root), owner("https://sync.example.com/v2", "acct_2"));
    for store in [&mine, &theirs] {
        store
            .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
            .expect("put");
    }
    std::fs::write(paths(&root).state.join("team-library").join("notes.txt"), b"x").expect("a stray file");

    delete_other_owners_blocking(&paths(&root), Some(&kept)).expect("deleted");

    assert_eq!(mine.teams_blocking().expect("teams").len(), 1);
    assert!(!theirs.path().exists());
    assert!(theirs.delete_pending_blocking());
    assert!(matches!(
        theirs.teams_blocking(),
        Err(StorageError::DeletePending { .. })
    ));
    assert!(paths(&root).state.join("team-library").join("notes.txt").exists());

    delete_other_owners_blocking(&paths(&root), None).expect("deleted");

    assert!(!mine.path().exists());
    assert!(mine.delete_pending_blocking());
}

#[test]
fn another_owner_s_copy_a_first_write_left_without_its_file_goes_too() {
    let root = tempfile::tempdir().expect("tempdir");
    let theirs = TeamLibraryStore::new(&paths(&root), owner("https://sync.example.com/v2", "acct_2"));
    let name = theirs.path().file_name().expect("name").to_string_lossy().into_owned();
    let left = theirs.path().with_file_name(format!(".{name}.x1y2.tmp"));
    std::fs::create_dir_all(left.parent().expect("folder")).expect("folder");
    std::fs::write(&left, b"{\"teams\": []}").expect("left");

    delete_other_owners_blocking(&paths(&root), None).expect("deleted");

    assert!(!left.exists());
    assert!(theirs.delete_pending_blocking());
}

#[test]
fn an_item_s_writer_is_replaced_by_the_next_pull_and_goes_with_the_item() {
    let root = tempfile::tempdir().expect("tempdir");
    let store = TeamLibraryStore::new(&paths(&root), owner("o", "a"));
    let writer = |name: &str, at_ms| TeamLibraryWriter {
        kind: TeamLibraryKind::Query,
        id: "q1".to_owned(),
        name: Some(name.to_owned()),
        at_ms,
    };
    store
        .put_items_blocking("team_a", vec![item(TeamLibraryKind::Query, "q1", "a")])
        .expect("put");

    store
        .record_writers_blocking("team_a", vec![writer("Ada", 1)])
        .expect("writers");
    store
        .record_writers_blocking("team_a", vec![writer("Grace", 2)])
        .expect("writers");
    let held = store.local_blocking("team_a").expect("read").writers;
    store
        .remove_items_blocking("team_a", &[(TeamLibraryKind::Query, "q1".to_owned())])
        .expect("remove");

    assert_eq!(held, [writer("Grace", 2)]);
    assert!(store.local_blocking("team_a").expect("read").writers.is_empty());
}
