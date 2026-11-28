// Approval-required members on iCloud (0054, Rules for both providers; Rationale, Approvals cover iCloud): a pulled
// host waits for the person on the device, the device never pushes its own value back over it, a record new to the
// device waits whole, and a deletion leaves nothing to decide.

use serde_json::json;
use tablepro_records::Kind;
use tablepro_sync::api::control::{PassReason, SyncControl};
use tablepro_sync::api::state::HeldReason;

use crate::faults::Unreliable;
use crate::support::{A, Rig, key, name, projected};

#[tokio::test]
async fn a_pulled_host_waits_and_the_push_never_sends_the_device_s_own_back_over_it() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.internal"}));
    rig.fetch().await.unwrap();
    rig.approve_everything().await;
    rig.save_elsewhere(
        Kind::Connection,
        A,
        &json!({"name": "prod 2", "host": "elsewhere.example.com"}),
    );

    rig.fetch().await.unwrap();
    let waited = rig.store(Kind::Connection).fields(A);
    let waiting = rig.waiting().await;
    let mut edited = waited.clone().unwrap();
    edited["name"] = json!("prod 3");
    rig.store(Kind::Connection).put(A, edited);
    let pushed = rig.push().await.unwrap();
    let zone = rig.zone_fields(Kind::Connection, A);
    rig.approve_everything().await;

    assert_eq!(
        waited,
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "prod 2", "host": "db.internal"})
        ))
    );
    assert_eq!(waiting.len(), 1);
    assert_eq!(
        (waiting[0].field.as_str(), &waiting[0].pulled),
        ("/host", &json!("elsewhere.example.com"))
    );
    assert_eq!(waiting[0].current, Some(json!("db.internal")));
    assert_eq!(pushed.saved, 1);
    assert_eq!(
        zone,
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "prod 3", "host": "elsewhere.example.com"})
        ))
    );
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "prod 3", "host": "elsewhere.example.com"})
        ))
    );
}

#[tokio::test]
async fn a_connection_new_to_the_device_waits_whole_until_the_pass_s_approval_lets_it_in() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.example.com"}));
    let sync = rig.sync(None);

    sync.run_pass(PassReason::Launch).await.unwrap();
    let held = rig.held(Kind::Connection, A).await.map(|row| row.reason);
    let stored = rig.store(Kind::Connection).holds(A);
    let status = sync.status();
    let waiting = sync.approvals().await.unwrap();
    for record in &waiting {
        for approval in &record.fields {
            sync.decide_approval(record.key.clone(), approval.field.clone(), approval.digest, true)
                .await
                .unwrap();
        }
    }
    let pushed = sync.run_pass(PassReason::Poll).await.unwrap().push;

    assert_eq!(held, Some(HeldReason::AwaitingApproval));
    assert!(!stored);
    assert_eq!(status.waiting_approvals, 1);
    assert_eq!(waiting.len(), 1);
    assert_eq!(waiting[0].key, key(Kind::Connection, A));
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(
            Kind::Connection,
            A,
            &json!({"name": "prod", "host": "db.example.com"})
        ))
    );
    assert!(rig.held(Kind::Connection, A).await.is_none());
    assert_eq!(sync.status().waiting_approvals, 0);
    assert_eq!(pushed.queued, 0);
}

#[tokio::test]
async fn a_record_deleted_elsewhere_or_here_leaves_nothing_to_approve() {
    let rig = Rig::new().await;
    for id in [A, crate::support::B] {
        rig.save_elsewhere(Kind::Connection, id, &json!({"name": "prod", "host": "db.internal"}));
    }
    rig.fetch().await.unwrap();
    rig.approve_everything().await;
    for id in [A, crate::support::B] {
        rig.save_elsewhere(
            Kind::Connection,
            id,
            &json!({"name": "prod", "host": "elsewhere.example.com"}),
        );
    }
    rig.fetch().await.unwrap();
    let waited = rig.waiting().await.len();

    rig.delete_elsewhere(Kind::Connection, A);
    rig.fetch().await.unwrap();
    rig.store(Kind::Connection).remove(crate::support::B);
    rig.push().await.unwrap();

    assert_eq!(waited, 2);
    assert!(rig.waiting().await.is_empty());
    assert!(!rig.store(Kind::Connection).holds(A));
}

// A connection new to the device waits whole for its host when its next copy, a placement-only change, fails to read.
// It stays held for the person, not as a copy to read again, so the approval given meanwhile stands, and the copy that
// reads on the next fetch goes into the store with it.
#[tokio::test]
async fn a_connection_held_whole_whose_next_copy_fails_to_read_stays_held_for_the_person() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::Connection, A, &json!({"name": "prod", "host": "db.example.com"}));
    rig.fetch().await.unwrap();
    let placed = json!({"name": "prod", "host": "db.example.com", "sort_order": 2});
    rig.save_elsewhere(Kind::Connection, A, &placed);
    let transport = Unreliable::new(&rig.cloud);
    transport.leave_unfetched(&name(Kind::Connection, A));
    transport.fail_reads(&name(Kind::Connection, A), 1);

    rig.fetch_through(&transport).await.unwrap();
    let held = rig.held(Kind::Connection, A).await.map(|row| row.reason);
    rig.approve_everything().await;
    rig.fetch().await.unwrap();
    let pushed = rig.push().await.unwrap();

    assert_eq!(held, Some(HeldReason::AwaitingApproval));
    assert_eq!(
        rig.store(Kind::Connection).fields(A),
        Some(projected(Kind::Connection, A, &placed))
    );
    assert!(rig.held(Kind::Connection, A).await.is_none());
    assert!(rig.waiting().await.is_empty());
    assert_eq!((pushed.saved, pushed.deleted), (0, 0));
    assert_eq!(
        rig.zone_fields(Kind::Connection, A),
        Some(projected(Kind::Connection, A, &placed))
    );
}
