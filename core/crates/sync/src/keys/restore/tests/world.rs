// The world of `tablepro-keys`' flow vectors (`core/crates/keys/vectors/flows.json`): its accounts, devices, team and
// team keys, its scenarios' records as the server would serve them, and the objects a scenario leaves implicit, signed
// with the same keys.

use serde_json::Value;
use tablepro_keys::body::{AccountBody, KeyBody, KeyObject, VersionBody, WrapBody};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, TeamId, Version, uuid_from_wire};
use tablepro_keys::keys::{AccountPublicKeys, Ed25519Seed, ScopeKey, X25519Secret};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Ring, Start, VersionRecord};
use tablepro_keys::wrap::{Wrap, Wrapper, scope_key_target};

use crate::keys::HeldObject;

const FLOWS: &str = include_str!("../../../../../keys/vectors/flows.json");

pub(crate) struct World {
    pub origin: Origin,
    pub team: TeamId,
    json: Value,
}

fn bytes32(text: &str) -> [u8; 32] {
    let bytes: Vec<u8> = (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap())
        .collect();
    bytes.try_into().unwrap()
}

pub(crate) fn v(number: u32) -> Version {
    Version::new(number).unwrap()
}

pub(crate) fn held(object: KeyObject) -> HeldObject {
    HeldObject {
        fields: object.fields_json(),
        object,
        applied: true,
    }
}

impl World {
    pub fn load() -> Self {
        let json: Value = serde_json::from_str(FLOWS).unwrap();
        let origin = Origin::parse(json["origin"].as_str().unwrap()).unwrap();
        let team = TeamId(uuid_from_wire(json["world"]["team"].as_str().unwrap()).unwrap());
        Self { origin, team, json }
    }

    fn named<'a>(&'a self, list: &str, name: &str) -> &'a Value {
        self.json["world"][list]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["name"] == name)
            .unwrap_or_else(|| panic!("no {list} entry {name}"))
    }

    pub fn account(&self, name: &str) -> AccountId {
        AccountId(uuid_from_wire(self.named("accounts", name)["account"].as_str().unwrap()).unwrap())
    }

    // A key device of an account that writes a team wrap. The vectors fix none outside the personal records, and a
    // team wrap's checks never read it.
    pub fn device(&self, name: &str) -> KeyDeviceId {
        let seed = name.bytes().fold(0_u128, |hash, byte| {
            hash.wrapping_mul(131).wrapping_add(u128::from(byte))
        });
        KeyDeviceId(uuid::Uuid::from_u128(seed))
    }

    // The key device a scenario's `key.device` record certifies.
    pub fn certified_device(&self, scenario: &str, label: &str) -> KeyDeviceId {
        match self.record(scenario, label).object.id {
            KeyRecordId::Device { key_device, .. } => key_device,
            other => panic!("{other:?} is not a device certificate"),
        }
    }

    pub fn ik(&self, name: &str) -> Ed25519Seed {
        let r = RecoveryKey::from_bytes(bytes32(self.named("accounts", name)["r_hex"].as_str().unwrap()));
        r.identity_seed(&self.origin, self.account(name)).unwrap()
    }

    fn keys_at<'a>(&'a self, name: &str, av: u32) -> &'a Value {
        self.named("accounts", name)["account_keys"]
            .as_array()
            .unwrap()
            .iter()
            .find(|keys| keys["av"] == av)
            .unwrap()
    }

    pub fn ask(&self, name: &str, av: u32) -> Ed25519Seed {
        Ed25519Seed::from_bytes(bytes32(self.keys_at(name, av)["ask_seed_hex"].as_str().unwrap()))
    }

    pub fn public(&self, name: &str, av: u32) -> AccountPublicKeys {
        let aek = X25519Secret::from_bytes(bytes32(self.keys_at(name, av)["aek_secret_hex"].as_str().unwrap()));
        AccountPublicKeys {
            ask: self.ask(name, av).public().unwrap(),
            aek: aek.public().unwrap(),
        }
    }

    pub fn team_key(&self, version: u32) -> ScopeKey {
        let entry = self.json["world"]["team_keys"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["version"] == version)
            .unwrap();
        ScopeKey::from_bytes(bytes32(entry["key_hex"].as_str().unwrap()))
    }

    fn records(&self, scenario: &str) -> Vec<&Value> {
        let scenario = self.json["scenarios"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["name"] == scenario)
            .unwrap_or_else(|| panic!("no scenario {scenario}"));
        scenario["steps"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|step| step["records"].as_array().into_iter().flatten())
            .collect()
    }

    // A scenario's record by its label, parsed as a pull serves it.
    pub fn record(&self, scenario: &str, label: &str) -> HeldObject {
        let record = self
            .records(scenario)
            .into_iter()
            .find(|record| record["label"] == label)
            .unwrap_or_else(|| panic!("no record {label} in {scenario}"));
        let fields = record["fields"].to_string();
        HeldObject {
            object: KeyObject::parse(
                record["kind"].as_str().unwrap(),
                record["id"].as_str().unwrap(),
                fields.as_bytes(),
            )
            .unwrap(),
            fields,
            applied: true,
        }
    }

    // Every record of a scenario whose label starts with `prefix`, in order.
    pub fn records_labelled(&self, scenario: &str, prefix: &str) -> Vec<HeldObject> {
        self.records(scenario)
            .into_iter()
            .filter(|record| record["label"].as_str().unwrap().starts_with(prefix))
            .map(|record| self.record(scenario, record["label"].as_str().unwrap()))
            .collect()
    }

    pub fn certificate(&self, name: &str, av: u32, kind: CertKind) -> AccountCertificate {
        AccountCertificate::sign(
            &self.origin,
            self.account(name),
            v(av),
            kind,
            &self.ik(name),
            self.public(name, av),
            None,
        )
        .unwrap()
    }

    pub fn member(&self, name: &str, av: u32) -> HeldObject {
        let certificate = self.certificate(name, av, CertKind::GenesisOrRotation);
        held(KeyObject {
            id: KeyRecordId::Member {
                account: self.account(name),
                av: v(av),
            },
            body: KeyBody::Member(AccountBody::of(&certificate)),
        })
    }

    pub fn team_ref(&self, version: u32) -> KeyRef {
        KeyRef {
            owner: self.team.0,
            purpose: KeyPurpose::Team,
            version: v(version),
        }
    }

    pub fn team_version(&self, version: u32, signer: &str, signer_av: u32, start: Start) -> HeldObject {
        let key = self.team_ref(version);
        let record = VersionRecord::sign(
            &self.origin,
            key,
            start,
            &self.team_key(version),
            self.account(signer),
            v(signer_av),
            &self.ask(signer, signer_av),
        )
        .unwrap();
        held(KeyObject {
            id: KeyRecordId::Version(key),
            body: KeyBody::Version(VersionBody::of(&record)),
        })
    }

    pub fn team_ring(&self, version: u32) -> HeldObject {
        let key = self.team_ref(version);
        let ring = Ring::seal(&self.origin, key, &self.team_key(version), &self.team_key(version - 1)).unwrap();
        held(KeyObject {
            id: KeyRecordId::Ring(key),
            body: KeyBody::Ring(ring),
        })
    }

    pub fn team_wrap(
        &self,
        version: u32,
        (wrapper, wrapper_av): (&str, u32),
        (recipient, recipient_av): (&str, u32),
    ) -> HeldObject {
        let target = scope_key_target(self.team_ref(version), self.account(recipient), v(recipient_av));
        let wrap = Wrap::seal_scope_key(
            &self.origin,
            target,
            &self.public(recipient, recipient_av).aek,
            &self.team_key(version),
            Wrapper {
                account: self.account(wrapper),
                av: v(wrapper_av),
                key_device: self.device(wrapper),
            },
            &self.ask(wrapper, wrapper_av),
        )
        .unwrap();
        held(KeyObject {
            id: KeyRecordId::Wrap(target),
            body: KeyBody::Wrap(WrapBody::of(&wrap)),
        })
    }
}
