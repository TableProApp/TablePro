// The approval rows of `tablepro-keys`' flow vectors, run through this side's checks with their real objects: N opens
// the approver's wraps under the DSK and IK it compared, then merges the trust plaintext over what it holds. These
// carry the G0 attacks S6-C1 and S7-C1, which must fail closed.

use serde_json::Value;
use tablepro_keys::KeysError;
use tablepro_keys::body::{AccountBody, KeyBody, KeyObject, VersionBody};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, TeamId, Version};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, Ed25519Seed, X25519Secret};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::sas::SasDevice;
use tablepro_keys::scope_key::VersionRecord;
use tablepro_keys::trust::PinHow;

use super::change_set::{Arrived, open};
use super::confirm::HeldFacts;
use super::merge::{Approver, HeldTables, Merge, Merged, merge};
use crate::api::ids::ScopeName;
use crate::api::state::{Holder, KeyPinRow, KeyVersionRow, KeyVersionState, StoppedCause};
use crate::keys::HeldObject;

// `tablepro-keys`' flows.json at 8a90c920c0 (#4568, blob 5a977fb3ea), which adds the flow device keys these rows open
// wraps with. It goes once that PR's vectors are on this branch.
const FLOWS: &str = include_str!("vectors/flows.json");

fn flows() -> Value {
    serde_json::from_str(FLOWS).unwrap()
}

fn scenario(flows: &Value, name: &str) -> Value {
    flows["scenarios"]
        .as_array()
        .unwrap()
        .iter()
        .find(|scenario| scenario["name"] == name)
        .unwrap_or_else(|| panic!("no scenario {name}"))
        .clone()
}

fn hex32(text: &str) -> [u8; 32] {
    let bytes: Vec<u8> = (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(&text[index..index + 2], 16).unwrap())
        .collect();
    bytes.try_into().unwrap()
}

fn object(record: &Value) -> KeyObject {
    let fields = serde_json::to_string(&record["fields"]).unwrap();
    KeyObject::parse(
        record["kind"].as_str().unwrap(),
        record["id"].as_str().unwrap(),
        fields.as_bytes(),
    )
    .unwrap()
}

struct World {
    origin: Origin,
    flows: Value,
}

impl World {
    fn new() -> Self {
        let flows = flows();
        Self {
            origin: Origin::parse(flows["origin"].as_str().unwrap()).unwrap(),
            flows,
        }
    }

    fn account(&self, name: &str) -> &Value {
        self.flows["world"]["accounts"]
            .as_array()
            .unwrap()
            .iter()
            .find(|account| account["name"] == name)
            .unwrap()
    }

    fn account_id(&self, name: &str) -> AccountId {
        AccountId::from_wire(self.account(name)["account"].as_str().unwrap()).unwrap()
    }

    fn ik(&self, name: &str) -> Ed25519Seed {
        RecoveryKey::from_bytes(hex32(self.account(name)["r_hex"].as_str().unwrap()))
            .identity_seed(&self.origin, self.account_id(name))
            .unwrap()
    }

    fn account_keys(&self, name: &str, av: u32) -> AccountKeys {
        let keys = self.account(name)["account_keys"]
            .as_array()
            .unwrap()
            .iter()
            .find(|keys| keys["av"] == av)
            .unwrap();
        AccountKeys {
            ask: Ed25519Seed::from_bytes(hex32(keys["ask_seed_hex"].as_str().unwrap())),
            aek: X25519Secret::from_bytes(hex32(keys["aek_secret_hex"].as_str().unwrap())),
        }
    }

    fn certificate(&self, name: &str, av: u32) -> AccountCertificate {
        AccountCertificate::sign(
            &self.origin,
            self.account_id(name),
            Version::new(av).unwrap(),
            CertKind::GenesisOrRotation,
            &self.ik(name),
            self.account_keys(name, av).public().unwrap(),
            None,
        )
        .unwrap()
    }

    fn device(&self, key_device: KeyDeviceId) -> DeviceKeys {
        let device = self.flows["world"]["devices"]
            .as_array()
            .unwrap()
            .iter()
            .find(|device| device["key_device"] == key_device.to_wire())
            .unwrap();
        DeviceKeys {
            key_device,
            dsk: Ed25519Seed::from_bytes(hex32(device["dsk_seed_hex"].as_str().unwrap())),
            dek: X25519Secret::from_bytes(hex32(device["dek_secret_hex"].as_str().unwrap())),
        }
    }
}

// The approval change set of a scenario's first step, as N found it.
struct Approval {
    n: DeviceKeys,
    approver: SasDevice,
    device: tablepro_keys::cert::DeviceCertificate,
    account_wrap: tablepro_keys::wrap::Wrap,
    trust_wrap: tablepro_keys::wrap::Wrap,
    av: Version,
}

fn approval(world: &World, step: &Value) -> Approval {
    let objects: Vec<KeyObject> = step["records"].as_array().unwrap().iter().map(object).collect();
    let device = objects
        .iter()
        .find_map(|object| match (&object.id, &object.body) {
            (
                KeyRecordId::Device {
                    account,
                    key_device,
                    av,
                },
                KeyBody::Device(body),
            ) => Some(body.certificate(*account, *key_device, *av)),
            _ => None,
        })
        .unwrap();
    let wraps: Vec<_> = objects.iter().filter_map(KeyObject::wrap).collect();
    let account_wrap = wraps
        .iter()
        .find(|wrap| wrap.target.purpose == tablepro_keys::encoding::WrapPurpose::Account)
        .unwrap()
        .clone();
    let trust_wrap = wraps
        .iter()
        .find(|wrap| wrap.target.purpose == tablepro_keys::encoding::WrapPurpose::Trust)
        .unwrap()
        .clone();
    let approver_keys = world.device(account_wrap.wrapper.key_device);
    Approval {
        n: world.device(device.key_device),
        approver: SasDevice {
            key_device: approver_keys.key_device,
            dek: approver_keys.dek.public().unwrap(),
            dsk: approver_keys.dsk.public().unwrap(),
        },
        av: device.av,
        device,
        account_wrap,
        trust_wrap,
    }
}

fn held(object: KeyObject) -> HeldObject {
    HeldObject {
        fields: object.fields_json(),
        object,
        applied: true,
    }
}

fn version_object(record: &VersionRecord) -> HeldObject {
    held(KeyObject {
        id: KeyRecordId::Version(record.key),
        body: KeyBody::Version(VersionBody::of(record)),
    })
}

fn certificate_object(certificate: &AccountCertificate) -> HeldObject {
    held(KeyObject {
        id: KeyRecordId::Account {
            account: certificate.account,
            av: certificate.av,
        },
        body: KeyBody::Account(AccountBody::of(certificate)),
    })
}

fn records(list: &Value) -> Vec<VersionRecord> {
    list.as_array()
        .map(|list| {
            list.iter()
                .map(|record| object(record).version_record().unwrap())
                .collect()
        })
        .unwrap_or_default()
}

// The rows concern the personal key, and the trust plaintexts carry no history version. The history key works the same
// way, so N holds it current under the merged `av` and only the personal key decides.
fn history_at_av2(world: &World) -> VersionRecord {
    let key = tablepro_keys::scope_key::KeyRef {
        owner: world.account_id("P").0,
        purpose: KeyPurpose::History,
        version: Version::new(2).unwrap(),
    };
    VersionRecord::sign(
        &world.origin,
        key,
        tablepro_keys::scope_key::Start::Next,
        &tablepro_keys::keys::ScopeKey::from_bytes([0x48; 32]),
        world.account_id("P"),
        Version::new(2).unwrap(),
        &world.account_keys("P", 2).ask,
    )
    .unwrap()
}

fn with_history(world: &World, held: &[VersionRecord]) -> Vec<VersionRecord> {
    let mut held = held.to_vec();
    held.push(history_at_av2(world));
    held
}

fn own_rows(world: &World, held: &[VersionRecord]) -> Vec<KeyVersionRow> {
    let mut rows: Vec<KeyVersionRow> = Vec::new();
    for record in held {
        let row = KeyVersionRow {
            scope: ScopeName::Personal,
            purpose: record.key.purpose,
            version: record.key.version,
            record: record.digest(&world.origin).unwrap(),
            holders: Vec::new(),
            state: KeyVersionState::Ok,
            stopped_cause: None,
            epoch: None,
        };
        match rows.iter_mut().find(|held| held.purpose == row.purpose) {
            Some(held) if held.version < row.version => *held = row,
            Some(_) => {}
            None => rows.push(row),
        }
    }
    rows
}

fn own_pin(world: &World, av: u32) -> KeyPinRow {
    KeyPinRow {
        account: world.account_id("P"),
        ik: world.ik("P").public().unwrap(),
        av: Version::new(av).unwrap(),
        how: PinHow::FirstUse,
        alert: false,
        replaced: Vec::new(),
    }
}

// N's checks on the approval, then the merge over `held`, with `n_holds` and then `server_holds` in its key objects.
fn run(
    world: &World,
    scenario: &Value,
    held: &HeldTables,
    n_holds: &[VersionRecord],
    server_holds: &[VersionRecord],
) -> Result<Merge, KeysError> {
    let approval = approval(world, &scenario["steps"][0]);
    let certificate = world.certificate("P", approval.av.get());
    let ik = world.ik("P").public().unwrap();
    let opened = open(
        &world.origin,
        world.account_id("P"),
        &approval.n,
        &approval.approver,
        &ik,
        &Arrived {
            certificate: &certificate,
            device: &approval.device,
            account_wrap: &approval.account_wrap,
            trust_wrap: &approval.trust_wrap,
        },
    )?;
    // N's own records, then the server's at every id N does not hold, all checked as the production merge checks them.
    let mut versions = n_holds.to_vec();
    for record in server_holds {
        if !versions.iter().any(|held| held.key == record.key) {
            versions.push(record.clone());
        }
    }
    let held_versions: Vec<HeldObject> = versions.iter().map(version_object).collect();
    let certificates: Vec<HeldObject> = [1, 2]
        .into_iter()
        .map(|av| certificate_object(&world.certificate("P", av)))
        .collect();
    let facts = HeldFacts::from_objects(&world.origin, world.account_id("P"), &held_versions, &certificates, &[]);
    merge(
        held,
        &Approver {
            account: world.account_id("P"),
            ik,
            av: opened.av,
            trust: &opened.trust,
            device: approval.approver,
        },
        &facts,
    )
}

fn merged(merge: Merge) -> Merged {
    match merge {
        Merge::Merged(merged) => *merged,
        Merge::Waiting { .. } => panic!("the merge waits"),
    }
}

fn personal(merged: &Merged) -> &KeyVersionRow {
    merged
        .versions
        .iter()
        .find(|row| row.purpose == KeyPurpose::Personal)
        .unwrap()
}

#[test]
fn every_approval_scenario_names_the_code_this_side_answers() {
    let world = World::new();
    for (name, code) in [
        (
            "C kept on av 1 holds versions 2 and 3 under the old key; B approves C",
            Some("keys.conflict"),
        ),
        ("the same C after an anchored rebuild that kept only version 3", None),
        ("the pair the other way", None),
        (
            "neither side holds a personal version under the merged av",
            Some("keys.stale"),
        ),
    ] {
        let scenario = scenario(&world.flows, name);
        let codes: Vec<&str> = scenario["client_codes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|code| code.as_str().unwrap())
            .collect();
        assert_eq!(codes.first().copied(), code, "{name}");
    }
}

// S7-C1: C, kept on `av` 1, took personal versions 2 and 3 signed under the old account key and still holds its
// version 2. B approves C: `keys.conflict` at version 2, and no old-key version becomes current.
#[test]
fn s7_c1_b_approving_a_stale_c_fails_with_keys_conflict() {
    let world = World::new();
    let scenario = scenario(
        &world.flows,
        "C kept on av 1 holds versions 2 and 3 under the old key; B approves C",
    );
    let c_holds = with_history(&world, &records(&scenario["given"]["c_holds"]));
    let held = HeldTables {
        pins: vec![own_pin(&world, 1)],
        versions: own_rows(&world, &c_holds),
    };

    let error = run(
        &world,
        &scenario,
        &held,
        &c_holds,
        &records(&scenario["given"]["b_holds"]),
    )
    .unwrap_err();

    assert_eq!(error.code(), "keys.conflict");
}

#[test]
fn s7_c1_after_an_anchored_rebuild_c_takes_b_s_version_2_and_never_its_version_3() {
    let world = World::new();
    let scenario = scenario(
        &world.flows,
        "the same C after an anchored rebuild that kept only version 3",
    );
    let c_holds = with_history(&world, &records(&scenario["given"]["c_holds"]));
    let b_holds = records(&scenario["given"]["b_holds"]);
    let held = HeldTables {
        pins: vec![own_pin(&world, 1)],
        versions: own_rows(&world, &c_holds),
    };

    let merged = merged(run(&world, &scenario, &held, &c_holds, &b_holds).unwrap());

    let row = personal(&merged);
    assert_eq!(row.version, b_holds[0].key.version);
    assert_eq!(row.record, b_holds[0].digest(&world.origin).unwrap());
    assert_eq!(
        merged
            .pins
            .iter()
            .find(|pin| pin.account == world.account_id("P"))
            .unwrap()
            .av
            .get(),
        2
    );
}

#[test]
fn s7_c1_the_other_way_b_keeps_its_version_2() {
    let world = World::new();
    let scenario = scenario(&world.flows, "the pair the other way");
    let c_holds = records(&scenario["given"]["c_holds"]);
    let b_holds = records(&scenario["given"]["b_holds"]);
    let b_tables = with_history(&world, &b_holds);
    let held = HeldTables {
        pins: vec![own_pin(&world, 2)],
        versions: own_rows(&world, &b_tables),
    };

    let merged = merged(run(&world, &scenario, &held, &b_tables, &c_holds).unwrap());

    let row = personal(&merged);
    assert_eq!(row.version, b_holds[0].key.version);
    assert_eq!(row.record, b_holds[0].digest(&world.origin).unwrap());
}

#[test]
fn neither_side_holding_a_version_under_the_merged_av_is_keys_stale_on_the_vectors() {
    let world = World::new();
    let scenario = scenario(
        &world.flows,
        "neither side holds a personal version under the merged av",
    );
    let both = records(&scenario["given"]["both_hold"]);
    let n_holds = with_history(&world, &both);
    let held = HeldTables {
        pins: vec![own_pin(&world, 1)],
        versions: own_rows(&world, &n_holds),
    };

    let error = run(&world, &scenario, &held, &n_holds, &both).unwrap_err();

    assert_eq!(error, KeysError::Stale { held: 2, offered: 1 });
}

// S6-C1: B saw A's rotation and holds team version 6. C took versions 7 and 8 on a view the server kept behind and
// approves B. B keeps version 6 with its holders and state, stopped or not; version 8 is only a hint.
#[test]
fn s6_c1_b_keeps_team_version_6_stopped_or_not() {
    let world = World::new();
    let scenario = scenario(
        &world.flows,
        "B keeps team version 6 when approved from a C the server kept behind",
    );
    let team = TeamId::from_wire(world.flows["world"]["team"].as_str().unwrap()).unwrap();
    let world_records = records(&world.flows["world"]["version_records"]);
    let labels: Vec<&str> = world.flows["world"]["version_records"]
        .as_array()
        .unwrap()
        .iter()
        .map(|record| record["label"].as_str().unwrap())
        .collect();
    let by_label = |label: &str| world_records[labels.iter().position(|held| *held == label).unwrap()].clone();
    let pk2 = with_history(&world, &[by_label("P PK2")]);
    let team_six = by_label("team 6");
    for state in [KeyVersionState::Ok, KeyVersionState::Stopped] {
        let six = KeyVersionRow {
            scope: ScopeName::Team(team),
            purpose: KeyPurpose::Team,
            version: Version::new(6).unwrap(),
            record: team_six.digest(&world.origin).unwrap(),
            holders: vec![
                Holder {
                    account: world.account_id("A"),
                    ik: world.ik("A").public().unwrap(),
                },
                Holder {
                    account: world.account_id("P"),
                    ik: world.ik("P").public().unwrap(),
                },
            ],
            stopped_cause: (state == KeyVersionState::Stopped).then_some(StoppedCause::CatchUp),
            state,
            epoch: None,
        };
        let mut versions = own_rows(&world, &pk2);
        versions.push(six.clone());
        let held = HeldTables {
            pins: vec![own_pin(&world, 2)],
            versions,
        };

        let merged = merged(run(&world, &scenario, &held, &pk2, &pk2).unwrap());

        let kept = merged
            .versions
            .iter()
            .find(|row| row.scope == ScopeName::Team(team))
            .unwrap();
        assert_eq!(kept, &six);
        assert_eq!(merged.hints, vec![team]);
    }
}
