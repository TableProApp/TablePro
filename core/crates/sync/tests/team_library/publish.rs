use serde_json::json;
use tablepro_records::Kind;
use tablepro_storage::TeamLibraryKind;
use tablepro_sync::api::control::{ConflictChoice, SyncControl};
use tablepro_sync::api::ids::RecordKey;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::team_library::{TeamConnection, TeamLibraryControl, TeamPublish};
use tablepro_sync_testing::FakeServer;

use crate::support::{
    Mac, folder, item, lower, owner, query, query_fields, scope, server_fields, team, team_server, uuid,
};

#[tokio::test]
async fn a_connection_goes_up_without_its_secrets_and_publishing_it_again_writes_nothing() {
    let server = team_server(Role::Editor);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let connection = TeamConnection {
        id: uuid(7),
        settings: json!({"name": "Prod", "host": "db", "password": "x", "sshConfig": {"host": "b", "keyPassphrase": "y"}}),
    };

    let first = mac
        .device
        .sync
        .publish_team_connections(team(), vec![connection.clone()])
        .await
        .unwrap();
    let again = mac
        .device
        .sync
        .publish_team_connections(team(), vec![connection])
        .await
        .unwrap();

    assert_eq!(
        first,
        TeamPublish {
            edits: 1,
            ..TeamPublish::default()
        }
    );
    assert_eq!(again, TeamPublish::default());
    assert_eq!(
        server_fields(&server, "library_connection", &lower(7)),
        Some(json!({"name": "Prod", "host": "db", "sshConfig": {"host": "b"}}))
    );
}

#[tokio::test]
async fn a_member_s_publish_is_refused_before_anything_is_written() {
    let server = team_server(Role::Member);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;

    let refused = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await;

    assert_eq!(refused.unwrap_err().code(), "sync.team_library.not_writable");
    assert!(mac.items(TeamLibraryKind::Query).is_empty());
}

#[tokio::test]
async fn once_the_sign_in_ends_a_publish_is_refused_and_queued_edits_stay_on_the_device() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device.wire.drop_next_push();
    let queued = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();

    mac.sign_out();
    let refused = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(4, "Other", None)])
        .await;
    let pass = mac.device.pass().await;

    assert_eq!(queued.unsent, 1);
    assert!(queued.problem.is_some());
    assert_eq!(refused.unwrap_err().code(), "sync.team_library.signed_in_changed");
    assert_eq!(pass.unwrap_err().code(), "sync.team_library.signed_in_changed");
    assert!(server.stored(owner(), "library_query", &lower(3)).is_none());
    assert_eq!(
        mac.device.sync.team_library().await.unwrap_err().code(),
        "sync.team_library.signed_in_changed"
    );
    assert_eq!(mac.device.sync.unsent_team_edits().await.unwrap().len(), 1);
}

// Another Mac of the team publishes what this one then removes and moves.
async fn published_by_both(server: &std::sync::Arc<FakeServer>, dir: &std::path::Path) -> (Mac, Mac) {
    let mac = Mac::new(server, "dev_mac", dir).await;
    let mini = Mac::new(server, "dev_mini", dir).await;
    mac.device
        .sync
        .publish_team_saved_queries(
            team(),
            vec![folder(1, "Top", None), folder(2, "Mine", Some(1))],
            vec![query(3, "Mine too", Some(2))],
        )
        .await
        .unwrap();
    mini.device.sync().await;
    mini.device
        .sync
        .publish_team_saved_queries(
            team(),
            vec![folder(1, "Top", None), folder(2, "Mine", Some(1))],
            vec![query(4, "Theirs", Some(2))],
        )
        .await
        .unwrap();
    (mac, mini)
}

#[tokio::test]
async fn removing_a_published_folder_moves_what_others_keep_in_it_and_leaves_that_theirs() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, _mini) = published_by_both(&server, dir.path()).await;
    let theirs_before = server_fields(&server, "library_query", &lower(4));

    let removed = mac
        .device
        .sync
        .publish_team_saved_queries(team(), vec![folder(1, "Top", None)], Vec::new())
        .await
        .unwrap();
    let again = mac
        .device
        .sync
        .publish_team_saved_queries(team(), vec![folder(1, "Top", None)], Vec::new())
        .await
        .unwrap();

    assert!(theirs_before.is_some());
    assert_eq!(removed.edits, 3);
    assert!(
        server
            .stored(owner(), "library_folder", &lower(2))
            .unwrap()
            .deleted
            .is_some()
    );
    assert!(
        server
            .stored(owner(), "library_query", &lower(3))
            .unwrap()
            .deleted
            .is_some()
    );
    assert_eq!(
        server_fields(&server, "library_query", &lower(4)),
        Some(query_fields("Theirs", Some(lower(1))))
    );
    assert_eq!(again, TeamPublish::default());
}

// Team Library runs on a Mac whose personal provider is iCloud or Off, where the service carries the teams only:
// its publish goes up and another member's edit comes down (K8's teams-only mode).
#[tokio::test]
async fn team_library_runs_on_a_mac_whose_personal_provider_is_icloud_or_off() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::teams_only(&server, "dev_mac", dir.path()).await;
    let mini = Mac::new(&server, "dev_mini", dir.path()).await;

    let published = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "From iCloud", None)])
        .await
        .unwrap();
    mini.device.sync().await;
    mini.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(4, "From the service", None)])
        .await
        .unwrap();
    mac.device.sync().await;

    assert_eq!(published.edits, 1);
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)),
        Some(query_fields("From iCloud", None))
    );
    assert!(mac.items(TeamLibraryKind::Query).iter().any(|(id, _)| *id == lower(4)));
    assert_eq!(mac.device.sync.mode(), tablepro_sync::service::ServiceMode::TeamsOnly);
}

// The query moved out of a folder lands before the folder's deletion, so a server that deletes what a folder holds
// never takes the query with it (K8t leftover, push order).
#[tokio::test]
async fn a_folder_deletion_goes_up_after_the_queries_moved_out_of_it() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, _mini) = published_by_both(&server, dir.path()).await;

    mac.device
        .sync
        .publish_team_saved_queries(team(), vec![folder(1, "Top", None)], Vec::new())
        .await
        .unwrap();

    let moved = server.stored(owner(), "library_query", &lower(4)).unwrap();
    let gone = server.stored(owner(), "library_folder", &lower(2)).unwrap();
    assert!(gone.deleted.is_some());
    assert!(
        moved.revision < gone.revision,
        "{} then {}",
        moved.revision,
        gone.revision
    );
}

#[tokio::test]
async fn an_item_the_team_deleted_asks_and_keep_mine_brings_it_back() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, mini) = published_by_both(&server, dir.path()).await;
    mini.device.sync().await;
    mini.device
        .sync
        .remove_team_items(team(), vec![item(TeamLibraryKind::Query, lower(3))])
        .await
        .unwrap();

    let asked = mac
        .device
        .sync
        .publish_team_saved_queries(
            team(),
            vec![folder(1, "Top", None), folder(2, "Mine", Some(1))],
            vec![query(3, "Mine too", Some(2))],
        )
        .await
        .unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));
    crate::support::resolve(&mac, key, ConflictChoice::KeepMine).await;
    mac.device.sync().await;

    assert_eq!((asked.edits, asked.conflicts), (1, 1));
    let back = server.stored(owner(), "library_query", &lower(3)).unwrap();
    assert!(back.deleted.is_none());
    assert_eq!(back.fields, Some(query_fields("Mine too", Some(lower(2)))));
}

#[tokio::test]
async fn keep_theirs_leaves_the_team_s_copy_on_later_publishes_until_the_copy_here_changes() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, mini) = published_by_both(&server, dir.path()).await;
    let folders = vec![folder(1, "Top", None), folder(2, "Mine", Some(1))];
    let mine = vec![query(3, "Renamed here", Some(2))];
    mac.device.wire.drop_next_push();
    mac.device
        .sync
        .publish_team_saved_queries(team(), folders.clone(), mine.clone())
        .await
        .unwrap();
    mini.device.sync().await;
    mini.device
        .sync
        .publish_team_saved_queries(
            team(),
            folders.clone(),
            vec![query(3, "Renamed there", Some(2)), query(4, "Theirs", Some(2))],
        )
        .await
        .unwrap();
    mac.device.sync().await;
    let open = mac.device.sync.conflicts().await.unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));
    crate::support::resolve(&mac, key, ConflictChoice::KeepTheirs).await;

    let held = mac
        .device
        .sync
        .publish_team_saved_queries(team(), folders.clone(), mine)
        .await
        .unwrap();
    let changed = mac
        .device
        .sync
        .publish_team_saved_queries(team(), folders, vec![query(3, "Renamed again", Some(2))])
        .await
        .unwrap();

    assert_eq!(open.len(), 1);
    assert_eq!(open[0].fields, ["name"]);
    assert_eq!(held, TeamPublish::default());
    assert_eq!(changed.edits, 1);
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)).unwrap()["name"],
        json!("Renamed again")
    );
}

#[tokio::test]
async fn each_item_names_who_last_changed_it_as_the_server_names_them() {
    let server = team_server(Role::Owner);
    server.name_writer(crate::harness::account(), "Ada Lovelace");
    let dir = tempfile::tempdir().unwrap();
    let mini = Mac::new(&server, "dev_mini", dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mini.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();

    mac.device.sync().await;
    let teams = mac.device.sync.team_library().await.unwrap();

    let item = &teams[0].items[0];
    assert_eq!(item.item.id, lower(3));
    assert_eq!(item.updated_by.as_deref(), Some("Ada Lovelace"));
    assert!(item.updated_at_ms.is_some_and(|at| at > 0));
}

#[tokio::test]
async fn a_server_the_managed_policy_no_longer_allows_takes_no_publish_and_nothing_is_written() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.policy_allows.store(false, std::sync::atomic::Ordering::SeqCst);

    let refused = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await;

    assert_eq!(refused.unwrap_err().code(), "sync.not_allowed");
    assert!(mac.items(TeamLibraryKind::Query).is_empty());
    assert!(server.stored(owner(), "library_query", &lower(3)).is_none());
}

// This Mac's rename waits in a conflict against the one another Mac made.
async fn conflicted(server: &std::sync::Arc<FakeServer>, dir: &std::path::Path) -> (Mac, Mac) {
    let (mac, mini) = published_by_both(server, dir).await;
    let folders = vec![folder(1, "Top", None), folder(2, "Mine", Some(1))];
    mac.device.wire.drop_next_push();
    mac.device
        .sync
        .publish_team_saved_queries(team(), folders.clone(), vec![query(3, "Renamed here", Some(2))])
        .await
        .unwrap();
    mini.device.sync().await;
    mini.device
        .sync
        .publish_team_saved_queries(
            team(),
            folders,
            vec![query(3, "Renamed there", Some(2)), query(4, "Theirs", Some(2))],
        )
        .await
        .unwrap();
    mac.device.sync().await;
    (mac, mini)
}

#[tokio::test]
async fn a_publish_while_a_conflict_is_open_becomes_its_side_so_keep_mine_sends_the_newer_copy() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, _mini) = conflicted(&server, dir.path()).await;
    let before = mac.device.sync.conflicts().await.unwrap();

    let newer = mac
        .device
        .sync
        .publish_team_saved_queries(
            team(),
            vec![folder(1, "Top", None), folder(2, "Mine", Some(1))],
            vec![query(3, "Renamed newer", Some(2))],
        )
        .await
        .unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));
    let stale = mac
        .device
        .sync
        .resolve_conflict(key.clone(), before[0].digest, ConflictChoice::KeepMine)
        .await;
    crate::support::resolve(&mac, key, ConflictChoice::KeepMine).await;
    mac.device.sync().await;

    assert_eq!(before.len(), 1);
    assert_eq!((newer.edits, newer.conflicts), (1, 1));
    assert_eq!(stale.unwrap_err().code(), "sync.changed");
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)).unwrap()["name"],
        json!("Renamed newer")
    );
}

#[tokio::test]
async fn keep_mine_needs_the_sign_in_the_edit_was_made_in_and_keep_theirs_does_not() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, _mini) = conflicted(&server, dir.path()).await;
    let open = mac.device.sync.conflicts().await.unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));

    mac.sign_out();
    let mine = mac
        .device
        .sync
        .resolve_conflict(key.clone(), open[0].digest, ConflictChoice::KeepMine)
        .await;
    let theirs = mac
        .device
        .sync
        .resolve_conflict(key, open[0].digest, ConflictChoice::KeepTheirs)
        .await;

    assert_eq!(mine.unwrap_err().code(), "sync.team_library.signed_in_changed");
    assert!(theirs.is_ok());
    assert!(mac.device.sync.conflicts().await.unwrap().is_empty());
}

#[tokio::test]
async fn an_item_the_team_deleted_and_someone_brought_back_is_no_longer_this_device_s_to_remove() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let mini = Mac::new(&server, "dev_mini", dir.path()).await;
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();
    mini.device.sync().await;
    mini.device
        .sync
        .remove_team_items(team(), vec![item(TeamLibraryKind::Query, lower(3))])
        .await
        .unwrap();
    mac.device.sync().await;
    mini.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Back", None)])
        .await
        .unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));
    crate::support::resolve(&mini, key, ConflictChoice::KeepMine).await;
    mini.device.sync().await;
    mac.device.sync().await;

    let removed = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), Vec::new())
        .await
        .unwrap();

    assert_eq!(removed, TeamPublish::default());
    let back = server.stored(owner(), "library_query", &lower(3)).unwrap();
    assert!(back.deleted.is_none());
    assert_eq!(back.fields, Some(query_fields("Back", None)));
}

#[tokio::test]
async fn republishing_the_copy_both_started_from_during_a_conflict_and_keeping_theirs_sends_nothing() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let (mac, _mini) = conflicted(&server, dir.path()).await;

    mac.device
        .sync
        .publish_team_saved_queries(
            team(),
            vec![folder(1, "Top", None), folder(2, "Mine", Some(1))],
            vec![query(3, "Mine too", Some(2))],
        )
        .await
        .unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(3));
    crate::support::resolve(&mac, key, ConflictChoice::KeepTheirs).await;
    mac.device.sync().await;

    assert_eq!(
        server_fields(&server, "library_query", &lower(3)).unwrap()["name"],
        json!("Renamed there")
    );
    let held = mac.items(TeamLibraryKind::Query);
    let here = held.iter().find(|(id, _)| *id == lower(3)).unwrap();
    assert_eq!(here.1["name"], json!("Renamed there"));
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
}
