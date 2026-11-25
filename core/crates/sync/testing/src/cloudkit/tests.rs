use tablepro_sync::api::cloudkit::{
    CloudKitFailure, CloudKitFetched, CloudKitField, CloudKitOutcome, CloudKitRecord, CloudKitTransport, CloudKitValue,
};

use super::FakeCloudKit;

const USER: &str = "_a1b2";

fn connection(name: &str, system_fields: Option<Vec<u8>>, title: &str) -> CloudKitRecord {
    CloudKitRecord {
        record_type: "Connection".to_owned(),
        name: name.to_owned(),
        system_fields,
        fields: vec![CloudKitField {
            name: "name".to_owned(),
            value: Some(CloudKitValue::Text(title.to_owned())),
        }],
    }
}

async fn zone() -> FakeCloudKit {
    let cloud = FakeCloudKit::signed_in(USER);
    cloud.ensure_zone(USER.to_owned()).await.unwrap();
    cloud
}

async fn saved(cloud: &FakeCloudKit, record: CloudKitRecord) -> Vec<u8> {
    match cloud
        .modify(USER.to_owned(), vec![record], Vec::new())
        .await
        .unwrap()
        .remove(0)
    {
        CloudKitOutcome::Saved { system_fields, .. } => system_fields,
        other => panic!("not saved: {other:?}"),
    }
}

#[tokio::test]
async fn a_save_holds_only_on_the_stored_system_fields() {
    let cloud = zone().await;
    let first = saved(&cloud, connection("Connection_A", None, "a")).await;

    let second = saved(&cloud, connection("Connection_A", Some(first.clone()), "b")).await;
    let stale = cloud
        .modify(
            USER.to_owned(),
            vec![connection("Connection_A", Some(first), "c")],
            Vec::new(),
        )
        .await
        .unwrap();
    let create_again = cloud
        .modify(USER.to_owned(), vec![connection("Connection_A", None, "d")], Vec::new())
        .await
        .unwrap();

    let server = match &stale[0] {
        CloudKitOutcome::ServerChanged {
            server: Some(server), ..
        } => server.clone(),
        other => panic!("not server changed: {other:?}"),
    };
    assert_eq!(server.system_fields, Some(second));
    assert_eq!(server.fields, connection("x", None, "b").fields);
    assert!(matches!(
        &create_again[0],
        CloudKitOutcome::ServerChanged { server: Some(_), .. }
    ));
}

#[tokio::test]
async fn a_save_rebuilt_for_a_record_deleted_elsewhere_is_unknown_item() {
    let cloud = zone().await;
    let tag = saved(&cloud, connection("Connection_A", None, "a")).await;
    cloud.delete_elsewhere(USER, "Connection_A");

    let outcome = cloud
        .modify(
            USER.to_owned(),
            vec![connection("Connection_A", Some(tag), "b")],
            Vec::new(),
        )
        .await
        .unwrap();

    assert_eq!(
        outcome[0],
        CloudKitOutcome::UnknownItem {
            name: "Connection_A".to_owned()
        }
    );
    assert!(cloud.record(USER, "Connection_A").is_none());
}

#[tokio::test]
async fn changes_page_after_a_token_with_deletions_and_a_full_fetch_lists_only_what_is_there() {
    let cloud = zone().await;
    cloud.set_limits(1, 400, 1 << 20);
    for name in ["Connection_A", "Connection_B"] {
        saved(&cloud, connection(name, None, "x")).await;
    }

    let first = cloud.fetch_changes(USER.to_owned(), None).await.unwrap();
    let second = cloud
        .fetch_changes(USER.to_owned(), Some(first.token.clone()))
        .await
        .unwrap();
    cloud.delete_elsewhere(USER, "Connection_A");
    let after = cloud
        .fetch_changes(USER.to_owned(), Some(second.token.clone()))
        .await
        .unwrap();
    let full = cloud.fetch_changes(USER.to_owned(), None).await.unwrap();

    assert!(first.more && !second.more);
    assert_eq!(first.changed[0].name, "Connection_A");
    assert_eq!(second.changed[0].name, "Connection_B");
    assert_eq!(after.deleted[0].name, "Connection_A");
    assert_eq!(after.deleted[0].record_type, "Connection");
    assert_eq!(
        full.changed
            .iter()
            .map(|record| record.name.as_str())
            .collect::<Vec<_>>(),
        ["Connection_B"]
    );
    assert!(full.deleted.is_empty());
}

#[tokio::test]
async fn an_expired_token_answers_token_expired() {
    let cloud = zone().await;
    saved(&cloud, connection("Connection_A", None, "a")).await;
    let changes = cloud.fetch_changes(USER.to_owned(), None).await.unwrap();

    cloud.expire_tokens(USER);

    let expired = cloud.fetch_changes(USER.to_owned(), Some(changes.token)).await;
    assert_eq!(expired.unwrap_err(), CloudKitFailure::TokenExpired);
}

#[tokio::test]
async fn a_batch_over_the_limit_saves_nothing() {
    let cloud = zone().await;
    cloud.set_limits(200, 1, 1 << 20);

    let batch = vec![
        connection("Connection_A", None, "a"),
        connection("Connection_B", None, "b"),
    ];
    let refused = cloud.modify(USER.to_owned(), batch, Vec::new()).await;

    assert_eq!(refused.unwrap_err(), CloudKitFailure::LimitExceeded);
    assert!(cloud.record_names(USER).is_empty());
}

#[tokio::test]
async fn a_zone_the_person_removed_answers_so_until_it_is_made_again() {
    let cloud = zone().await;
    saved(&cloud, connection("Connection_A", None, "a")).await;

    cloud.remove_zone_by_user(USER);
    let fetch = cloud.fetch_changes(USER.to_owned(), None).await;
    let save = cloud
        .modify(USER.to_owned(), vec![connection("Connection_A", None, "a")], Vec::new())
        .await;
    cloud.ensure_zone(USER.to_owned()).await.unwrap();

    assert_eq!(fetch.unwrap_err(), CloudKitFailure::ZoneDeletedByUser);
    assert_eq!(save.unwrap_err(), CloudKitFailure::ZoneDeletedByUser);
    assert!(cloud.record_names(USER).is_empty());
}

#[tokio::test]
async fn another_account_before_or_during_a_call_saves_nothing_to_either() {
    let cloud = zone().await;
    cloud.switch_account(Some("_other"));
    let before = cloud
        .modify(USER.to_owned(), vec![connection("Connection_A", None, "a")], Vec::new())
        .await;
    cloud.switch_account(Some(USER));
    cloud.switch_account_during_next_call(Some("_other"));
    let during = cloud
        .modify(USER.to_owned(), vec![connection("Connection_A", None, "a")], Vec::new())
        .await;

    assert_eq!(before.unwrap_err(), CloudKitFailure::AccountChanged);
    assert_eq!(during.unwrap_err(), CloudKitFailure::AccountChanged);
    assert!(cloud.record_names(USER).is_empty());
    assert!(cloud.record_names("_other").is_empty());
    assert_eq!(cloud.account_status().await.unwrap().user_record_name, "_other");
}

#[tokio::test]
async fn records_are_fetched_by_name_and_a_failing_one_answers_alone() {
    let cloud = zone().await;
    saved(&cloud, connection("Connection_A", None, "a")).await;
    cloud.fail_record("Connection_B", 7);

    let fetched = cloud
        .fetch_records(
            USER.to_owned(),
            vec!["Connection_A".to_owned(), "Connection_Z".to_owned()],
        )
        .await
        .unwrap();
    let outcomes = cloud
        .modify(
            USER.to_owned(),
            vec![
                connection("Connection_B", None, "b"),
                connection("Connection_C", None, "c"),
            ],
            Vec::new(),
        )
        .await
        .unwrap();

    assert!(matches!(&fetched[0], CloudKitFetched::Found { record } if record.name == "Connection_A"));
    assert_eq!(
        fetched[1],
        CloudKitFetched::Missing {
            name: "Connection_Z".to_owned()
        }
    );
    assert!(matches!(&outcomes[0], CloudKitOutcome::Failed { code: 7, .. }));
    assert!(matches!(&outcomes[1], CloudKitOutcome::Saved { .. }));
}

#[tokio::test]
async fn a_signed_out_device_has_no_account() {
    let cloud = FakeCloudKit::signed_in(USER);
    cloud.switch_account(None);

    assert_eq!(cloud.account_status().await.unwrap_err(), CloudKitFailure::NoAccount);
    assert_eq!(
        cloud.ensure_zone(USER.to_owned()).await.unwrap_err(),
        CloudKitFailure::NoAccount
    );
}
