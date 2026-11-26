use tablepro_storage::{TeamLibraryKind, delete_other_team_library_owners_blocking};
use tablepro_sync::api::control::SyncControl;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{Row, RowRange, Table};
use tablepro_sync::api::team_library::TeamLibraryControl;

use crate::support::{Mac, query, scope, team, team_server};

async fn library_rows(mac: &Mac) -> usize {
    let mut count = 0;
    for table in [Table::Bases, Table::Conflicts, Table::Held, Table::Approvals] {
        count += mac
            .device
            .rows(RowRange::Scope(table, scope()))
            .await
            .iter()
            .filter(|row| !matches!(row, Row::Scope(_)))
            .count();
    }
    count
}

#[tokio::test]
async fn a_delete_takes_the_store_file_and_the_team_s_library_records_and_the_team_refills_after_it() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None), query(4, "R", None)])
        .await
        .unwrap();
    let before = library_rows(&mac).await;

    mac.device.sync.delete_team_library_data().await.unwrap();
    let after = library_rows(&mac).await;
    let file_gone = !mac.store.path().exists();
    let report = mac.device.sync().await;

    assert_eq!(before, 2);
    assert_eq!(after, 0);
    assert!(file_gone);
    assert_eq!(report.pushed, 0);
    assert_eq!(mac.items(TeamLibraryKind::Query).len(), 2);
    assert!(mac.device.sync.unsent_team_edits().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_delete_another_sign_in_made_keeps_team_library_off_until_the_owner_s_engine_finishes_it() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device
        .sync
        .publish_team_saved_queries(team(), Vec::new(), vec![query(3, "Q", None)])
        .await
        .unwrap();
    let paths = mac.paths.clone();

    delete_other_team_library_owners_blocking(&paths, None).unwrap();
    let while_running = mac.device.sync.team_library().await;
    let mac = mac.reopen(&server, "dev_mac", dir.path()).await;
    let rows_after_reopen = library_rows(&mac).await;
    let report = mac.device.sync().await;

    assert_eq!(while_running.unwrap_err().code(), "sync.team_library.delete_pending");
    assert_eq!(rows_after_reopen, 0);
    assert!(!mac.store.delete_pending_blocking());
    assert_eq!(report.pushed, 0);
    assert_eq!(mac.items(TeamLibraryKind::Query).len(), 1);
}
