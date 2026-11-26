use tablepro_storage::TeamLibraryKind;
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::team_library::{TeamLibraryControl, UnsentState};

use crate::support::{Mac, item, lower, owner, query, query_fields, server_fields, team, team_server};

#[tokio::test]
async fn an_edit_that_could_not_go_up_survives_a_quit_and_goes_up_after_it() {
    let server = team_server(Role::Editor);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device.wire.drop_next_push();
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();
    let before = mac.device.sync.unsent_team_edits().await.unwrap();

    let mac = mac.reopen(&server, "dev_mac", dir.path()).await;
    let after_quit = mac.device.sync.unsent_team_edits().await.unwrap();
    mac.device.sync().await;

    assert_eq!(before.len(), 1);
    assert_eq!(before[0].item, item(TeamLibraryKind::Query, lower(3)));
    assert_eq!(before[0].name.as_deref(), Some("Q"));
    assert_eq!(before[0].state, UnsentState::Pending);
    assert_eq!(after_quit, before);
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)),
        Some(query_fields("Q", None))
    );
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_discard_puts_back_the_team_s_copy_and_sends_nothing() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();
    mac.device.wire.drop_next_push();
    mac.device
        .sync
        .publish_team_saved_queries(
            team(),
            Vec::new(),
            vec![query(3, "Renamed", None), query(4, "New", None)],
        )
        .await
        .unwrap();
    let listed = mac.device.sync.unsent_team_edits().await.unwrap();

    mac.device.sync.discard_team_edits(Some(team())).await.unwrap();
    let report = mac.device.sync().await;

    assert_eq!(listed.len(), 2);
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
    assert_eq!(report.pushed, 0);
    assert_eq!(mac.items(TeamLibraryKind::Query), [(lower(3), query_fields("Q", None))]);
    assert_eq!(
        server_fields(&server, "library_query", &lower(3)),
        Some(query_fields("Q", None))
    );
    assert!(server.stored(owner(), "library_query", &lower(4)).is_none());
}

#[tokio::test]
async fn a_discard_and_the_list_still_answer_after_the_sign_in_ended() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device.wire.drop_next_push();
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();

    mac.sign_out();
    let listed = mac.device.sync.unsent_team_edits().await.unwrap();
    mac.device.sync.discard_team_edits(None).await.unwrap();

    assert_eq!(listed.len(), 1);
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
    assert!(mac.items(TeamLibraryKind::Query).is_empty());
}

#[tokio::test]
async fn status_names_the_last_pull_a_lapsed_team_s_pull_only_and_a_member_s_read_only_role() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    let before = mac.device.sync.team_scope_status().await.unwrap();
    mac.device.clock.advance(5_000);
    mac.device.sync().await;
    let synced = mac.device.sync.team_scope_status().await.unwrap();

    server.set_lapsed(true);
    mac.device.sync().await;
    let lapsed = mac.device.sync.team_scope_status().await.unwrap();
    let queued = mac
        .device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();
    server.set_lapsed(false);
    server.set_role(team(), crate::harness::account(), Some(Role::Member));
    mac.device.sync().await;
    let member = mac.device.sync.team_scope_status().await.unwrap();

    assert!(before.is_empty());
    assert_eq!(synced[0].last_synced_ms, Some(5_000));
    assert!(!synced[0].pull_only && !synced[0].write_forbidden);
    assert!(lapsed[0].pull_only);
    assert_eq!(queued.unsent, 1);
    assert_eq!(queued.problem.as_deref(), Some("sync.team_library.pull_only"));
    assert!(member[0].write_forbidden);
}
