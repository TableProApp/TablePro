// Rules the Swift iOS engine kept for copies an earlier iOS build wrote, and the keyword rule both Swift engines kept,
// on the core's CloudKit path (0054, Rules for both providers): an unsettled Required sends nothing over the Mac's
// Preferred, a link that build never read is no removal, a link this device removed goes up, and a pull that brings a
// second holder of a keyword leaves it with the query created first.

use serde_json::{Value, json};
use tablepro_records::Kind;

use crate::support::{A, B, C, Rig};

const PROFILE: &str = "0F6C2A1E-6B3D-4D8E-9A51-3D7E2B1F0C44";

fn with_tls(name: &str, mode: &str) -> Value {
    json!({"name": name, "ssl_config": {"mode": mode}})
}

fn with_tunnel(name: &str, link: Option<&str>) -> Value {
    let mut copy = json!({
        "name": name,
        "ssh_config": {"enabled": true, "host": "db.internal", "port": 22, "username": "deploy"},
    });
    if let Some(link) = link {
        copy["ssh_profile_id"] = json!(link);
    }
    copy
}

async fn synced(rig: &Rig, wire: &Value) -> Value {
    rig.save_elsewhere(Kind::Connection, A, wire);
    rig.fetch().await.unwrap();
    rig.approve_everything().await;
    rig.store(Kind::Connection).fields(A).unwrap()
}

fn unsettled(mut copy: Value) -> Value {
    copy["ssl_config"]["mode"] = json!("Required");
    copy["tls_mode_unsettled"] = json!(true);
    copy
}

fn without_link(mut copy: Value) -> Value {
    if let Value::Object(members) = &mut copy {
        members.remove("ssh_profile_id");
    }
    copy
}

#[tokio::test]
async fn a_required_an_earlier_ios_build_wrote_sends_nothing_over_the_mac_s_preferred() {
    let rig = Rig::new().await;
    let stored = synced(&rig, &with_tls("prod", "Preferred")).await;
    rig.store(Kind::Connection).put(A, unsettled(stored));

    let pushed = rig.push().await.unwrap();

    assert_eq!(pushed.queued, 0);
    assert_eq!(
        rig.zone_fields(Kind::Connection, A).unwrap()["ssl_config"]["mode"],
        json!("Preferred")
    );
}

#[tokio::test]
async fn a_required_the_person_chose_goes_up_over_the_mac_s_preferred() {
    let rig = Rig::new().await;
    let mut stored = synced(&rig, &with_tls("prod", "Preferred")).await;
    stored["ssl_config"]["mode"] = json!("Required");
    rig.store(Kind::Connection).put(A, stored);

    rig.push().await.unwrap();

    assert_eq!(
        rig.zone_fields(Kind::Connection, A).unwrap()["ssl_config"]["mode"],
        json!("Required")
    );
}

#[tokio::test]
async fn the_pull_that_brings_the_record_settles_the_mode_with_nothing_to_approve() {
    let rig = Rig::new().await;
    let stored = synced(&rig, &with_tls("prod", "Preferred")).await;
    rig.store(Kind::Connection).put(A, unsettled(stored));
    rig.save_elsewhere(Kind::Connection, A, &with_tls("prod 2", "Preferred"));

    rig.fetch().await.unwrap();

    let settled = rig.store(Kind::Connection).fields(A).unwrap();
    assert_eq!(settled["ssl_config"]["mode"], json!("Preferred"));
    assert_eq!(settled["name"], json!("prod 2"));
    assert!(settled.get("tls_mode_unsettled").is_none());
    assert!(rig.waiting().await.is_empty());
}

#[tokio::test]
async fn a_link_an_earlier_build_never_read_is_no_removal_and_the_pull_writes_it_unasked() {
    let rig = Rig::new().await;
    let stored = synced(&rig, &with_tunnel("prod", Some(PROFILE))).await;
    rig.store(Kind::Connection).put(A, without_link(stored));

    let pushed = rig.push().await.unwrap();
    rig.save_elsewhere(Kind::Connection, A, &with_tunnel("prod 2", Some(PROFILE)));
    rig.fetch().await.unwrap();

    assert_eq!(pushed.queued, 0);
    let adopted = rig.store(Kind::Connection).fields(A).unwrap();
    assert_eq!(adopted["ssh_profile_id"], json!(PROFILE));
    assert_eq!(adopted["name"], json!("prod 2"));
    assert!(rig.waiting().await.is_empty());
}

#[tokio::test]
async fn a_link_this_device_removed_goes_up_and_the_pull_without_it_drops_the_mark() {
    let rig = Rig::new().await;
    let stored = synced(&rig, &with_tunnel("prod", Some(PROFILE))).await;
    let mut removed = without_link(stored);
    removed["ssh_profile_unlinked"] = json!(true);
    rig.store(Kind::Connection).put(A, removed);

    rig.push().await.unwrap();
    let zone = rig.zone_fields(Kind::Connection, A).unwrap();
    rig.save_elsewhere(Kind::Connection, A, &with_tunnel("prod 2", None));
    rig.fetch().await.unwrap();

    assert!(zone.get("ssh_profile_id").is_none());
    let settled = rig.store(Kind::Connection).fields(A).unwrap();
    assert!(settled.get("ssh_profile_id").is_none());
    assert!(settled.get("ssh_profile_unlinked").is_none());
}

#[tokio::test]
async fn a_tunnel_switched_off_drops_the_link() {
    let rig = Rig::new().await;
    let stored = synced(&rig, &with_tunnel("prod", Some(PROFILE))).await;
    let mut off = without_link(stored);
    off["ssh_config"]["enabled"] = json!(false);
    rig.store(Kind::Connection).put(A, off);

    rig.push().await.unwrap();

    assert!(
        rig.zone_fields(Kind::Connection, A)
            .unwrap()
            .get("ssh_profile_id")
            .is_none()
    );
}

fn saved_query(keyword: &str, created_at: i64) -> Value {
    json!({
        "name": "revenue",
        "query": "SELECT 1",
        "keyword": keyword,
        "connection_id": C,
        "created_at": created_at,
    })
}

#[tokio::test]
async fn a_pulled_older_holder_takes_the_keyword_and_the_local_query_s_release_goes_up() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::SavedQuery, A, &saved_query("rev", 2_000));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::SavedQuery, B, &saved_query("rev", 1_000));

    rig.fetch().await.unwrap();
    rig.push().await.unwrap();

    let store = rig.store(Kind::SavedQuery);
    assert!(store.fields(A).unwrap().get("keyword").is_none());
    assert_eq!(store.fields(B).unwrap()["keyword"], json!("rev"));
    assert!(rig.zone_fields(Kind::SavedQuery, A).unwrap().get("keyword").is_none());
    assert_eq!(rig.zone_fields(Kind::SavedQuery, B).unwrap()["keyword"], json!("rev"));
}

#[tokio::test]
async fn a_pulled_newer_holder_lands_without_the_keyword_and_its_release_goes_up() {
    let rig = Rig::new().await;
    rig.save_elsewhere(Kind::SavedQuery, A, &saved_query("rev", 1_000));
    rig.fetch().await.unwrap();
    rig.save_elsewhere(Kind::SavedQuery, B, &saved_query("rev", 2_000));

    rig.fetch().await.unwrap();
    rig.push().await.unwrap();

    let store = rig.store(Kind::SavedQuery);
    assert_eq!(store.fields(A).unwrap()["keyword"], json!("rev"));
    assert!(store.fields(B).unwrap().get("keyword").is_none());
    assert!(rig.zone_fields(Kind::SavedQuery, B).unwrap().get("keyword").is_none());
    assert_eq!(rig.zone_fields(Kind::SavedQuery, A).unwrap()["keyword"], json!("rev"));
}
