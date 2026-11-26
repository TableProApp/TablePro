use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::cloudkit::{CloudKitFailure, CloudKitField, CloudKitValue};
use tablepro_sync::api::error::StateError;
use tablepro_sync::api::ids::ChangeTag;
use tablepro_sync::api::state::{StateFiles, StateIdentity};
use tablepro_sync::api::{DeviceRowId, SyncError};
use tablepro_sync::cloudkit::fetch::{Categories, Fetcher};

use crate::faults::{Crashing, Unreliable};
use crate::support::{A, B, C, D, Rig, USER, name, projected};

#[tokio::test]
async fn a_first_fetch_takes_the_zone_and_keeps_each_record_s_system_fields() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db"}));
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "Work", "sort_order": 0}));

    let report = rig.fetch().await.unwrap();
    let again = rig.fetch().await.unwrap();

    let stored = rig.cloud.record(USER, &name(Kind::Connection, A)).unwrap();
    let base = rig.base(Kind::Connection, A).await.unwrap();
    assert!(report.full);
    assert_eq!(report.counts.written, 2);
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(Kind::Connection, A, &json!({"name": "prod", "host": "db"})))
    );
    assert_eq!(base.tag, ChangeTag::CloudKit(stored.system_fields.unwrap()));
    assert_eq!(base.fields, rig.store(Kind::Connection).fields(A));
    assert!(rig.token().await.is_some());
    assert!(!again.full);
    assert_eq!(again.counts.written, 0);
}

#[tokio::test]
async fn a_delta_brings_only_what_changed_since_the_token() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let writes = rig.store(Kind::Connection).writes();

    rig.save_elsewhere(Kind::Connection, B, &json!({"name": "staging"}));
    let report = rig.fetch().await.unwrap();

    assert!(!report.full);
    assert_eq!(report.counts.written, 1);
    assert_eq!(rig.store(Kind::Connection).writes(), writes + 1);
    assert!(rig.store(Kind::Connection).fields(B).is_some());
}

#[tokio::test]
async fn each_page_of_a_delta_commits_with_its_token() {
    let rig = Rig::new().await;
    rig.fetch().await.unwrap();
    rig.cloud.set_limits(1, 400, 1 << 20);
    for id in [A, B, C] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    let transport = Unreliable::new(&rig.cloud);
    transport.stop_after(2);

    let stopped = rig.fetch_through(&transport).await;
    let token_after_two = rig.token().await;
    let report = rig.fetch().await.unwrap();

    assert_eq!(stopped.unwrap_err(), SyncError::CloudKit(CloudKitFailure::Network));
    assert!(token_after_two.is_some());
    assert_eq!(report.pages, 1);
    assert_eq!(report.counts.written, 1);
    for id in [A, B, C] {
        assert!(rig.store(Kind::Group).fields(id).is_some(), "{id}");
    }
}

#[tokio::test]
async fn a_store_that_refuses_the_write_commits_no_base_and_no_token() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.store(Kind::Connection).refuse_next_write();

    let refused = rig.fetch().await;

    assert!(matches!(refused, Err(SyncError::Adapter(_))));
    assert!(rig.base(Kind::Connection, A).await.is_none());
    assert!(rig.token().await.is_none());
    rig.fetch().await.unwrap();
    assert!(rig.store(Kind::Connection).fields(A).is_some());
}

// The crash window between the store write and the state commit after it, the second of the batch's commits: the
// replay finds the store already holding the merge and writes nothing new, then commits the base and the token.
#[tokio::test]
async fn a_crash_after_the_store_write_replays_with_no_effect() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 5432}));
    rig.fetch().await.unwrap();
    rig.store(Kind::Connection).put(
        A,
        projected(Kind::Connection, A, &json!({"name": "mine", "port": 5432})),
    );
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 6432}));
    let crashing = Crashing::new(rig.state.clone());
    crashing.crash_after_commits(1);

    let crashed = rig.fetcher_on(rig.cloud.as_ref(), &crashing).fetch().await;
    let after_crash = rig.store(Kind::Connection).fields(A);
    let writes = rig.store(Kind::Connection).writes();
    let replay = rig.fetch().await.unwrap();

    let merged = projected(Kind::Connection, A, &json!({"name": "mine", "port": 6432}));
    assert!(matches!(crashed, Err(SyncError::State(StateError::Io { .. }))));
    assert_eq!(after_crash, Some(merged.clone()));
    assert_eq!(replay.counts.written, 0);
    assert_eq!(rig.store(Kind::Connection).writes(), writes);
    assert_eq!(rig.store(Kind::Connection).fields(A), Some(merged));
    let server = projected(Kind::Connection, A, &json!({"name": "prod", "port": 6432}));
    assert_eq!(rig.base(Kind::Connection, A).await.unwrap().fields, Some(server));
}

#[tokio::test]
async fn an_account_change_during_the_fetch_writes_nothing() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.cloud.switch_account_during_next_call(Some("_other"));

    let changed = rig.fetch().await;

    assert_eq!(
        changed.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::AccountChanged)
    );
    assert!(rig.store(Kind::Connection).fields(A).is_none());
    assert_eq!(rig.store(Kind::Connection).writes(), 0);
    assert!(rig.base(Kind::Connection, A).await.is_none());
    assert!(rig.token().await.is_none());
}

#[tokio::test]
async fn a_state_file_of_another_provider_is_refused() {
    let rig = Rig::new().await;
    let service = rig
        .files
        .open(StateIdentity::Service {
            origin: tablepro_keys::encoding::Origin::parse("https://sync.example.com").unwrap(),
            sign_in: "key".to_owned(),
            account: tablepro_keys::encoding::AccountId(uuid::Uuid::nil()),
            device_row: DeviceRowId("dev_1".to_owned()),
        })
        .await
        .unwrap();

    let refused = Fetcher::new(rig.cloud.as_ref(), service.as_ref(), &[], Categories::default());

    assert!(matches!(refused, Err(SyncError::State(StateError::WrongIdentity))));
}

#[tokio::test]
async fn a_record_type_iclouds_builds_no_longer_write_and_a_name_out_of_form_are_left_alone() {
    let rig = Rig::new().await;
    let field = |name: &str| CloudKitField {
        name: name.to_owned(),
        value: Some(CloudKitValue::Text("SELECT 1".to_owned())),
    };
    rig.cloud
        .save_elsewhere(USER, "QueryHistory", "QueryHistory_1", vec![field("query")]);
    rig.cloud
        .save_elsewhere(USER, "Connection", "Connection_not-a-uuid", vec![field("name")]);

    let report = rig.fetch().await.unwrap();

    assert_eq!(report.counts.written, 0);
    assert_eq!(report.counts.held, 0);
    assert!(!rig.store(Kind::Connection).holds("not-a-uuid"));
}

// The token stays where it was until a full fetch ends, so one stopped midway starts over whole.
#[tokio::test]
async fn an_expired_token_starts_a_full_fetch_that_starts_over_whole_when_it_stops() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.fetch().await.unwrap();
    let old = rig.token().await;
    rig.cloud.set_limits(1, 400, 1 << 20);
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "b"}));
    rig.cloud.expire_tokens(USER);
    let transport = Unreliable::new(&rig.cloud);
    transport.stop_after(2);

    let stopped = rig.fetch_through(&transport).await;
    let kept = rig.token().await;
    let report = rig.fetch().await.unwrap();

    assert!(stopped.is_err());
    assert_eq!(kept, old);
    assert!(report.token_expired && report.full);
    assert_eq!(report.pages, 2);
    assert_ne!(rig.token().await, old);
    assert!(rig.store(Kind::Group).fields(B).is_some());
    assert!(!rig.fetch().await.unwrap().full);
}

// The person saves while the pull merges: the batch is read and merged again, so the save survives.
#[tokio::test]
async fn a_store_written_while_the_pull_merges_is_read_and_merged_again() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 5432}));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "port": 6432}));
    rig.store(Kind::Connection).edit_after_next_read(
        A,
        projected(Kind::Connection, A, &json!({"name": "mine", "port": 5432})),
    );

    rig.fetch().await.unwrap();

    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(Kind::Connection, A, &json!({"name": "mine", "port": 6432})))
    );
}

#[tokio::test]
async fn a_fetch_that_never_ends_is_refused() {
    let rig = Rig::new().await;
    let transport = Unreliable::new(&rig.cloud);
    transport.never_end();

    let refused = rig.fetch_through(&transport).await;

    assert_eq!(refused.unwrap_err(), SyncError::Malformed { what: "change token" });
    assert!(rig.token().await.is_none());
}

#[tokio::test]
async fn an_account_change_on_a_later_page_keeps_what_the_earlier_pages_brought_and_no_token() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(1, 400, 1 << 20);
    for id in [A, B] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    let transport = Unreliable::new(&rig.cloud);
    transport.fail_after(1, CloudKitFailure::AccountChanged);

    let changed = rig.fetch_through(&transport).await;

    assert_eq!(
        changed.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::AccountChanged)
    );
    assert!(rig.store(Kind::Group).holds(A));
    assert!(!rig.store(Kind::Group).holds(B));
    assert!(rig.token().await.is_none());
}

#[tokio::test]
async fn an_account_change_while_reading_by_name_writes_nothing_of_that_page() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.save_elsewhere(Kind::Group, B, &json!({"name": "b"}));
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Group, A));
    transport.fail_next_read_call(CloudKitFailure::AccountChanged);

    let changed = rig.fetch_through(&transport).await;

    assert_eq!(
        changed.unwrap_err(),
        SyncError::CloudKit(CloudKitFailure::AccountChanged)
    );
    assert!(!rig.store(Kind::Group).holds(B));
    assert!(rig.held(Kind::Group, A).await.is_none());
}

// A settings category past the record name limit is named by its digest in the zone; the store keeps the category.
#[tokio::test]
async fn a_long_id_meets_the_digest_the_zone_names_it_with() {
    let rig = Rig::new().await;
    let table = "t".repeat(240);
    let category = tablepro_records::record_id::column_layout_category(uuid::Uuid::nil(), Some("shop"), None, &table);
    let wire = tablepro_records::record_id::shortened(Kind::MacosSettings, category.clone());
    assert!(wire.starts_with("sha256-"));
    let layout =
        |width: i64| json!({"category": category, "options": {"columnWidths": [{"id": "id", "value": width}]}});
    rig.store(Kind::MacosSettings)
        .put(&category, projected(Kind::MacosSettings, &wire, &layout(80)));
    rig.save_elsewhere(Kind::MacosSettings, &wire, &layout(120));

    rig.fetch().await.unwrap();

    assert_eq!(
        rig.store(Kind::MacosSettings).fields(&category),
        Some(projected(Kind::MacosSettings, &wire, &layout(80)))
    );
    assert!(!rig.store(Kind::MacosSettings).holds(&wire));
    assert!(rig.base(Kind::MacosSettings, &wire).await.is_some());
}

// A field the zone never carries is neither an edit nor a removal: deleted elsewhere, the record goes.
#[tokio::test]
async fn a_field_only_this_device_keeps_does_not_revive_a_record_deleted_elsewhere() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod"}));
    rig.fetch().await.unwrap();
    let mut opened = rig.store(Kind::Connection).fields(A).unwrap();
    opened["last_opened_at"] = json!(1_700_000_000_000_i64);
    rig.store(Kind::Connection).put(A, opened);
    rig.delete_elsewhere(Kind::Connection, A);

    rig.fetch().await.unwrap();

    assert!(!rig.store(Kind::Connection).holds(A));
    assert!(rig.base(Kind::Connection, A).await.is_none());
}

// A member only TablePro Sync carries inside a field iCloud carries stays through a change made elsewhere.
#[tokio::test]
async fn a_member_icloud_does_not_carry_stays_through_a_change_made_elsewhere() {
    let rig = Rig::new().await;
    let ssl = |mode: &str| json!({"name": "prod", "ssl_config": {"mode": mode}});
    rig.save_elsewhere(Kind::Connection, A, &ssl("Preferred"));
    rig.fetch().await.unwrap();
    let mut local = rig.store(Kind::Connection).fields(A).unwrap();
    local["ssl_config"]["server_name"] = json!("db.internal");
    rig.store(Kind::Connection).put(A, local);
    rig.save_elsewhere(Kind::Connection, A, &ssl("Required"));

    rig.fetch().await.unwrap();

    let stored = rig.store(Kind::Connection).fields(A).unwrap();
    assert_eq!(stored["ssl_config"]["mode"], json!("Required"));
    assert_eq!(stored["ssl_config"]["server_name"], json!("db.internal"));
}

// A full fetch whose first page ends at the token the state kept is no fetch that never ends.
#[tokio::test]
async fn a_full_fetch_page_may_end_at_the_token_the_state_kept() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(2, 400, 1 << 20);
    for id in [A, B] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::Group, C, &json!({"name": C}));
    rig.store(Kind::Group).restore(Vec::new());

    let report = rig.fetch().await.unwrap();

    assert!(report.full);
    assert!(rig.store(Kind::Group).holds(C));
}

#[tokio::test]
async fn a_page_that_repeats_a_token_is_refused() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(1, 400, 1 << 20);
    for id in [A, B] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    rig.fetch().await.unwrap();
    let token = rig.token().await;
    let transport = Unreliable::new(&rig.cloud);
    transport.repeat_token(token.unwrap());
    rig.save_elsewhere(Kind::Group, C, &json!({"name": C}));
    rig.save_elsewhere(Kind::Group, D, &json!({"name": D}));

    let refused = rig.fetch_through(&transport).await;

    assert_eq!(refused.unwrap_err(), SyncError::Malformed { what: "change token" });
}

// The store is put back while the fetch runs: the pass ends before its copies merge as edits, and the next refills.
#[tokio::test]
async fn a_store_restored_while_the_fetch_runs_ends_the_pass_and_the_next_refills() {
    let rig = Rig::new().await;
    rig.cloud.set_limits(1, 400, 1 << 20);
    rig.save_elsewhere(Kind::Group, A, &json!({"name": "a"}));
    rig.fetch().await.unwrap();
    for id in [B, D] {
        rig.save_elsewhere(Kind::Group, id, &json!({"name": id}));
    }
    let transport = Unreliable::new(&rig.cloud);
    let group = rig.store(Kind::Group);
    let stale = projected(Kind::Group, A, &json!({"name": "stale"}));
    transport.before_call(1, Box::new(move || group.restore(vec![(A, stale)])));

    let ended = rig.fetch_through(&transport).await;
    let next = rig.fetch().await.unwrap();

    assert!(matches!(ended, Err(SyncError::Adapter(_))));
    assert_eq!(next.refilled, [Kind::Group]);
    assert_eq!(
        rig.store(Kind::Group).fields(A),
        Some(projected(Kind::Group, A, &json!({"name": "a"})))
    );
}

#[tokio::test]
async fn a_new_long_id_record_is_stored_under_the_category_it_names() {
    let rig = Rig::new().await;
    let category =
        tablepro_records::record_id::column_layout_category(uuid::Uuid::nil(), Some("shop"), None, &"t".repeat(240));
    let wire = tablepro_records::record_id::shortened(Kind::MacosSettings, category.clone());
    let layout = json!({"category": category, "options": {"columnWidths": [{"id": "id", "value": 80}]}});
    rig.save_elsewhere(Kind::MacosSettings, &wire, &layout);

    rig.fetch().await.unwrap();

    assert!(rig.store(Kind::MacosSettings).holds(&category));
    assert!(!rig.store(Kind::MacosSettings).holds(&wire));
}
