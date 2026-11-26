use tablepro_records::Kind;
use tablepro_storage::TeamLibraryKind;
use tablepro_sync::api::scopes::Role;
use tablepro_sync::api::state::{HeldReason, Row, RowRange, Table};
use tablepro_sync::api::team_library::TeamLibraryControl;

use crate::support::{Mac, lower, owner, query_fields, scope, server_fields, team_server};

async fn listed(mac: &Mac) -> usize {
    mac.device
        .sync
        .team_library()
        .await
        .unwrap()
        .iter()
        .flat_map(|team| &team.items)
        .filter(|item| item.item.kind == TeamLibraryKind::Query)
        .count()
}

// A record whose id another of its kind holds in other case, as a hostile server or an older build may write, is held
// by id with the server's copy as its base, so neither spelling is listed, planned or sent, the same way the publish
// plan leaves both out (K8t leftover).
#[tokio::test]
async fn a_pair_of_ids_that_collide_in_case_is_held_and_neither_is_listed_or_sent() {
    let server = team_server(Role::Owner);
    let dir = tempfile::tempdir().unwrap();
    server.plant(owner(), Kind::LibraryQuery, &lower(0xab), query_fields("Lower", None));
    let mac = Mac::new(&server, "dev_mac", dir.path()).await;
    mac.device.sync().await;
    let listed_before = listed(&mac).await;

    server.plant(
        owner(),
        Kind::LibraryQuery,
        &lower(0xab).to_uppercase(),
        query_fields("Upper", None),
    );
    let report = mac.device.sync().await;
    // An edit of the spelling the store already held goes nowhere either.
    mac.store
        .put_items_blocking(
            &scope().wire(),
            vec![tablepro_storage::TeamLibraryItem {
                kind: TeamLibraryKind::Query,
                id: lower(0xab),
                fields: query_fields("Edited here", None),
            }],
        )
        .unwrap();
    let edited = mac.device.sync().await;
    let held: Vec<(String, HeldReason)> = mac
        .device
        .rows(RowRange::Scope(Table::Held, scope()))
        .await
        .into_iter()
        .filter_map(|row| match row {
            Row::Held(row) => Some((row.key.record_id, row.reason)),
            _ => None,
        })
        .collect();

    assert_eq!(listed_before, 1);
    assert_eq!(listed(&mac).await, 0);
    assert_eq!(held, vec![(lower(0xab).to_uppercase(), HeldReason::Collides)]);
    assert_eq!(report.pushed, 0);
    assert_eq!(edited.pushed, 0);
    assert!(
        mac.items(TeamLibraryKind::Query)
            .iter()
            .all(|(id, _)| *id == lower(0xab))
    );
    assert_eq!(
        server_fields(&server, "library_query", &lower(0xab)),
        Some(query_fields("Lower", None))
    );
}
