use serde_json::json;
use tablepro_records::Kind;
use tablepro_storage::TeamLibraryKind;
use tablepro_sync::api::control::{ConflictChoice, SyncControl};
use tablepro_sync::api::ids::RecordKey;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::team_library::{
    FacadeBase, ImportedEdit, TeamLibraryControl, TeamLibraryImport, TeamPublish, UnsentState,
};

use crate::support::{Mac, item, lower, query, query_fields, scope, server_fields, team, team_server};

fn edit(
    n: u128,
    version: Option<u64>,
    base: Option<serde_json::Value>,
    fields: Option<serde_json::Value>,
) -> ImportedEdit {
    ImportedEdit {
        item: item(TeamLibraryKind::Query, lower(n)),
        base: version.map(|version| FacadeBase { version, fields: base }),
        fields,
        moved: false,
    }
}

fn import(edits: Vec<ImportedEdit>) -> Vec<TeamLibraryImport> {
    vec![TeamLibraryImport {
        team: team(),
        edits,
        published: Vec::new(),
        declined: Vec::new(),
    }]
}

// The team holds query 3 at version 1, as 0.88 last pulled it, and someone renamed query 4 after 0.88 pulled it.
async fn team_with_history(server: &std::sync::Arc<tablepro_sync_testing::FakeServer>, dir: &std::path::Path) {
    let other = Mac::new(server, "dev_other", dir).await;
    other
        .device
        .sync
        .publish_team_saved_queries(
            team(),
            Vec::new(),
            vec![query(3, "Three", None), query(4, "Four", None)],
        )
        .await
        .unwrap();
    other
        .device
        .sync
        .publish_team_saved_queries(
            team(),
            Vec::new(),
            vec![query(3, "Three", None), query(4, "Four renamed", None)],
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn an_edit_on_the_version_the_team_holds_goes_up_and_one_the_team_changed_merges_or_asks() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let version_3 = server
        .stored(crate::support::owner(), "library_query", &lower(3))
        .unwrap()
        .version;
    let mut four_keyword = query_fields("Four", None);
    four_keyword["keyword"] = json!("k");

    mac.device
        .sync
        .import_team_library(import(vec![
            edit(
                3,
                Some(version_3),
                Some(query_fields("Three", None)),
                Some(query_fields("Three edited", None)),
            ),
            edit(4, Some(version_3), Some(query_fields("Four", None)), Some(four_keyword)),
            edit(5, None, None, Some(query_fields("Five", None))),
        ]))
        .await
        .unwrap();
    let waiting = mac.device.sync.unsent_team_edits().await.unwrap();
    mac.device.sync().await;
    mac.device.sync().await;

    assert!(waiting.iter().all(|edit| edit.state == UnsentState::Waiting));
    assert_eq!(waiting.len(), 3);
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)),
        Some(query_fields("Three edited", None))
    );
    let mut merged = query_fields("Four renamed", None);
    merged["keyword"] = json!("k");
    assert_eq!(server_fields(&server, "library_query", &lower(4)), Some(merged));
    assert_eq!(
        server_fields(&server, "library_query", &lower(5)),
        Some(query_fields("Five", None))
    );
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
}

#[tokio::test]
async fn an_edit_of_a_member_the_team_changed_since_asks_keep_mine_or_keep_theirs() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;

    mac.device
        .sync
        .import_team_library(import(vec![edit(
            4,
            Some(1),
            Some(query_fields("Four", None)),
            Some(query_fields("Four mine", None)),
        )]))
        .await
        .unwrap();
    mac.device.sync().await;
    let open = mac.device.sync.conflicts().await.unwrap();
    let listed = mac.device.sync.unsent_team_edits().await.unwrap();

    assert_eq!(open.len(), 1);
    assert_eq!(open[0].key, RecordKey::new(scope(), Kind::LibraryQuery, lower(4)));
    assert_eq!(open[0].fields, ["name"]);
    assert_eq!(listed[0].state, UnsentState::Conflict);
    assert_eq!(
        server_fields(&server, "library_query", &lower(4)),
        Some(query_fields("Four renamed", None))
    );
}

#[tokio::test]
async fn a_member_s_imported_edits_are_listed_as_refused_and_never_sent() {
    let server = team_server(Role::Member);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;

    mac.device
        .sync
        .import_team_library(import(vec![edit(5, None, None, Some(query_fields("Five", None)))]))
        .await
        .unwrap();
    mac.device.sync().await;
    let listed = mac.device.sync.unsent_team_edits().await.unwrap();
    mac.device.sync.discard_team_edits(None).await.unwrap();

    assert_eq!(
        listed[0].state,
        UnsentState::Refused {
            code: "sync.team_library.not_writable".to_owned()
        }
    );
    assert!(server_fields(&server, "library_query", &lower(5)).is_none());
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
}

#[tokio::test]
async fn what_0_88_published_stays_this_device_s_to_remove() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device
        .sync
        .import_team_library(vec![TeamLibraryImport {
            team: team(),
            edits: Vec::new(),
            published: vec![item(TeamLibraryKind::Query, lower(3).to_uppercase())],
            declined: Vec::new(),
        }])
        .await
        .unwrap();

    let removed = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(4, "Four renamed", None)])
        .await
        .unwrap();

    assert_eq!(
        removed,
        TeamPublish {
            edits: 1,
            ..TeamPublish::default()
        }
    );
    assert!(
        server
            .stored(crate::support::owner(), "library_query", &lower(3))
            .unwrap()
            .deleted
            .is_some()
    );
}

#[tokio::test]
async fn an_imported_delete_whose_base_0_88_did_not_keep_asks_and_still_asks_after_the_team_changes_it_again() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;

    mac.device
        .sync
        .import_team_library(import(vec![edit(4, Some(1), None, None)]))
        .await
        .unwrap();
    mac.device.sync().await;
    let open = mac.device.sync.conflicts().await.unwrap();
    let third = Mac::new(&server, "dev_third", dir.path()).await;
    third
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(4, "Four again", None)])
        .await
        .unwrap();
    mac.device.sync().await;
    let still = mac.device.sync.conflicts().await.unwrap();
    let key = RecordKey::new(scope(), Kind::LibraryQuery, lower(4));
    crate::support::resolve(&mac, key.clone(), ConflictChoice::KeepMine).await;
    mac.device.sync().await;

    assert_eq!(open.len(), 1);
    assert_eq!(open[0].key, key);
    assert_eq!(still.len(), 1);
    assert!(
        server
            .stored(crate::support::owner(), "library_query", &lower(4))
            .unwrap()
            .deleted
            .is_some()
    );
}

#[tokio::test]
async fn an_edit_on_the_version_number_the_team_holds_with_other_content_merges_instead_of_overwriting() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let version_4 = server
        .stored(crate::support::owner(), "library_query", &lower(4))
        .unwrap()
        .version;

    mac.device
        .sync
        .import_team_library(import(vec![edit(
            4,
            Some(version_4),
            Some(query_fields("Four", None)),
            Some(query_fields("Four mine", None)),
        )]))
        .await
        .unwrap();
    mac.device.sync().await;
    let open = mac.device.sync.conflicts().await.unwrap();

    assert_eq!(open.len(), 1);
    assert_eq!(
        server_fields(&server, "library_query", &lower(4)),
        Some(query_fields("Four renamed", None))
    );
}

#[tokio::test]
async fn an_import_the_merge_changed_is_still_this_device_s_to_remove() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    team_with_history(&server, dir.path()).await;
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let mut four_keyword = query_fields("Four", None);
    four_keyword["keyword"] = json!("k");
    mac.device
        .sync
        .import_team_library(import(vec![edit(
            4,
            Some(1),
            Some(query_fields("Four", None)),
            Some(four_keyword),
        )]))
        .await
        .unwrap();
    mac.device.sync().await;
    mac.device.sync().await;

    let removed = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), Vec::new())
        .await
        .unwrap();

    assert_eq!(removed.edits, 1);
    assert!(
        server
            .stored(crate::support::owner(), "library_query", &lower(4))
            .unwrap()
            .deleted
            .is_some()
    );
}
