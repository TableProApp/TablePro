use std::cell::RefCell;
use std::collections::HashMap;

use uuid::Uuid;

use crate::crypto;
use crate::encoding::{AccountId, KeyDeviceId, Origin, TeamId, Version, uuid_from_wire};
use crate::json::JsonValue;
use crate::keys::{AccountKeys, DeviceKeys, Ed25519Public, Ed25519Seed, ScopeKey, X25519Public, X25519Secret};
use crate::recovery::RecoveryKey;
use crate::wrap::{Wrap, WrapTarget, Wrapper, wrap_info, wrap_sig_message};

pub(super) const ORIGIN: &str = "https://sync.example.com";
pub(super) const ACCOUNT_A: &str = "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8";
pub(super) const ACCOUNT_M: &str = "019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90";
pub(super) const TEAM_T: &str = "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63";

pub(super) fn origin() -> Origin {
    Origin::parse(ORIGIN).expect("fixture origin")
}

// Every random input of a case is drawn from its name, so a run reproduces the same bytes.
pub(super) fn draw<const N: usize>(name: &str) -> [u8; N] {
    let mut out = [0_u8; N];
    let mut counter = 0_u32;
    let mut filled = 0;
    while filled < N {
        let mut input = b"tablepro-keys vectors/".to_vec();
        input.extend_from_slice(name.as_bytes());
        input.extend_from_slice(&counter.to_be_bytes());
        let block = crypto::sha256(&input);
        let take = (N - filled).min(32);
        out[filled..filled + take].copy_from_slice(&block[..take]);
        filled += take;
        counter += 1;
    }
    out
}

pub(super) fn draw_uuid(name: &str) -> Uuid {
    uuid::Builder::from_random_bytes(draw::<16>(name)).into_uuid()
}

pub(super) fn v(value: u32) -> Version {
    Version::new(value).expect("fixture version")
}

pub(super) fn account_id(text: &str) -> AccountId {
    AccountId(uuid_from_wire(text).expect("fixture id"))
}

pub(super) fn team_id() -> TeamId {
    TeamId(uuid_from_wire(TEAM_T).expect("fixture id"))
}

pub(super) struct Account {
    pub id: AccountId,
    pub r: RecoveryKey,
    pub ik: Ed25519Seed,
    // Index av - 1.
    pub keys: Vec<AccountKeys>,
}

impl Account {
    pub(super) fn new(name: &str, id: &str, avs: u32) -> Self {
        let id = account_id(id);
        let r = RecoveryKey::from_bytes(draw(&format!("{name}/R")));
        let ik = r.identity_seed(&origin(), id).expect("identity seed");
        let keys = (1..=avs)
            .map(|av| AccountKeys {
                ask: Ed25519Seed::from_bytes(draw(&format!("{name}/av{av}/ask"))),
                aek: X25519Secret::from_bytes(draw(&format!("{name}/av{av}/aek"))),
            })
            .collect();
        Self { id, r, ik, keys }
    }

    pub(super) fn at(&self, av: u32) -> &AccountKeys {
        &self.keys[av as usize - 1]
    }

    pub(super) fn ask(&self, av: u32) -> Ed25519Public {
        self.at(av).ask.public().expect("public")
    }

    pub(super) fn aek(&self, av: u32) -> X25519Public {
        self.at(av).aek.public().expect("public")
    }

    pub(super) fn ik_public(&self) -> Ed25519Public {
        self.ik.public().expect("public")
    }
}

pub(super) fn device(name: &str) -> DeviceKeys {
    DeviceKeys {
        key_device: KeyDeviceId(draw_uuid(&format!("{name}/key device"))),
        dsk: Ed25519Seed::from_bytes(draw(&format!("{name}/dsk"))),
        dek: X25519Secret::from_bytes(draw(&format!("{name}/dek"))),
    }
}

pub(super) fn scope_key(name: &str) -> ScopeKey {
    ScopeKey::from_bytes(draw(name))
}

// HPKE draws its own ephemeral key, so a wrap's `enc` and `ct` come from a committed wrap at the
// same record id while they still open to the case's plaintext under its key and `info`.
type Sealed = Vec<([u8; 32], Vec<u8>)>;

// A seal made during a run joins the cache, so a wrap built twice in one run is the same both times.
pub(super) struct HpkeCache {
    entries: RefCell<HashMap<String, Sealed>>,
}

impl HpkeCache {
    pub(super) fn from_committed(files: &[JsonValue]) -> Self {
        let mut entries = HashMap::new();
        for file in files {
            collect(file, &mut entries);
        }
        Self {
            entries: RefCell::new(entries),
        }
    }

    pub(super) fn seal(&self, id: &str, secret: &X25519Secret, info: &[u8], plaintext: &[u8]) -> ([u8; 32], Vec<u8>) {
        let mut entries = self.entries.borrow_mut();
        let found = entries.entry(id.to_owned()).or_default();
        for (enc, ct) in found.iter() {
            if crypto::hpke_open(secret.expose(), enc, info, ct).is_ok_and(|opened| opened.as_slice() == plaintext) {
                return (*enc, ct.clone());
            }
        }
        let sealed = crypto::hpke_seal(&secret.public().expect("public").0, info, plaintext).expect("seal");
        found.push(sealed.clone());
        sealed
    }

    // A wrap as `Wrap::seal` makes it, with its HPKE output from the cache.
    pub(super) fn wrap(
        &self,
        target: WrapTarget,
        recipient: &X25519Secret,
        plaintext: &[u8],
        wrapper: Wrapper,
        signer: &Ed25519Seed,
    ) -> Wrap {
        let pk_r = recipient.public().expect("public");
        let info = wrap_info(&origin(), target, &pk_r).expect("info");
        let id = crate::record_id::KeyRecordId::Wrap(target).to_wire();
        let (enc, ct) = self.seal(&id, recipient, &info, plaintext);
        let sig = signer
            .sign(&wrap_sig_message(&info, &enc, &ct, wrapper).expect("message"))
            .expect("sign");
        Wrap {
            target,
            enc,
            ct,
            wrapper,
            sig,
        }
    }
}

fn collect(value: &JsonValue, entries: &mut HashMap<String, Sealed>) {
    match value {
        JsonValue::Object(members) => {
            let get = |name: &str| {
                members
                    .iter()
                    .find(|(member, _)| member == name)
                    .map(|(_, value)| value)
            };
            // Read from the members, not through the parser, which refuses a record past 1 MiB.
            if let (Some(JsonValue::String(kind)), Some(JsonValue::String(id)), Some(JsonValue::Object(fields))) =
                (get("kind"), get("id"), get("fields"))
                && kind == "key.wrap"
                && let (Some((_, JsonValue::String(enc))), Some((_, JsonValue::String(ct)))) = (
                    fields.iter().find(|(member, _)| member == "enc"),
                    fields.iter().find(|(member, _)| member == "ct"),
                )
                && let (Ok(enc), Ok(ct)) = (crate::b64::decode_exact::<32>(enc), crate::b64::decode(ct))
            {
                let found = entries.entry(id.clone()).or_default();
                if !found.iter().any(|(held, _)| *held == enc) {
                    found.push((enc, ct));
                }
            }
            for (_, member) in members {
                collect(member, entries);
            }
        }
        JsonValue::Array(items) => items.iter().for_each(|item| collect(item, entries)),
        _ => {}
    }
}
