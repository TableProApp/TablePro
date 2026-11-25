// Checks a case from its inputs alone, through the crate's own API: the outputs it lists, or the
// client error it names. The Go side runs the same files.

use secrecy::ExposeSecret;
use zeroize::Zeroizing;

use super::out::{arr, b, h, n, s};
use crate::KeysError;
use crate::b64;
use crate::base32;
use crate::body::{KeyBody, KeyObject, check_same_object, parse_sealed};
use crate::cert::IkChange;
use crate::check::{check_not_below, check_record_digest, check_signed_under_newest, check_step};
use crate::crypto;
use crate::dpop::{self, DpopRequest};
use crate::encoding::{
    AccountId, Frame, HistoryId, KeyDeviceId, Label, Origin, RequestId, Scope, TeamId, Version, WrapPurpose, lp,
    uuid_from_wire,
};
use crate::envelope::{
    EnvelopeId, check_destination, envelope_aad, envelope_subkey, history_aad, history_subkey, open_envelope,
    open_history,
};
use crate::fingerprint::{fingerprint, fingerprint_words, parse_qr, qr_text};
use crate::json::{JsonValue, Members};
use crate::keys::{
    AccountKeys, AccountPublicKeys, Ed25519Public, Ed25519Seed, ScopeKey, Signature, X25519Public, X25519Secret,
};
use crate::padding;
use crate::record_id::KeyRecordId;
use crate::recovery::{RecoveryKey, blob_aad};
use crate::sas::{Comparison, SasDevice, Transcript};
use crate::scope_key::{KeyRef, ring_aad};
use crate::state_mac::{StateSnapshot, state_mac, state_mac_input};
use crate::trust::TrustPlaintext;
use crate::words::{word_indexes, words};
use crate::wrap::wrap_info;

pub(super) struct In<'a>(Members<'a>);

impl<'a> In<'a> {
    pub(super) fn of(value: &'a JsonValue) -> Self {
        Self(Members::of(value).expect("input object"))
    }

    pub(super) fn optional(&mut self, name: &str) -> Option<&'a JsonValue> {
        self.0.optional(name)
    }

    pub(super) fn has(&mut self, name: &str) -> bool {
        self.0
            .optional(name)
            .is_some_and(|value| !matches!(value, JsonValue::Null))
    }

    pub(super) fn str(&mut self, name: &str) -> &'a str {
        self.0.string(name).unwrap_or_else(|_| panic!("input {name}"))
    }

    pub(super) fn value(&mut self, name: &str) -> &'a JsonValue {
        self.0.required(name).unwrap_or_else(|_| panic!("input {name}"))
    }

    pub(super) fn u64(&mut self, name: &str) -> u64 {
        match self.value(name) {
            JsonValue::Number(number) => number.as_u64().expect("unsigned"),
            other => panic!("input {name} is {other:?}"),
        }
    }

    pub(super) fn u32(&mut self, name: &str) -> u32 {
        u32::try_from(self.u64(name)).expect("u32")
    }

    pub(super) fn version(&mut self, name: &str) -> Version {
        Version::new(self.u32(name)).expect("version")
    }

    pub(super) fn hex(&mut self, name: &str) -> Vec<u8> {
        hex::decode(self.str(name)).expect("hex")
    }

    pub(super) fn hex32(&mut self, name: &str) -> [u8; 32] {
        self.hex(name).try_into().expect("32 bytes")
    }

    pub(super) fn origin(&mut self) -> Origin {
        Origin::parse(self.str("origin")).expect("origin")
    }

    pub(super) fn account(&mut self, name: &str) -> AccountId {
        AccountId(uuid_from_wire(self.str(name)).expect("account"))
    }

    pub(super) fn sub(&mut self, name: &str) -> In<'a> {
        In::of(self.value(name))
    }
}

type Outputs = Vec<(&'static str, JsonValue)>;

fn record_object(value: &JsonValue) -> Result<KeyObject, KeysError> {
    let mut record = In::of(value);
    let kind = record.str("kind").to_owned();
    let id = record.str("id").to_owned();
    let fields = match record.value("fields") {
        JsonValue::String(text) => text.clone(),
        other => other.to_json(),
    };
    KeyObject::parse(&kind, &id, fields.as_bytes())
}

fn object_from_text(value: &JsonValue) -> Result<KeyObject, KeysError> {
    let mut object = In::of(value);
    let kind = object.str("kind").to_owned();
    let id = object.str("id").to_owned();
    let text = object.str("fields_text").to_owned();
    KeyObject::parse(&kind, &id, text.as_bytes())
}

fn scope_of(value: &JsonValue) -> Scope {
    let mut scope = In::of(value);
    let owner = uuid_from_wire(scope.str("owner")).expect("owner");
    match scope.str("type") {
        "personal" => Scope::Personal(AccountId(owner)),
        "history" => Scope::History(AccountId(owner)),
        _ => Scope::Team(TeamId(owner)),
    }
}

fn sas_device(value: &JsonValue) -> SasDevice {
    let mut device = In::of(value);
    SasDevice {
        key_device: KeyDeviceId(uuid_from_wire(device.str("key_device")).expect("id")),
        dek: X25519Public(device.hex32("dek_hex")),
        dsk: Ed25519Public(device.hex32("dsk_hex")),
    }
}

struct SasView {
    transcript: Transcript,
    n: SasDevice,
    r_n: [u8; 32],
    a: SasDevice,
    r_a: [u8; 32],
}

fn sas_view(input: &mut In<'_>) -> SasView {
    SasView {
        transcript: Transcript {
            origin: input.origin(),
            account: input.account("account"),
            request: RequestId(uuid_from_wire(input.str("request")).expect("request")),
            ik: Ed25519Public(input.hex32("ik_hex")),
        },
        n: sas_device(input.value("n")),
        r_n: input.hex32("r_n_hex"),
        a: sas_device(input.value("a")),
        r_a: input.hex32("r_a_hex"),
    }
}

fn words_json(list: &[&str]) -> JsonValue {
    arr(list.iter().map(|word| s(word)).collect())
}

fn indexes_json(digest: &[u8; 32], count: usize) -> JsonValue {
    arr(word_indexes(digest, count)
        .into_iter()
        .map(|index| n(u64::from(index)))
        .collect())
}

fn ok() -> Outputs {
    vec![("ok", b(true))]
}

#[expect(clippy::too_many_lines, reason = "one arm per op the vectors name")]
pub(super) fn run(op: &str, input: &JsonValue) -> Result<Outputs, KeysError> {
    let mut input = In::of(input);
    let outputs = match op {
        "lp" => {
            if input.has("bytes_hex") {
                vec![("lp_hex", h(&lp(&input.hex("bytes_hex"))?))]
            } else {
                let byte = input.hex("repeat_byte_hex")[0];
                let framed = lp(&vec![byte; usize::try_from(input.u64("repeat_count")).expect("count")])?;
                vec![
                    ("lp_prefix_hex", h(&framed[..4])),
                    ("lp_sha256_hex", h(&crypto::sha256(&framed))),
                ]
            }
        }
        "uuid" => {
            let uuid = uuid_from_wire(input.str("uuid"))?;
            vec![("bytes_hex", h(uuid.as_bytes())), ("lp_hex", h(&lp(uuid.as_bytes())?))]
        }
        "record_id_text" => vec![("lp_hex", h(&lp(input.str("record_id").as_bytes())?))],
        "scope" => {
            let owner = uuid_from_wire(input.str("owner"))?;
            let scope = match input.str("type") {
                "personal" => Scope::Personal(AccountId(owner)),
                "history" => Scope::History(AccountId(owner)),
                _ => Scope::Team(TeamId(owner)),
            };
            vec![("bytes_hex", h(&scope.bytes()))]
        }
        "purpose" => {
            let purpose = WrapPurpose::parse(input.str("purpose"))?;
            vec![("lp_hex", h(&lp(purpose.name().as_bytes())?))]
        }
        "label" => {
            let label = input.str("label");
            let mut frame = Frame::empty();
            frame.lp(label.as_bytes()).lp(b"tp1");
            vec![("prefix_hex", h(&frame.finish()?))]
        }
        "origin" => {
            let origin = Origin::of_url(input.str("url"))?;
            vec![
                ("origin", s(origin.as_str())),
                ("lp_hex", h(&lp(origin.as_str().as_bytes())?)),
            ]
        }
        "base64url" => {
            let bytes = b64::decode(input.str("text"))?;
            if bytes.len() as u64 != input.u64("len") {
                return Err(KeysError::encoding("wrong byte length"));
            }
            vec![("bytes_hex", h(&bytes))]
        }
        "base32" => vec![("text", s(&base32::encode(&input.hex("bytes_hex"))))],
        "version" => {
            Version::from_i64(i64::try_from(input.u64("value")).expect("i64"))?;
            ok()
        }
        "padded_len" => vec![(
            "padded_len",
            n(padding::padded_len(usize::try_from(input.u64("n")).expect("n"))? as u64),
        )],
        "unpad" => {
            padding::unpad(&input.hex("padded_hex"))?;
            ok()
        }
        "recovery_text" => {
            let r = RecoveryKey::from_bytes(input.hex32("r_hex"));
            let mut frame = Frame::new(Label::RecoveryChecksum);
            frame.lp(r.expose());
            let checksum_input = frame.finish()?;
            let checksum = crypto::sha256(&checksum_input);
            let mut b_bytes = r.expose().to_vec();
            b_bytes.extend_from_slice(&checksum[..3]);
            vec![
                ("checksum_input_hex", h(&checksum_input)),
                ("checksum_hex", h(&checksum[..3])),
                ("b_hex", h(&b_bytes)),
                ("text", s(r.to_text()?.expose_secret())),
            ]
        }
        "recovery_parse" => vec![("r_hex", h(RecoveryKey::parse(input.str("text"))?.expose()))],
        "identity_seed" => {
            let origin = input.origin();
            let account = input.account("account");
            let r = RecoveryKey::from_bytes(input.hex32("r_hex"));
            let seed = r.identity_seed(&origin, account)?;
            let mut info = Frame::new(Label::Identity);
            info.origin(&origin).id(account.0);
            let mut key_info = Frame::new(Label::RecoveryWrap);
            key_info.origin(&origin).id(account.0);
            vec![
                ("info_hex", h(&info.finish()?)),
                ("seed_hex", h(seed.expose())),
                ("ik_hex", h(&seed.public()?.0)),
                ("k_rec_info_hex", h(&key_info.finish()?)),
                ("k_rec_hex", h(&*r.blob_key(&origin, account)?)),
            ]
        }
        "recovery_blob" => {
            let origin = input.origin();
            let account = input.account("account");
            let av = input.version("av");
            let r = RecoveryKey::from_bytes(input.hex32("r_hex"));
            let keys = AccountKeys {
                ask: Ed25519Seed::from_bytes(input.hex32("ask_seed_hex")),
                aek: X25519Secret::from_bytes(input.hex32("aek_secret_hex")),
            };
            let nonce: [u8; 12] = input.hex("nonce_hex").try_into().expect("nonce");
            let blob = r.seal_blob_with_nonce(&origin, account, av, &keys, nonce)?;
            let opened = r.open_blob(&origin, account, av, &blob)?;
            assert_eq!(opened.to_plaintext(), keys.to_plaintext());
            vec![
                ("aad_hex", h(&blob_aad(&origin, account, av)?)),
                ("plaintext_hex", h(keys.to_plaintext().as_slice())),
                ("ct_hex", h(&blob.ct)),
                (
                    "record",
                    super::gen_basic::record(
                        "key.recovery",
                        &KeyRecordId::Recovery { account, av }.to_wire(),
                        &crate::body::body_json(&KeyBody::Recovery(blob)),
                    ),
                ),
            ]
        }
        "recovery_blob_open" => {
            let origin = input.origin();
            let account = input.account("account");
            let av = input.version("av");
            let r = RecoveryKey::from_bytes(input.hex32("r_hex"));
            let fields = input.value("fields").to_json();
            let KeyObject {
                body: KeyBody::Recovery(blob),
                ..
            } = KeyObject::parse(
                "key.recovery",
                &KeyRecordId::Recovery { account, av }.to_wire(),
                fields.as_bytes(),
            )?
            else {
                panic!("a recovery record");
            };
            let keys = r.open_blob(&origin, account, av, &blob)?;
            if input.has("certificate_ask_hex") {
                keys.check_against(
                    &Ed25519Public(input.hex32("certificate_ask_hex")),
                    &X25519Public(input.hex32("certificate_aek_hex")),
                )?;
            }
            ok()
        }
        "account_certificate" => {
            let origin = input.origin();
            let account = input.account("account");
            let av = input.version("av");
            let kind = crate::cert::CertKind::from_code(i64::from(input.u32("kind")))?;
            let ik = Ed25519Seed::from_bytes(input.hex32("ik_seed_hex"));
            let keys = AccountKeys {
                ask: Ed25519Seed::from_bytes(input.hex32("ask_seed_hex")),
                aek: X25519Secret::from_bytes(input.hex32("aek_secret_hex")),
            };
            let previous = input
                .has("previous_ik_seed_hex")
                .then(|| Ed25519Seed::from_bytes(input.hex32("previous_ik_seed_hex")));
            let certificate = crate::cert::AccountCertificate::sign(
                &origin,
                account,
                av,
                kind,
                &ik,
                keys.public()?,
                previous.as_ref(),
            )?;
            certificate.verify(&origin)?;
            let mut outputs = vec![
                ("message_hex", h(&certificate.message(&origin)?)),
                ("sig_hex", h(&certificate.sig.0)),
            ];
            if let Some(previous) = &previous {
                assert_eq!(certificate.ik_change(&origin, &previous.public()?)?, IkChange::Endorsed);
                outputs.push((
                    "replace_message_hex",
                    h(&crate::cert::replace_message(&origin, account, av, &certificate.ik)?),
                ));
                outputs.push(("replace_sig_hex", h(&certificate.replace_sig.expect("replace").0)));
            }
            outputs.push((
                "record",
                super::gen_basic::record(
                    "key.account",
                    &KeyRecordId::Account { account, av }.to_wire(),
                    &crate::body::body_json(&KeyBody::Account(crate::body::AccountBody::of(&certificate))),
                ),
            ));
            outputs
        }
        "device_certificate" => {
            let origin = input.origin();
            let account = input.account("account");
            let av = input.version("av");
            let key_device = KeyDeviceId(uuid_from_wire(input.str("key_device"))?);
            let dek = X25519Secret::from_bytes(input.hex32("dek_secret_hex")).public()?;
            let dsk = Ed25519Seed::from_bytes(input.hex32("dsk_seed_hex")).public()?;
            let ask = Ed25519Seed::from_bytes(input.hex32("ask_seed_hex"));
            let certificate = crate::cert::DeviceCertificate::sign(&origin, account, av, key_device, dek, dsk, &ask)?;
            certificate.verify(&origin, &ask.public()?)?;
            vec![
                (
                    "message_hex",
                    h(&crate::cert::device_message(
                        &origin, account, av, key_device, &dek, &dsk,
                    )?),
                ),
                ("sig_hex", h(&certificate.sig.0)),
                (
                    "record",
                    super::gen_basic::record(
                        "key.device",
                        &KeyRecordId::Device {
                            account,
                            key_device,
                            av,
                        }
                        .to_wire(),
                        &crate::body::body_json(&KeyBody::Device(crate::body::DeviceBody::of(&certificate))),
                    ),
                ),
            ]
        }
        "cancel" | "verify_cancel" => {
            let origin = input.origin();
            let account = input.account("account");
            let reset_av = input.version("reset_av");
            let proposed = Ed25519Public(input.hex32("proposed_ik_hex"));
            let sig = Signature(input.hex("sig_hex").try_into().expect("signature"));
            crate::cert::verify_cancel(
                &origin,
                account,
                reset_av,
                &proposed,
                &sig,
                &Ed25519Public(input.hex32("ik_hex")),
            )?;
            if op == "cancel" {
                let ik = Ed25519Seed::from_bytes(input.hex32("ik_seed_hex"));
                let signed = crate::cert::sign_cancel(&origin, account, reset_av, &proposed, &ik)?;
                vec![
                    (
                        "message_hex",
                        h(&crate::cert::cancel_message(&origin, account, reset_av, &proposed)?),
                    ),
                    ("sig_hex", h(&signed.0)),
                ]
            } else {
                ok()
            }
        }
        "verify_account_certificate" => {
            let origin = input.origin();
            let object = record_object(input.value("record"))?;
            let (KeyRecordId::Account { account, av }, KeyBody::Account(body)) = (&object.id, &object.body) else {
                panic!("an account record");
            };
            let certificate = body.certificate(*account, *av);
            if input.has("previous_ik_hex") {
                match certificate.ik_change(&origin, &Ed25519Public(input.hex32("previous_ik_hex")))? {
                    IkChange::Same => vec![("ik_change", s("same"))],
                    IkChange::Endorsed => vec![("ik_change", s("endorsed"))],
                }
            } else {
                certificate.verify(&origin)?;
                ok()
            }
        }
        "check_step" => {
            let held = input.has("held").then(|| input.version("held"));
            check_step(held, input.version("offered"))?;
            ok()
        }
        "ed25519_verify" => {
            let sig = Signature(input.hex("sig_hex").try_into().expect("signature"));
            Ed25519Public(input.hex32("public_hex")).verify(&input.hex("message_hex"), &sig)?;
            ok()
        }
        "kid" => {
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            vec![
                ("info_hex", h(&Frame::new(Label::KeyId).finish()?)),
                ("kid_hex", h(&key.kid()?.0)),
            ]
        }
        "version_record" => {
            let origin = input.origin();
            let key_ref = KeyRef {
                owner: uuid_from_wire(input.str("owner"))?,
                purpose: crate::encoding::KeyPurpose::parse(input.str("purpose"))?,
                version: input.version("version"),
            };
            let start = crate::scope_key::Start::from_code(i64::from(input.u32("start")))?;
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            let ask = Ed25519Seed::from_bytes(input.hex32("signer_ask_seed_hex"));
            let record = crate::scope_key::VersionRecord::sign(
                &origin,
                key_ref,
                start,
                &key,
                input.account("signer"),
                input.version("signer_av"),
                &ask,
            )?;
            record.verify(&origin, &ask.public()?)?;
            record.check_key(&key)?;
            vec![
                ("message_hex", h(&record.message(&origin)?)),
                ("digest_hex", h(&record.digest(&origin)?)),
                (
                    "record",
                    super::gen_basic::record(
                        "key.version",
                        &KeyRecordId::Version(key_ref).to_wire(),
                        &crate::body::body_json(&KeyBody::Version(crate::body::VersionBody::of(&record))),
                    ),
                ),
            ]
        }
        "ring" => {
            let origin = input.origin();
            let key_ref = KeyRef {
                owner: uuid_from_wire(input.str("owner"))?,
                purpose: crate::encoding::KeyPurpose::parse(input.str("purpose"))?,
                version: input.version("version"),
            };
            let newer = ScopeKey::from_bytes(input.hex32("newer_hex"));
            let older = ScopeKey::from_bytes(input.hex32("older_hex"));
            let ring = crate::scope_key::Ring::seal_with_nonce(
                &origin,
                key_ref,
                &newer,
                &older,
                input.hex("nonce_hex").try_into().expect("nonce"),
            )?;
            let mut key_info = Frame::new(Label::RingKey);
            key_info
                .origin(&origin)
                .scope(key_ref.scope())
                .lp(key_ref.purpose.name().as_bytes())
                .u32(key_ref.version.get());
            let below = key_ref.version.previous().expect("below");
            vec![
                ("key_info_hex", h(&key_info.finish()?)),
                ("aad_hex", h(&ring_aad(&origin, key_ref)?)),
                (
                    "plaintext_hex",
                    h(&[below.get().to_be_bytes().as_slice(), older.expose()].concat()),
                ),
                (
                    "record",
                    super::gen_basic::record(
                        "key.ring",
                        &KeyRecordId::Ring(key_ref).to_wire(),
                        &crate::body::body_json(&KeyBody::Ring(ring)),
                    ),
                ),
            ]
        }
        "ring_walk" => {
            let origin = input.origin();
            let versions: Vec<KeyObject> = match input.value("versions") {
                JsonValue::Array(items) => items.iter().map(record_object).collect::<Result<_, _>>()?,
                _ => panic!("versions"),
            };
            let rings: Vec<KeyObject> = match input.value("rings") {
                JsonValue::Array(items) => items.iter().map(record_object).collect::<Result<_, _>>()?,
                _ => panic!("rings"),
            };
            let mut current = ScopeKey::from_bytes(input.hex32("newest_hex"));
            let records: Vec<_> = versions
                .iter()
                .map(|object| object.version_record().expect("version record"))
                .collect();
            records.last().expect("newest").check_key(&current)?;
            let mut keys = vec![h(current.expose())];
            for ring_object in rings.iter().rev() {
                let (KeyRecordId::Ring(key_ref), KeyBody::Ring(ring)) = (&ring_object.id, &ring_object.body) else {
                    panic!("a ring");
                };
                let below = records
                    .iter()
                    .find(|record| Some(record.key.version) == key_ref.version.previous())
                    .expect("below");
                current = ring.open(&origin, *key_ref, &current, below)?;
                keys.push(h(current.expose()));
            }
            vec![("keys_hex", arr(keys))]
        }
        "open_ring" => {
            let origin = input.origin();
            let ring_object = record_object(input.value("ring"))?;
            let below = record_object(input.value("below"))?.version_record().expect("below");
            let (KeyRecordId::Ring(key_ref), KeyBody::Ring(ring)) = (&ring_object.id, &ring_object.body) else {
                panic!("a ring");
            };
            ring.open(
                &origin,
                *key_ref,
                &ScopeKey::from_bytes(input.hex32("newer_hex")),
                &below,
            )?;
            ok()
        }
        "aead_open" => {
            let key = Zeroizing::new(input.hex32("key_hex"));
            crypto::aes_open(
                &key,
                &input.hex("nonce_hex").try_into().expect("nonce"),
                &input.hex("aad_hex"),
                &input.hex("ct_hex"),
            )?;
            ok()
        }
        "key_object" => {
            if input.has("record") {
                record_object(input.value("record"))?;
            } else {
                object_from_text(input.value("object"))?;
            }
            ok()
        }
        "same_object" => {
            let mut held = input.sub("held");
            let mut offered = input.sub("offered");
            check_same_object(
                held.str("kind"),
                held.str("id"),
                held.str("fields_text").as_bytes(),
                offered.str("kind"),
                offered.str("id"),
                offered.str("fields_text").as_bytes(),
            )?;
            ok()
        }
        "check_record_digest" => {
            let origin = input.origin();
            let record = record_object(input.value("record"))?
                .version_record()
                .expect("version record");
            check_record_digest(&input.hex32("anchored_hex"), &record.digest(&origin)?)?;
            ok()
        }
        "wrap" => {
            let origin = input.origin();
            let KeyRecordId::Wrap(target) = KeyRecordId::parse(crate::record_id::KeyKind::Wrap, input.str("id"))?
            else {
                panic!("a wrap id");
            };
            let pk_r = X25519Public(input.hex32("pk_r_hex"));
            let secret = X25519Secret::from_bytes(input.hex32("sk_r_hex"));
            assert_eq!(secret.public()?, pk_r);
            let info = wrap_info(&origin, target, &pk_r)?;
            let signer = Ed25519Seed::from_bytes(input.hex32("signer_seed_hex"));
            assert_eq!(signer.public()?.0, input.hex32("signer_hex"));
            vec![
                ("info_hex", h(&info)),
                ("plaintext_hex", h(&input.hex("plaintext_hex"))),
            ]
        }
        "open_wrap" => {
            let origin = input.origin();
            let wrap = record_object(input.value("record"))?.wrap().expect("a wrap");
            let secret = X25519Secret::from_bytes(input.hex32("recipient_secret_hex"));
            let certified = X25519Public(input.hex32("certified_pk_hex"));
            let signer = Ed25519Public(input.hex32("signer_hex"));
            match input.str("mode") {
                "account" => {
                    let certificate = AccountPublicKeys {
                        ask: Ed25519Public(input.hex32("certificate_ask_hex")),
                        aek: X25519Public(input.hex32("certificate_aek_hex")),
                    };
                    wrap.open_account(&origin, &secret, &certified, &signer, &certificate)?;
                    ok()
                }
                "trust" => vec![(
                    "trust",
                    s(&wrap.open_trust(&origin, &secret, &certified, &signer)?.encode()),
                )],
                _ => {
                    let record = record_object(input.value("version_record"))?
                        .version_record()
                        .expect("version record");
                    vec![(
                        "key_hex",
                        h(wrap
                            .open_scope_key(&origin, &secret, &certified, &signer, &record)?
                            .expose()),
                    )]
                }
            }
        }
        "hpke_open" => {
            crypto::hpke_open(
                &input.hex32("sk_hex"),
                &input.hex32("enc_hex"),
                &input.hex("info_hex"),
                &input.hex("ct_hex"),
            )?;
            ok()
        }
        "hpke_seal" => {
            crypto::hpke_seal(
                &input.hex32("pk_hex"),
                &input.hex("info_hex"),
                &input.hex("plaintext_hex"),
            )?;
            ok()
        }
        "check_signed_under_newest" => {
            check_signed_under_newest(input.version("signed_under"), input.version("newest_known"))?;
            ok()
        }
        "check_not_below" => {
            check_not_below(input.version("held"), input.version("offered"))?;
            ok()
        }
        "envelope" => {
            let origin = input.origin();
            let scope = scope_of(input.value("scope"));
            let id = EnvelopeId::parse(input.str("id"))?;
            let kv = input.version("kv");
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            let plaintext = input.str("plaintext");
            let nonce: [u8; 12] = input.hex("nonce_hex").try_into().expect("nonce");
            let sealed =
                crate::envelope::seal_envelope_plaintext(&key, &origin, scope, &id, kv, plaintext.as_bytes(), nonce)?;
            let opened = open_envelope(&key, &origin, scope, &id, &sealed)?;
            let rebuilt = crate::envelope::envelope_plaintext(opened.secret.expose_secret(), &opened.dest)?;
            assert!(crate::json::parse(rebuilt.as_bytes())?.same_as(&crate::json::parse(plaintext.as_bytes())?));
            let mut info = Frame::new(Label::EnvelopeKey);
            info.origin(&origin)
                .scope(scope)
                .lp(id.parent_kind.name().as_bytes())
                .lp(id.parent_id.as_bytes())
                .lp(id.secret_kind.name().as_bytes());
            vec![
                ("subkey_info_hex", h(&info.finish()?)),
                ("subkey_hex", h(&*envelope_subkey(&key, &origin, scope, &id)?)),
                ("aad_hex", h(&envelope_aad(&origin, scope, &id, kv)?)),
                ("plaintext_len", n(plaintext.len() as u64)),
                ("padded_len", n(padding::padded_len(plaintext.len())? as u64)),
                ("ct_hex", h(&sealed.ct)),
                (
                    "fields",
                    crate::json::parse(crate::body::sealed_json(&sealed).as_bytes())?,
                ),
            ]
        }
        "open_envelope" => {
            let origin = input.origin();
            let scope = scope_of(input.value("scope"));
            let id = EnvelopeId::parse(input.str("id"))?;
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            let sealed = parse_sealed(input.value("fields").to_json().as_bytes())?;
            let opened = open_envelope(&key, &origin, scope, &id, &sealed)?;
            vec![("secret", s(opened.secret.expose_secret())), ("dest", opened.dest)]
        }
        "sealed_fields" => {
            parse_sealed(input.value("fields").to_json().as_bytes())?;
            ok()
        }
        "check_destination" => {
            check_destination(input.value("sealed"), input.value("current"))?;
            ok()
        }
        "history_entry" => {
            let origin = input.origin();
            let account = input.account("account");
            let id = HistoryId(uuid_from_wire(input.str("id"))?);
            let kv = input.version("kv");
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            let plaintext = input.str("plaintext");
            let nonce: [u8; 12] = input.hex("nonce_hex").try_into().expect("nonce");
            let sealed =
                crate::envelope::seal_history_plaintext(&key, &origin, account, id, kv, plaintext.as_bytes(), nonce)?;
            open_history(&key, &origin, account, id, &sealed)?;
            let mut info = Frame::new(Label::HistoryKey);
            info.origin(&origin)
                .scope(Scope::History(account))
                .lp(id.to_wire().as_bytes());
            vec![
                ("subkey_info_hex", h(&info.finish()?)),
                ("subkey_hex", h(&*history_subkey(&key, &origin, account, id)?)),
                ("aad_hex", h(&history_aad(&origin, account, id, kv)?)),
                ("plaintext_len", n(plaintext.len() as u64)),
                ("padded_len", n(padding::padded_len(plaintext.len())? as u64)),
                ("ct_hex", h(&sealed.ct)),
                (
                    "fields",
                    crate::json::parse(crate::body::sealed_json(&sealed).as_bytes())?,
                ),
            ]
        }
        "open_history" => {
            let origin = input.origin();
            let account = input.account("account");
            let id = HistoryId(uuid_from_wire(input.str("id"))?);
            let key = ScopeKey::from_bytes(input.hex32("key_hex"));
            let sealed = parse_sealed(input.value("fields").to_json().as_bytes())?;
            vec![("entry", open_history(&key, &origin, account, id, &sealed)?)]
        }
        "trust_plaintext" => {
            let text = input.str("text");
            let trust = TrustPlaintext::parse(text.as_bytes())?;
            let mut outputs = vec![
                ("pins", n(trust.pins.len() as u64)),
                ("versions", n(trust.versions.len() as u64)),
            ];
            if trust.encode() == text {
                outputs.push(("padded_hex", h(&padding::pad(text.as_bytes())?)));
            }
            outputs
        }
        "trust_fit" => {
            let trust = TrustPlaintext::parse(input.str("text").as_bytes())?;
            let limit = usize::try_from(input.u64("limit_bytes")).expect("limit");
            match trust.fit(|candidate| candidate.encode().len() <= limit) {
                Some(fitted) => vec![("fits", b(true)), ("text", s(&fitted.encode()))],
                None => vec![("fits", b(false))],
            }
        }
        "sas" => {
            let view = sas_view(&mut input);
            let commit = view.transcript.commitment(&view.n, &view.r_n)?;
            let digest = view.transcript.digest(&view.n, &view.r_n, &view.a, &view.r_a)?;
            // A's side, from the request it read and its own keys, after the reveal.
            let mut approver = Comparison::approver(view.transcript.clone(), view.n, commit, view.a, view.r_a);
            approver.receive_reveal(view.r_n)?;
            let mut new_device = Comparison::new_device(view.transcript.clone(), view.n, view.r_n)?;
            new_device.receive_nonce(view.a, view.r_a)?;
            new_device.reveal()?;
            assert_eq!(approver.words()?, new_device.words()?);
            let commit_input = commit_input_frame(&view, Label::SasCommit);
            let mut digest_input = commit_input_frame(&view, Label::Sas);
            digest_input
                .id(view.a.key_device.0)
                .lp(&view.a.dek.0)
                .lp(&view.a.dsk.0)
                .lp(&view.r_a);
            vec![
                ("commit_input_hex", h(&commit_input.finish()?)),
                ("digest_input_hex", h(&digest_input.finish()?)),
                ("commit_hex", h(&commit)),
                ("digest_hex", h(&digest)),
                ("word_indexes", indexes_json(&digest, 5)),
                ("words", words_json(&words(&digest, 5))),
            ]
        }
        "check_commitment" => {
            let view = sas_view(&mut input);
            view.transcript
                .check_commitment(&view.n, &view.r_n, &input.hex32("commit_hex"))?;
            ok()
        }
        "sas_words_differ" => {
            let mut base = input.sub("view");
            let mut other = input.sub("other_view");
            let base = sas_view(&mut base);
            let other = sas_view(&mut other);
            let base_words = base.transcript.words(&base.n, &base.r_n, &base.a, &base.r_a)?;
            let other_words = other.transcript.words(&other.n, &other.r_n, &other.a, &other.r_a)?;
            if base_words == other_words {
                ok()
            } else {
                return Err(KeysError::SasMismatch);
            }
        }
        "sas_session" => {
            let mut view_input = input.sub("view");
            let view = sas_view(&mut view_input);
            let commit = view.transcript.commitment(&view.n, &view.r_n)?;
            let mut session = if input.str("role") == "new_device" {
                Comparison::new_device(view.transcript.clone(), view.n, view.r_n)?
            } else {
                Comparison::approver(view.transcript.clone(), view.n, commit, view.a, view.r_a)
            };
            let steps: Vec<String> = match input.value("steps") {
                JsonValue::Array(items) => items
                    .iter()
                    .map(|item| crate::json::as_str(item).expect("step").to_owned())
                    .collect(),
                _ => panic!("steps"),
            };
            let mut shown = Vec::new();
            for step in steps {
                match step.as_str() {
                    "receive_nonce" => session.receive_nonce(view.a, view.r_a)?,
                    "reveal" => {
                        session.reveal()?;
                    }
                    "receive_reveal" => session.receive_reveal(view.r_n)?,
                    "words" => shown = session.words()?,
                    "confirm" => session.confirm()?,
                    "receive_cancel" => session.receive_cancel()?,
                    "expire" => {
                        let _ = session.check_live(600, 600);
                    }
                    other => panic!("unknown step {other}"),
                }
            }
            vec![("ok", b(true)), ("words", words_json(&shown))]
        }
        "fingerprint" => {
            let origin = input.origin();
            let account = input.account("account");
            let f = fingerprint(&origin, account, &Ed25519Public(input.hex32("ik_hex")))?;
            let mut info = Frame::new(Label::Fingerprint);
            info.origin(&origin).id(account.0);
            vec![
                ("info_hex", h(&info.finish()?)),
                ("f_hex", h(&f)),
                ("word_indexes", indexes_json(&f, 6)),
                ("words", words_json(&fingerprint_words(&f))),
                ("qr", s(&qr_text(&f))),
            ]
        }
        "words" => {
            let digest = input.hex32("digest_hex");
            let count = usize::try_from(input.u64("count")).expect("count");
            vec![
                ("word_indexes", indexes_json(&digest, count)),
                ("words", words_json(&words(&digest, count))),
            ]
        }
        "parse_qr" => vec![("f_hex", h(&parse_qr(input.str("text"))?))],
        "state_mac" => {
            let origin = input.origin();
            let account = input.account("account");
            let key = Zeroizing::new(input.hex32("key_hex"));
            let file_id: [u8; 16] = input.hex("file_id_hex").try_into().expect("file id");
            let key_digest = input.hex32("key_digest_hex");
            let sync_digest = input.hex32("sync_digest_hex");
            let snapshot = StateSnapshot {
                file_id: &file_id,
                counter: input.u64("counter"),
                key_digest: &key_digest,
                sync_digest: &sync_digest,
            };
            vec![
                ("input_hex", h(&state_mac_input(&origin, account, snapshot)?)),
                ("mac_hex", h(&state_mac(&key, &origin, account, snapshot)?)),
            ]
        }
        "dpop" => {
            let dsk = Ed25519Seed::from_bytes(input.hex32("dsk_seed_hex"));
            let nonce = input.has("nonce").then(|| input.str("nonce"));
            let request = DpopRequest {
                method: input.str("method"),
                url: input.str("url"),
                access_token: input.str("access_token"),
                iat: input.u64("iat"),
                nonce,
            };
            let proof = dpop::proof_with_jti(&dsk, request, input.hex("jti_hex").try_into().expect("jti"))?;
            let parts: Vec<&str> = proof.split('.').collect();
            let signature = Signature(b64::decode_exact(parts[2])?);
            Ed25519Public(input.hex32("dsk_hex"))
                .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)?;
            vec![
                ("header", s(&String::from_utf8(b64::decode(parts[0])?).expect("utf-8"))),
                ("claims", s(&String::from_utf8(b64::decode(parts[1])?).expect("utf-8"))),
                ("proof", s(&proof)),
            ]
        }
        other => panic!("no verifier for op {other}"),
    };
    Ok(outputs)
}

fn commit_input_frame(view: &SasView, label: Label) -> Frame {
    let mut frame = Frame::new(label);
    frame
        .origin(&view.transcript.origin)
        .id(view.transcript.account.0)
        .id(view.transcript.request.0)
        .id(view.n.key_device.0)
        .lp(&view.transcript.ik.0)
        .lp(&view.n.dek.0)
        .lp(&view.n.dsk.0)
        .lp(&view.r_n);
    frame
}

// Checks one case: its listed outputs match, or the client error is the one it names.
pub(super) fn check(area: &str, case: &JsonValue) {
    let mut members = Members::of(case).expect("case");
    let name = members.string("name").expect("name").to_owned();
    let op = members.string("op").expect("op").to_owned();
    let input = members.required("input").expect("input");
    let result = run(&op, input);
    match members.optional("error") {
        Some(JsonValue::String(code)) => match result {
            Err(error) => assert_eq!(error.code(), code, "{area}: {name}"),
            Ok(outputs) => panic!(
                "{area}: {name}: expected {code}, got {:?}",
                outputs.iter().map(|(key, _)| *key).collect::<Vec<_>>()
            ),
        },
        _ => {
            let outputs = result.unwrap_or_else(|error| panic!("{area}: {name}: {error:?}"));
            let JsonValue::Object(expected) = members.required("output").expect("output") else {
                panic!("{area}: {name}: output");
            };
            for (key, value) in expected {
                if matches!(
                    key.as_str(),
                    "hpke_id" | "enc_hex" | "ct_hex" | "sig_message_hex" | "sig_hex" | "record"
                ) && op == "wrap"
                {
                    continue;
                }
                let computed = outputs
                    .iter()
                    .find(|(computed, _)| computed == key)
                    .map(|(_, value)| value);
                let computed = computed.unwrap_or_else(|| panic!("{area}: {name}: no output {key}"));
                assert!(
                    computed.same_as(value),
                    "{area}: {name}: {key}\n computed {}\n expected {}",
                    computed.to_json(),
                    value.to_json()
                );
            }
            if op == "wrap" {
                check_wrap(&name, input, expected);
            }
        }
    }
}

// A wrap's HPKE output is random: its record must verify under the signer, open to the plaintext,
// and name the info the case gives.
fn check_wrap(name: &str, input: &JsonValue, expected: &[(String, JsonValue)]) {
    let mut input = In::of(input);
    let origin = input.origin();
    let get = |key: &str| {
        expected
            .iter()
            .find(|(member, _)| member == key)
            .map(|(_, value)| value)
            .unwrap_or_else(|| panic!("{name}: {key}"))
    };
    let wrap = record_object(get("record"))
        .expect("wrap record")
        .wrap()
        .expect("a wrap");
    let pk_r = X25519Public(input.hex32("pk_r_hex"));
    let secret = X25519Secret::from_bytes(input.hex32("sk_r_hex"));
    let signer = Ed25519Public(input.hex32("signer_hex"));
    wrap.verify(&origin, &pk_r, &signer)
        .unwrap_or_else(|error| panic!("{name}: {error:?}"));
    let info = wrap.info(&origin, &pk_r).expect("info");
    let opened = crypto::hpke_open(secret.expose(), &wrap.enc, &info, &wrap.ct)
        .unwrap_or_else(|error| panic!("{name}: {error:?}"));
    assert_eq!(opened.as_slice(), input.hex("plaintext_hex").as_slice(), "{name}");
    let JsonValue::String(enc) = get("enc_hex") else {
        panic!("{name}: enc")
    };
    assert_eq!(hex::decode(enc).expect("hex"), wrap.enc, "{name}");
    // And a fresh seal of the same plaintext opens the same way.
    let (enc, ct) = crypto::hpke_seal(&pk_r.0, &info, &input.hex("plaintext_hex")).expect("seal");
    assert_eq!(
        crypto::hpke_open(secret.expose(), &enc, &info, &ct)
            .expect("open")
            .as_slice(),
        input.hex("plaintext_hex").as_slice()
    );
}
