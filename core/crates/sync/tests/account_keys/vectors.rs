// tablepro-keys' G1 vectors through the account flows: account P's devices B and C from the flows world, its
// certificates, versions and envelopes as the vector rows give them.

use std::sync::{Arc, OnceLock};

use secrecy::ExposeSecret;
use serde_json::Value;
use tablepro_keys::body::{DeviceBody, KeyBody, KeyObject, WrapBody};
use tablepro_keys::cert::{AccountCertificate, CertKind, DeviceCertificate};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Version};
use tablepro_keys::envelope::EnvelopeId;
use tablepro_keys::keys::{AccountKeys, DeviceKeys, Ed25519Seed, ScopeKey, X25519Secret};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::KeyRef;
use tablepro_keys::trust::PinHow;
use tablepro_keys::wrap::{Wrap, Wrapper, scope_key_target};
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, ArrivalOrder, KeyState, LockCause};
use tablepro_sync::api::state::{KeyObjectRow, KeyPinRow, KeyVersionRow, KeyVersionState, Row};
use tablepro_sync::api::transport::PulledRecord;
use tablepro_sync::keys::HeldDeviceKeys;
use tablepro_sync_testing::{FakeDeviceStore, FakeServer};

use crate::harness::{Device, account_id, origin, record};

pub fn fixture() -> &'static Value {
    static FIXTURE: OnceLock<Value> = OnceLock::new();
    FIXTURE.get_or_init(|| serde_json::from_str(include_str!("g1_vectors.json")).unwrap())
}

fn bytes<const N: usize>(text: &Value) -> [u8; N] {
    hex::decode(text.as_str().unwrap()).unwrap().try_into().unwrap()
}

fn world_account(name: &str) -> &'static Value {
    fixture()["world"]["accounts"]
        .as_array()
        .unwrap()
        .iter()
        .find(|account| account["name"] == name)
        .unwrap()
}

fn world_device(name: &str) -> DeviceKeys {
    let device = fixture()["world"]["devices"]
        .as_array()
        .unwrap()
        .iter()
        .find(|device| device["name"] == name)
        .unwrap();
    DeviceKeys {
        key_device: KeyDeviceId::from_wire(device["key_device"].as_str().unwrap()).unwrap(),
        dsk: Ed25519Seed::from_bytes(bytes(&device["dsk_seed_hex"])),
        dek: X25519Secret::from_bytes(bytes(&device["dek_secret_hex"])),
    }
}

fn account_keys(name: &str, av: u32) -> AccountKeys {
    let keys = world_account(name)["account_keys"]
        .as_array()
        .unwrap()
        .iter()
        .find(|keys| keys["av"] == av)
        .unwrap();
    AccountKeys {
        ask: Ed25519Seed::from_bytes(bytes(&keys["ask_seed_hex"])),
        aek: X25519Secret::from_bytes(bytes(&keys["aek_secret_hex"])),
    }
}

fn scenario(name: &str) -> &'static Value {
    fixture()["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|scenario| scenario["name"] == name)
        .unwrap()
}

fn records(step: &Value) -> Vec<PulledRecord> {
    step["records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record_value| {
            record(
                record_value["kind"].as_str().unwrap(),
                record_value["id"].as_str().unwrap(),
                &record_value["fields"].to_string(),
            )
        })
        .collect()
}

fn version_record(label: &str) -> PulledRecord {
    let held = fixture()["world"]["version_records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|held| held["label"] == label)
        .unwrap();
    record(
        held["kind"].as_str().unwrap(),
        held["id"].as_str().unwrap(),
        &held["fields"].to_string(),
    )
}

fn p() -> AccountId {
    account_id(world_account("P")["account"].as_str().unwrap())
}

fn certificate(av: u32) -> AccountCertificate {
    let recovery = RecoveryKey::from_bytes(bytes(&world_account("P")["r_hex"]));
    let ik = recovery.identity_seed(&origin(), p()).unwrap();
    AccountCertificate::sign(
        &origin(),
        p(),
        Version::new(av).unwrap(),
        CertKind::GenesisOrRotation,
        &ik,
        account_keys("P", av).public().unwrap(),
        None,
    )
    .unwrap()
}

fn object_row(object: &KeyObject) -> Row {
    Row::KeyObject(KeyObjectRow {
        scope: ScopeName::Personal,
        kind: tablepro_sync::api::ids::KindName::parse(object.id.kind().name()).unwrap(),
        record_id: object.id.to_wire(),
        fields: object.fields_json(),
        applied: true,
        served: None,
    })
}

// Device `name` of account P, approved at `av`: its keys, P's certificates up to `av`, its own device certificate
// and the pin a device approved there holds.
async fn p_device(server: &Arc<FakeServer>, name: &str, row: &str, av: u32) -> Device {
    let device = Device::with_store(server, p(), row, Arc::new(FakeDeviceStore::new())).await;
    let keys = world_device(name);
    device
        .service
        .store_device_keys(&HeldDeviceKeys {
            current: Some(keys.clone()),
            pending: None,
        })
        .await
        .unwrap();
    let at = Version::new(av).unwrap();
    device
        .service
        .store_account_keys(at, &account_keys("P", av))
        .await
        .unwrap();
    let mut rows = Vec::new();
    for level in 1..=av {
        let certificate = certificate(level);
        rows.push(object_row(&KeyObject {
            id: KeyRecordId::Account {
                account: p(),
                av: certificate.av,
            },
            body: KeyBody::Account(tablepro_keys::body::AccountBody::of(&certificate)),
        }));
    }
    let device_certificate = DeviceCertificate::sign(
        &origin(),
        p(),
        at,
        keys.key_device,
        keys.dek.public().unwrap(),
        keys.dsk.public().unwrap(),
        &account_keys("P", av).ask,
    )
    .unwrap();
    rows.push(object_row(&KeyObject {
        id: KeyRecordId::Device {
            account: p(),
            key_device: keys.key_device,
            av: at,
        },
        body: KeyBody::Device(DeviceBody::of(&device_certificate)),
    }));
    rows.push(Row::KeyPin(KeyPinRow {
        account: p(),
        ik: certificate(av).ik,
        av: at,
        how: PinHow::Compared,
        alert: false,
        replaced: Vec::new(),
    }));
    device.put(rows).await;
    device
}

#[tokio::test]
async fn the_world_s_certificates_are_the_ones_the_vectors_sign() {
    let genesis = scenario("two genesis change sets, and an identical retry")["steps"][0]["records"][0].clone();
    let KeyBody::Account(body) = KeyObject::parse(
        "key.account",
        genesis["id"].as_str().unwrap(),
        genesis["fields"].to_string().as_bytes(),
    )
    .unwrap()
    .body
    else {
        panic!()
    };

    assert_eq!(body.certificate(p(), Version::FIRST), certificate(1));
}

#[tokio::test]
async fn a_device_left_out_of_a_rotation_waits_for_the_whole_change_set_then_locks_and_erases_nothing() {
    let server = FakeServer::new();
    let c = p_device(&server, "P device C", "dev_c", 1).await;
    let rows = scenario("a device left out of a rotation")["steps"].as_array().unwrap();
    let key_device = world_device("P device C").key_device;
    assert_eq!(
        c.key_state().await,
        KeyState::Approved {
            av: Version::FIRST,
            key_device
        }
    );

    let shown = c.feed(records(&rows[0]), ArrivalOrder::InOrder).await;

    assert!(shown.refused.is_empty());
    assert_eq!(
        c.key_state().await,
        KeyState::Approved {
            av: Version::FIRST,
            key_device
        }
    );
    let whole = c.feed(records(&rows[1]), ArrivalOrder::InOrder).await;
    assert!(whole.refused.is_empty(), "{:?}", whole.refused);
    assert_eq!(
        c.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
    assert!(c.store.holds(&DeviceItem::AccountKeys {
        origin: origin(),
        account: p(),
        av: Version::FIRST,
    }));
    assert_eq!(
        c.service.device_keys().await.unwrap().current.unwrap().key_device,
        key_device
    );
}

#[tokio::test]
async fn the_device_a_rotation_keeps_adopts_its_keys_from_the_compared_device_s_wrap() {
    let server = FakeServer::new();
    let b = p_device(&server, "P device B", "dev_b", 1).await;
    let rows = scenario("a device left out of a rotation")["steps"].as_array().unwrap();
    let key_device = world_device("P device B").key_device;
    // The world gives P's first personal version; its first history version is not in it, so only PK is followed.
    let pk1 = version_record("P PK1");
    let pk1 = KeyObject::parse(
        "key.version",
        &pk1.record_id,
        pk1.fields_json.as_deref().unwrap().as_bytes(),
    )
    .unwrap();
    b.put(vec![
        object_row(&pk1),
        Row::KeyVersion(KeyVersionRow {
            scope: ScopeName::Personal,
            purpose: KeyPurpose::Personal,
            version: Version::FIRST,
            record: pk1.version_record().unwrap().digest(&origin()).unwrap(),
            holders: Vec::new(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        }),
    ])
    .await;

    let applied = b.feed(records(&rows[1]), ArrivalOrder::InOrder).await;

    assert!(applied.refused.is_empty(), "{:?}", applied.refused);
    assert_eq!(
        b.key_state().await,
        KeyState::Approved {
            av: Version::new(2).unwrap(),
            key_device
        }
    );
    let held = b.service.account_keys(Version::new(2).unwrap()).await.unwrap().unwrap();
    assert_eq!(held.public().unwrap(), account_keys("P", 2).public().unwrap());
    let mut txn = b.txn().await;
    let current = b
        .service
        .current_personal(txn.as_mut(), KeyPurpose::Personal)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        (current.record.key.version, current.record.signer_av),
        (Version::new(2).unwrap(), Version::new(2).unwrap())
    );
    let pk2 = b
        .service
        .personal_key(txn.as_mut(), KeyPurpose::Personal, current.record.key.version)
        .await
        .unwrap();
    current.record.check_key(&pk2).unwrap();
}

// Device B of P holding personal version 2 under av 2, with PK2's key wrapped to it, for the envelope rows.
async fn holding_personal_2(server: &Arc<FakeServer>, row: &str) -> (Device, ScopeKey) {
    let b = p_device(server, "P device B", row, 2).await;
    let rows = scenario("an envelope below the version in force at its place, and one before the rotation")["steps"]
        .as_array()
        .unwrap();
    let key = ScopeKey::from_bytes(bytes(&rows[0]["records"][1]["verify"]["key_hex"]));
    let pk2 = version_record("P PK2 under av 2");
    let keys = account_keys("P", 2);
    let target = scope_key_target(
        KeyRef {
            owner: p().0,
            purpose: KeyPurpose::Personal,
            version: Version::new(2).unwrap(),
        },
        p(),
        Version::new(2).unwrap(),
    );
    let wrap = Wrap::seal_scope_key(
        &origin(),
        target,
        &keys.aek.public().unwrap(),
        &key,
        Wrapper {
            account: p(),
            av: Version::new(2).unwrap(),
            key_device: world_device("P device B").key_device,
        },
        &keys.ask,
    )
    .unwrap();
    let pk2_object = KeyObject::parse(
        "key.version",
        &pk2.record_id,
        pk2.fields_json.as_deref().unwrap().as_bytes(),
    )
    .unwrap();
    let record = pk2_object.version_record().unwrap();
    b.put(vec![
        object_row(&pk2_object),
        object_row(&KeyObject {
            id: KeyRecordId::Wrap(target),
            body: KeyBody::Wrap(WrapBody::of(&wrap)),
        }),
        Row::KeyVersion(KeyVersionRow {
            scope: ScopeName::Personal,
            purpose: KeyPurpose::Personal,
            version: Version::new(2).unwrap(),
            record: record.digest(&origin()).unwrap(),
            holders: Vec::new(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        }),
    ])
    .await;
    (b, key)
}

#[tokio::test]
async fn an_envelope_below_the_version_in_force_at_its_place_is_stale_and_the_same_one_before_the_rotation_is_taken() {
    let server = FakeServer::new();
    let rows = scenario("an envelope below the version in force at its place, and one before the rotation")["steps"]
        .as_array()
        .unwrap();
    let envelope = &rows[0]["records"][1];
    let id = EnvelopeId::parse(envelope["id"].as_str().unwrap()).unwrap();
    let secret = envelope["verify"]["secret"].as_str().unwrap();

    let (after, _) = holding_personal_2(&server, "dev_b").await;
    let pk3 = after
        .feed(vec![records(&rows[0]).remove(0)], ArrivalOrder::InOrder)
        .await;
    assert_eq!(pk3.in_force, Some(Version::new(3).unwrap()));
    let stale = after
        .service
        .open_personal_envelope(id.clone(), envelope["fields"].clone(), pk3.in_force)
        .await
        .unwrap_err();
    assert_eq!(stale.code(), "keys.stale");

    let (before, _) = holding_personal_2(&server, "dev_b2").await;
    let first = &rows[1]["records"][0];
    let taken = before
        .service
        .open_personal_envelope(id, first["fields"].clone(), Some(Version::new(2).unwrap()))
        .await
        .unwrap();
    assert_eq!(taken.secret.expose_secret(), secret);
    let then = before
        .feed(vec![records(&rows[1]).remove(1)], ArrivalOrder::InOrder)
        .await;
    assert_eq!(then.in_force, Some(Version::new(3).unwrap()));
}

#[tokio::test]
async fn the_losing_device_s_own_genesis_candidates_give_way_to_the_winner_the_server_serves() {
    let server = FakeServer::new();
    let rows = scenario("two genesis change sets, and an identical retry")["steps"]
        .as_array()
        .unwrap();
    let c = Device::new(&server, p(), "dev_c").await;
    let mut candidates = Vec::new();
    for served in records(&rows[1]) {
        let object = KeyObject::parse(
            served.kind.as_str(),
            &served.record_id,
            served.fields_json.as_deref().unwrap().as_bytes(),
        )
        .unwrap();
        candidates.push(Row::KeyObject(KeyObjectRow {
            applied: false,
            ..match object_row(&object) {
                Row::KeyObject(row) => row,
                _ => unreachable!(),
            }
        }));
    }
    c.put(candidates).await;

    let applied = c.feed(records(&rows[0]), ArrivalOrder::Snapshot).await;

    assert!(applied.refused.is_empty());
    let mut txn = c.txn().await;
    let winner = KeyObject::parse(
        "key.account",
        rows[0]["records"][0]["id"].as_str().unwrap(),
        rows[0]["records"][0]["fields"].to_string().as_bytes(),
    )
    .unwrap();
    let held = c
        .service
        .held_object(
            txn.as_mut(),
            ScopeName::Personal,
            tablepro_keys::record_id::KeyKind::Account,
            &winner.id.to_wire(),
        )
        .await
        .unwrap()
        .unwrap();
    assert!(held.applied);
    assert_eq!(held.object, winner);
    drop(txn);
    assert_eq!(c.key_state().await, KeyState::NeedsApproval { request: None });
}
