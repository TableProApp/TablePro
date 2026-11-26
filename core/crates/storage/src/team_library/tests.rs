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
