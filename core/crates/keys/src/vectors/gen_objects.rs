use super::fixtures::{ACCOUNT_A, ACCOUNT_M, Account, HpkeCache, ORIGIN, TEAM_T, device, draw, origin, scope_key, v};
use super::gen_basic::record;
use super::out::{arr, case, file, h, n, negative, null, obj, s};
use crate::body::{AccountBody, DeviceBody, KeyBody, VersionBody, WrapBody, body_json};
use crate::cert::{
    AccountCertificate, CertKind, DeviceCertificate, account_message, cancel_message, device_message, replace_message,
    sign_cancel,
};
use crate::encoding::{Frame, KeyPurpose, Label, WrapPurpose, uuid_from_wire, uuid_to_wire};
use crate::json::JsonValue;
use crate::keys::{Ed25519Seed, ScopeKey, Signature};
use crate::record_id::KeyRecordId;
use crate::scope_key::{KeyRef, Ring, Start, VersionRecord, ring_aad};
use crate::trust::{PinHow, TrustPin, TrustPlaintext, TrustVersion};
use crate::wrap::{Wrap, Wrapper, device_target, scope_key_target, wrap_info, wrap_sig_message};

const BAD_STATEMENT: Option<&str> = Some("bad_statement");

fn account_record(certificate: &AccountCertificate) -> JsonValue {
    let id = KeyRecordId::Account {
        account: certificate.account,
        av: certificate.av,
    };
    record(
        "key.account",
        &id.to_wire(),
        &body_json(&KeyBody::Account(AccountBody::of(certificate))),
    )
}

fn sign_certificate(
    account: &Account,
    av: u32,
    kind: CertKind,
    ik: &Ed25519Seed,
    previous: Option<&Ed25519Seed>,
) -> AccountCertificate {
    AccountCertificate::sign(
        &origin(),
        account.id,
        v(av),
        kind,
        ik,
        account.at(av).public().unwrap(),
        previous,
    )
    .unwrap()
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn certificates() -> JsonValue {
    let a = Account::new("certificates/A", ACCOUNT_A, 4);
    let new_ik = Ed25519Seed::from_bytes(draw("certificates/A/replacing IK"));
    let mut accounts = Vec::new();
    for (av, kind, ik, previous) in [
        (1, CertKind::GenesisOrRotation, &a.ik, None),
        (2, CertKind::Replace, &new_ik, Some(&a.ik)),
        (3, CertKind::ResetKeepingKeys, &a.ik, None),
        (4, CertKind::ResetEmpty, &a.ik, None),
    ] {
        let certificate = sign_certificate(&a, av, kind, ik, previous);
        let mut input = vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("av", n(u64::from(av))),
            ("kind", n(u64::from(kind.code()))),
            ("ik_seed_hex", h(ik.expose())),
            ("ask_seed_hex", h(a.at(av).ask.expose())),
            ("aek_secret_hex", h(a.at(av).aek.expose())),
        ];
        let mut output = vec![
            (
                "message_hex",
                h(&account_message(
                    &origin(),
                    a.id,
                    v(av),
                    &certificate.ik,
                    &certificate.ask,
                    &certificate.aek,
                    kind,
                )
                .unwrap()),
            ),
            ("sig_hex", h(&certificate.sig.0)),
        ];
        if let Some(previous) = previous {
            input.push(("previous_ik_seed_hex", h(previous.expose())));
            output.push((
                "replace_message_hex",
                h(&replace_message(&origin(), a.id, v(av), &certificate.ik).unwrap()),
            ));
            output.push(("replace_sig_hex", h(&certificate.replace_sig.unwrap().0)));
        }
        output.push(("record", account_record(&certificate)));
        accounts.push(case(
            &format!("account certificate of kind {}", kind.code()),
            "account_certificate",
            input,
            output,
        ));
    }

    let laptop = device("certificates/laptop");
    let device_certificate = DeviceCertificate::sign(
        &origin(),
        a.id,
        v(2),
        laptop.key_device,
        laptop.dek.public().unwrap(),
        laptop.dsk.public().unwrap(),
        &a.at(2).ask,
    )
    .unwrap();
    let device_id = KeyRecordId::Device {
        account: a.id,
        key_device: laptop.key_device,
        av: v(2),
    };
    let devices = vec![case(
        "device certificate",
        "device_certificate",
        vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("av", n(2)),
            ("key_device", s(&laptop.key_device.to_wire())),
            ("dek_secret_hex", h(laptop.dek.expose())),
            ("dsk_seed_hex", h(laptop.dsk.expose())),
            ("ask_seed_hex", h(a.at(2).ask.expose())),
        ],
        vec![
            (
                "message_hex",
                h(&device_message(
                    &origin(),
                    a.id,
                    v(2),
                    laptop.key_device,
                    &device_certificate.dek,
                    &device_certificate.dsk,
                )
                .unwrap()),
            ),
            ("sig_hex", h(&device_certificate.sig.0)),
            (
                "record",
                record(
                    "key.device",
                    &device_id.to_wire(),
                    &body_json(&KeyBody::Device(DeviceBody::of(&device_certificate))),
                ),
            ),
        ],
    )];

    let proposed = Ed25519Seed::from_bytes(draw("certificates/reset IK")).public().unwrap();
    let cancel_sig = sign_cancel(&origin(), a.id, v(3), &proposed, &a.ik).unwrap();
    let cancel_input = |proposed_ik: &[u8]| {
        vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("reset_av", n(3)),
            ("proposed_ik_hex", h(proposed_ik)),
            ("ik_hex", h(&a.ik_public().0)),
            ("sig_hex", h(&cancel_sig.0)),
        ]
    };
    let later = Ed25519Seed::from_bytes(draw("certificates/later reset IK"))
        .public()
        .unwrap();
    let mut cancel_case_input = cancel_input(&proposed.0);
    cancel_case_input.push(("ik_seed_hex", h(a.ik.expose())));
    let cancels = vec![
        case(
            "cancel with the recovery key",
            "cancel",
            cancel_case_input,
            vec![
                (
                    "message_hex",
                    h(&cancel_message(&origin(), a.id, v(3), &proposed).unwrap()),
                ),
                ("sig_hex", h(&cancel_sig.0)),
            ],
        ),
        negative(
            "a cancel signed for one reset, replayed against a later reset at the same av",
            "verify_cancel",
            "A cancel signed for one reset, replayed against a later reset at the same `av`",
            cancel_input(&later.0),
            "keys.signature",
            BAD_STATEMENT,
        ),
    ];

    let genesis = sign_certificate(&a, 1, CertKind::GenesisOrRotation, &a.ik, None);
    let mut under_other = genesis.clone();
    under_other.ik = new_ik.public().unwrap();
    let mut verify = vec![negative(
        "a certificate naming one IK, signed by another",
        "verify_account_certificate",
        "A certificate under another IK",
        vec![("origin", s(ORIGIN)), ("record", account_record(&under_other))],
        "keys.signature",
        BAD_STATEMENT,
    )];
    let unendorsed = AccountCertificate {
        replace_sig: Some(
            new_ik
                .sign(&replace_message(&origin(), a.id, v(2), &new_ik.public().unwrap()).unwrap())
                .unwrap(),
        ),
        ..sign_certificate(&a, 2, CertKind::Replace, &new_ik, Some(&new_ik))
    };
    verify.push(negative(
        "a replace endorsed by the new IK instead of the old",
        "verify_account_certificate",
        "A replace without the old IK's endorsement",
        vec![
            ("origin", s(ORIGIN)),
            ("record", account_record(&unendorsed)),
            ("previous_ik_hex", h(&a.ik_public().0)),
        ],
        "keys.unendorsed",
        BAD_STATEMENT,
    ));
    // An endorsement no key could make is keys.signature, not keys.unendorsed (ADR 0059).
    let endorsed = sign_certificate(&a, 2, CertKind::Replace, &new_ik, Some(&a.ik));
    let endorsement = endorsed.replace_sig.unwrap().0;
    let mut s_past_l = endorsement;
    s_past_l[32..].copy_from_slice(&add_l(&endorsement[32..]).expect("S + L fits 256 bits"));
    let mut r_not_canonical = endorsement;
    r_not_canonical[..32]
        .copy_from_slice(&hex::decode("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f").unwrap());
    for (name, sig) in [
        ("a replace whose endorsement has S + L", s_past_l),
        ("a replace whose endorsement has a non-canonical R", r_not_canonical),
    ] {
        let malformed = AccountCertificate {
            replace_sig: Some(Signature(sig)),
            ..endorsed.clone()
        };
        verify.push(negative(
            name,
            "verify_account_certificate",
            "An Ed25519 A of small order, a non-canonical A or R, S at or above L",
            vec![
                ("origin", s(ORIGIN)),
                ("record", account_record(&malformed)),
                ("previous_ik_hex", h(&a.ik_public().0)),
            ],
            "keys.signature",
            BAD_STATEMENT,
        ));
    }
    let reset = sign_certificate(&a, 2, CertKind::ResetKeepingKeys, &new_ik, None);
    verify.push(negative(
        "an IK change with no endorsement, as after a reset",
        "verify_account_certificate",
        "An IK change with no endorsement",
        vec![
            ("origin", s(ORIGIN)),
            ("record", account_record(&reset)),
            ("previous_ik_hex", h(&a.ik_public().0)),
        ],
        "keys.unendorsed",
        None,
    ));
    let replace = sign_certificate(&a, 2, CertKind::Replace, &new_ik, Some(&a.ik));
    verify.push(case(
        "a replace the old IK endorsed",
        "verify_account_certificate",
        vec![
            ("origin", s(ORIGIN)),
            ("record", account_record(&replace)),
            ("previous_ik_hex", h(&a.ik_public().0)),
        ],
        vec![("ik_change", s("endorsed"))],
    ));
    verify.push(case(
        "a rotation under the same IK",
        "verify_account_certificate",
        vec![
            ("origin", s(ORIGIN)),
            (
                "record",
                account_record(&sign_certificate(&a, 3, CertKind::GenesisOrRotation, &a.ik, None)),
            ),
            ("previous_ik_hex", h(&a.ik_public().0)),
        ],
        vec![("ik_change", s("same"))],
    ));
    // The certificate under the IK a replace retired still verifies what was signed under it.
    let retired = sign_certificate(&a, 1, CertKind::GenesisOrRotation, &a.ik, None);
    let older = VersionRecord::sign(
        &origin(),
        KeyRef {
            owner: a.id.0,
            purpose: KeyPurpose::Personal,
            version: v(1),
        },
        Start::Over,
        &scope_key("certificates/PK1"),
        a.id,
        v(1),
        &a.at(1).ask,
    )
    .unwrap();
    verify.push(super::out::case_row(
        "the certificate under the retired IK verifies a version record signed before the replace",
        "verify_under_certificate",
        "A certificate under an IK seen replaced, offered as the newest; the same certificate verifying an object signed before the replace",
        vec![("origin", s(ORIGIN)), ("certificate", account_record(&retired)), ("record", version_record_json(&older))],
        vec![("ok", super::out::b(true))],
        None,
    ));

    let steps = vec![
        negative(
            "an av that goes back",
            "check_step",
            "An `av` that goes back; one that skips",
            vec![("held", n(4)), ("offered", n(3))],
            "keys.stale",
            BAD_STATEMENT,
        ),
        negative(
            "an av that repeats",
            "check_step",
            "An `av` that goes back; one that skips",
            vec![("held", n(4)), ("offered", n(4))],
            "keys.stale",
            BAD_STATEMENT,
        ),
        negative(
            "an av that skips",
            "check_step",
            "An `av` that goes back; one that skips",
            vec![("held", n(4)), ("offered", n(6))],
            "keys.step",
            BAD_STATEMENT,
        ),
        case(
            "the next av",
            "check_step",
            vec![("held", n(4)), ("offered", n(5))],
            vec![("ok", super::out::b(true))],
        ),
        case(
            "a first version",
            "check_step",
            vec![("held", null()), ("offered", n(1))],
            vec![("ok", super::out::b(true))],
        ),
    ];

    file(
        "certificates",
        "Account and device certificates, the replace endorsement, cancels, IK changes and version steps (ADR 0056, Signed objects and wraps, Pins). In `ed25519`, `cofactorless_equation_holds` says that [S]B = R + [k]A holds for the signature, so only the refusal the case names stops it. `aws_lc_rs_takes_it` says whether aws-lc-rs 1.18.1, the library tablepro-keys verifies with, takes it without the crate's checks before it. It is given only for the canonical points of small order: for a non-canonical encoding the answer differs by platform, and the Windows build takes the sign-bit encodings of x = 0.",
        vec![
            ("account", arr(accounts)),
            ("device", arr(devices)),
            ("cancel", arr(cancels)),
            ("verify", arr(verify)),
            ("steps", arr(steps)),
            ("ed25519", arr(ed25519_negatives())),
        ],
    )
}

// S + L, little-endian, as a 32-byte value when it fits.
fn add_l(s_bytes: &[u8]) -> Option<[u8; 32]> {
    let l = hex::decode("edd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010").ok()?;
    let mut out = [0_u8; 32];
    let mut carry = 0_u16;
    for index in 0..32 {
        let sum = u16::from(s_bytes[index]) + u16::from(l[index]) + carry;
        out[index] = (sum & 0xff) as u8;
        carry = sum >> 8;
    }
    (carry == 0).then_some(out)
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
fn ed25519_negatives() -> Vec<JsonValue> {
    let row = "An Ed25519 A of small order, a non-canonical A or R, S at or above L";
    let seed = Ed25519Seed::from_bytes(draw("ed25519/seed"));
    let public = seed.public().unwrap();
    let message = b"tablepro-keys ed25519 vector";
    let mut counter = 0;
    let signature = loop {
        let candidate = seed.sign(&[message.as_slice(), &[counter]].concat()).unwrap();
        if add_l(&candidate.0[32..]).is_some() {
            break (candidate, [message.as_slice(), &[counter]].concat());
        }
        counter += 1;
    };
    let (sig, signed) = signature;
    let input = |public: &[u8], sig: &[u8]| {
        vec![
            ("public_hex", h(public)),
            ("message_hex", h(&signed)),
            ("sig_hex", h(sig)),
        ]
    };
    let mut cases = vec![case(
        "a valid signature",
        "ed25519_verify",
        input(&public.0, &sig.0),
        vec![("ok", super::out::b(true))],
    )];
    // Real forgeries, R = [r]B and S = r over a message whose challenge the key's order divides: the
    // cofactorless equation holds, so only the refusal of small-order A (and, for the encodings with
    // x = 0 and the sign bit set, of a non-canonical A) stops them.
    for (index, (small, order)) in crate::crypto::forgery::encodings().into_iter().enumerate() {
        let (forged, message) = crate::crypto::forgery::forge(&small, order, &format!("vector {index}"));
        let canonical = small[31] & 0x80 == 0;
        let mut input = vec![
            ("public_hex", h(&small)),
            ("message_hex", h(&message)),
            ("sig_hex", h(&forged)),
            ("cofactorless_equation_holds", super::out::b(true)),
        ];
        // AWS-LC's answer for a sign-bit encoding differs by platform, so it is given only where
        // every platform agrees.
        if canonical {
            input.push((
                "aws_lc_rs_takes_it",
                super::out::b(crate::crypto::forgery::library_accepts(&small, &message, &forged)),
            ));
        }
        cases.push(negative(
            &format!(
                "a forgery under A of order {order} ({}{})",
                hex::encode(&small[..4]),
                if canonical { "" } else { ", sign bit set" }
            ),
            "ed25519_verify",
            row,
            input,
            "keys.signature",
            BAD_STATEMENT,
        ));
    }
    // y = p + 1, which reduces to the identity's y: a decoder that takes non-canonical y reads the
    // identity, under which any message forges.
    let non_canonical = hex::decode("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f").unwrap();
    let non_canonical: [u8; 32] = non_canonical.try_into().unwrap();
    let (forged, message) = crate::crypto::forgery::forge(&non_canonical, 1, "vector non-canonical");
    cases.push(negative(
        "a forgery under a non-canonical A, y = p + 1",
        "ed25519_verify",
        row,
        vec![
            ("public_hex", h(&non_canonical)),
            ("message_hex", h(&message)),
            ("sig_hex", h(&forged)),
            ("cofactorless_equation_holds", super::out::b(true)),
        ],
        "keys.signature",
        BAD_STATEMENT,
    ));
    // R as x = 0 with the sign bit set, which RFC 8032 refuses, and as y = p + 1: a lenient decoder
    // reads both as the identity, and S = k * a then satisfies the equation, so only the R check fails.
    let negative_zero: [u8; 32] = hex::decode("0100000000000000000000000000000000000000000000000000000000000080")
        .unwrap()
        .try_into()
        .unwrap();
    for (name, r) in [
        ("R the identity with the sign bit set", negative_zero),
        ("a non-canonical R, y = p + 1", non_canonical),
    ] {
        let forged = crate::crypto::forgery::sign_with_identity_r(seed.expose(), &r, &signed);
        cases.push(negative(
            name,
            "ed25519_verify",
            row,
            vec![
                ("public_hex", h(&public.0)),
                ("message_hex", h(&signed)),
                ("sig_hex", h(&forged)),
                ("cofactorless_equation_holds", super::out::b(true)),
            ],
            "keys.signature",
            BAD_STATEMENT,
        ));
    }
    let mut high_s = sig.0;
    if let Some(s_plus_l) = add_l(&sig.0[32..]) {
        high_s[32..].copy_from_slice(&s_plus_l);
    }
    cases.push(negative(
        "S + L, at or above L",
        "ed25519_verify",
        row,
        input(&public.0, &high_s),
        "keys.signature",
        BAD_STATEMENT,
    ));
    cases
}

fn version_record_json(record: &VersionRecord) -> JsonValue {
    super::gen_basic::record(
        "key.version",
        &KeyRecordId::Version(record.key).to_wire(),
        &body_json(&KeyBody::Version(VersionBody::of(record))),
    )
}

fn ring_json(key: KeyRef, ring: &Ring) -> JsonValue {
    super::gen_basic::record(
        "key.ring",
        &KeyRecordId::Ring(key).to_wire(),
        &body_json(&KeyBody::Ring(ring.clone())),
    )
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn scope_keys() -> JsonValue {
    let a = Account::new("scope/A", ACCOUNT_A, 2);
    let team = uuid_from_wire(TEAM_T).unwrap();
    let key = scope_key("scope/key");
    let kids = vec![case(
        "kid",
        "kid",
        vec![("key_hex", h(key.expose()))],
        vec![
            ("info_hex", h(&Frame::new(Label::KeyId).finish().unwrap())),
            ("kid_hex", h(&key.kid().unwrap().0)),
        ],
    )];

    let mut versions = Vec::new();
    for (owner, purpose, version, start) in [
        (a.id.0, KeyPurpose::Personal, 1, Start::Over),
        (a.id.0, KeyPurpose::History, 2, Start::Next),
        (team, KeyPurpose::Team, 1, Start::Over),
        (team, KeyPurpose::Team, 5, Start::Next),
    ] {
        let key_ref = KeyRef {
            owner,
            purpose,
            version: v(version),
        };
        let record = VersionRecord::sign(&origin(), key_ref, start, &key, a.id, v(2), &a.at(2).ask).unwrap();
        versions.push(case(
            &format!("{} version {version}, start {}", purpose.name(), start.code()),
            "version_record",
            vec![
                ("origin", s(ORIGIN)),
                ("owner", s(&uuid_to_wire(owner))),
                ("purpose", s(purpose.name())),
                ("version", n(u64::from(version))),
                ("start", n(u64::from(start.code()))),
                ("key_hex", h(key.expose())),
                ("signer", s(ACCOUNT_A)),
                ("signer_av", n(2)),
                ("signer_ask_seed_hex", h(a.at(2).ask.expose())),
            ],
            vec![
                ("message_hex", h(&record.message(&origin()).unwrap())),
                ("digest_hex", h(&record.digest(&origin()).unwrap())),
                ("record", version_record_json(&record)),
            ],
        ));
    }

    let keys: Vec<ScopeKey> = (1..=4)
        .map(|version| scope_key(&format!("scope/team key {version}")))
        .collect();
    let refs: Vec<KeyRef> = (1..=4)
        .map(|version| KeyRef {
            owner: team,
            purpose: KeyPurpose::Team,
            version: v(version),
        })
        .collect();
    let records: Vec<VersionRecord> = (0..4)
        .map(|index| {
            let start = if index == 0 { Start::Over } else { Start::Next };
            VersionRecord::sign(&origin(), refs[index], start, &keys[index], a.id, v(1), &a.at(1).ask).unwrap()
        })
        .collect();
    let rings: Vec<Ring> = (1..4)
        .map(|index| {
            Ring::seal_with_nonce(
                &origin(),
                refs[index],
                &keys[index],
                &keys[index - 1],
                draw(&format!("scope/ring nonce {index}")),
            )
            .unwrap()
        })
        .collect();
    let mut ring_cases = Vec::new();
    let ring = &rings[2];
    let mut key_info = Frame::new(Label::RingKey);
    key_info.origin(&origin()).scope(refs[3].scope()).lp(b"team").u32(4);
    ring_cases.push(case(
        "ring of team version 4",
        "ring",
        vec![
            ("origin", s(ORIGIN)),
            ("owner", s(TEAM_T)),
            ("purpose", s("team")),
            ("version", n(4)),
            ("newer_hex", h(keys[3].expose())),
            ("older_hex", h(keys[2].expose())),
            ("nonce_hex", h(&ring.nonce)),
        ],
        vec![
            ("key_info_hex", h(&key_info.finish().unwrap())),
            ("aad_hex", h(&ring_aad(&origin(), refs[3]).unwrap())),
            (
                "plaintext_hex",
                h(&[3_u32.to_be_bytes().as_slice(), keys[2].expose()].concat()),
            ),
            ("record", ring_json(refs[3], ring)),
        ],
    ));
    let walk = case(
        "a walk down three rings",
        "ring_walk",
        vec![
            ("origin", s(ORIGIN)),
            ("newest_hex", h(keys[3].expose())),
            ("signer_ask_hex", h(&a.ask(1).0)),
            ("versions", arr(records.iter().map(version_record_json).collect())),
            (
                "rings",
                arr((1..4).map(|index| ring_json(refs[index], &rings[index - 1])).collect()),
            ),
        ],
        vec![
            ("keys_hex", arr(keys.iter().rev().map(|key| h(key.expose())).collect())),
            (
                "version_messages_hex",
                arr(records
                    .iter()
                    .map(|record| h(&record.message(&origin()).unwrap()))
                    .collect()),
            ),
            (
                "ring_frames",
                arr((1..4)
                    .rev()
                    .map(|index| ring_frame(refs[index], &keys[index], &keys[index - 1]))
                    .collect()),
            ),
        ],
    );

    // Version 4's ring holding version 2's key: its entry is not the version below.
    let skip = seal_ring_entry(refs[3], &keys[3], 2, &keys[1], draw("scope/bad ring nonce"));
    let open_input = |ring: &Ring, newer: &ScopeKey, below: &VersionRecord| {
        vec![
            ("origin", s(ORIGIN)),
            ("newer_hex", h(newer.expose())),
            ("ring", ring_json(refs[3], ring)),
            ("below", version_record_json(below)),
        ]
    };
    let mut wrong_kid = records[2].clone();
    wrong_kid.kid = keys[0].kid().unwrap();
    let wrong_kid = VersionRecord {
        sig: a.at(1).ask.sign(&wrong_kid.message(&origin()).unwrap()).unwrap(),
        ..wrong_kid
    };
    let mut opens = vec![
        negative(
            "a ring entry other than the version below",
            "open_ring",
            "A ring entry other than the version below",
            open_input(&skip, &keys[3], &records[2]),
            "keys.ring",
            None,
        ),
        negative(
            "a ring key that does not match the version's kid",
            "open_ring",
            "A `kid` mismatch, from a wrap or a ring",
            open_input(ring, &keys[3], &wrong_kid),
            "keys.kid",
            None,
        ),
        negative(
            "a ring opened with another key",
            "open_ring",
            "A wrong label, or each AAD or `info` field changed",
            open_input(ring, &keys[2], &records[2]),
            "keys.open",
            None,
        ),
    ];
    let mut short = super::gen_basic::record(
        "key.ring",
        &KeyRecordId::Ring(refs[3]).to_wire(),
        &body_json(&KeyBody::Ring(ring.clone())),
    );
    if let JsonValue::Object(members) = &mut short
        && let Some((_, JsonValue::Object(fields))) = members.iter_mut().find(|(name, _)| name == "fields")
        && let Some((_, value)) = fields.iter_mut().find(|(name, _)| name == "ct")
    {
        *value = s(&crate::b64::encode(&ring.ct[..51]));
    }
    opens.push(negative(
        "a ring ct of 51 bytes",
        "key_object",
        "A truncated nonce, tag or `ct`, a ring `ct` other than 52 bytes",
        vec![("record", short)],
        "keys.encoding",
        BAD_STATEMENT,
    ));
    for (field, changed) in [("origin", "origin"), ("owner", "owner"), ("version", "version")] {
        let mut aad_ref = refs[3];
        let mut other_origin = origin();
        match changed {
            "origin" => other_origin = crate::encoding::Origin::parse("https://other.example.com").unwrap(),
            "owner" => aad_ref.owner = a.id.0,
            _ => aad_ref.version = v(5),
        }
        let aad = ring_aad(&other_origin, aad_ref).unwrap();
        opens.push(negative(
            &format!("the ring AAD with its {field} changed"),
            "aead_open",
            "A wrong label, or each AAD or `info` field changed",
            vec![
                ("key_hex", h(&*ring_subkey(refs[3], &keys[3]))),
                ("nonce_hex", h(&ring.nonce)),
                ("ct_hex", h(&ring.ct)),
                ("aad_hex", h(&aad)),
            ],
            "keys.open",
            None,
        ));
    }

    let digests = vec![negative(
        "a version record at an anchored version whose digest differs",
        "check_record_digest",
        "After a state file restore, a version record at an anchored version whose digest differs",
        vec![
            ("origin", s(ORIGIN)),
            ("anchored_hex", h(&records[2].digest(&origin()).unwrap())),
            ("record", version_record_json(&wrong_kid)),
        ],
        "keys.conflict",
        None,
    )];

    file(
        "scope_keys",
        "Key commitments, version records with start 0 and 1, rings and a walk down them (ADR 0056, Signed objects and wraps)",
        vec![
            ("kid", arr(kids)),
            ("version_records", arr(versions)),
            ("rings", arr(ring_cases)),
            ("walk", arr(vec![walk])),
            ("open_ring", arr(opens)),
            ("digests", arr(digests)),
        ],
    )
}

// One step of a walk: version v's ring key input, the subkey, the AAD and the plaintext it holds.
pub(super) fn ring_frame(key: KeyRef, newer: &ScopeKey, older: &ScopeKey) -> JsonValue {
    let mut key_info = Frame::new(Label::RingKey);
    key_info
        .origin(&origin())
        .scope(key.scope())
        .lp(key.purpose.name().as_bytes())
        .u32(key.version.get());
    let below = key.version.get() - 1;
    obj(vec![
        ("version", n(u64::from(key.version.get()))),
        ("key_info_hex", h(&key_info.finish().unwrap())),
        ("subkey_hex", h(&*ring_subkey(key, newer))),
        ("aad_hex", h(&ring_aad(&origin(), key).unwrap())),
        (
            "plaintext_hex",
            h(&[below.to_be_bytes().as_slice(), older.expose()].concat()),
        ),
    ])
}

fn ring_subkey(key: KeyRef, newer: &ScopeKey) -> zeroize::Zeroizing<[u8; 32]> {
    let mut info = Frame::new(Label::RingKey);
    info.origin(&origin())
        .scope(key.scope())
        .lp(key.purpose.name().as_bytes())
        .u32(key.version.get());
    crate::crypto::hkdf32(newer.expose(), &info.finish().unwrap()).unwrap()
}

// A ring whose entry names `entry_version`, which only a broken or hostile writer makes.
fn seal_ring_entry(key: KeyRef, newer: &ScopeKey, entry_version: u32, older: &ScopeKey, nonce: [u8; 12]) -> Ring {
    let subkey = ring_subkey(key, newer);
    let plaintext = [entry_version.to_be_bytes().as_slice(), older.expose()].concat();
    let ct = crate::crypto::aes_seal(&subkey, &nonce, &ring_aad(&origin(), key).unwrap(), &plaintext).unwrap();
    Ring {
        nonce,
        ct: ct.try_into().unwrap(),
    }
}

fn wrap_json(wrap: &Wrap) -> JsonValue {
    super::gen_basic::record(
        "key.wrap",
        &KeyRecordId::Wrap(wrap.target).to_wire(),
        &body_json(&KeyBody::Wrap(WrapBody::of(wrap))),
    )
}

fn trust_sample(a: &Account, m: &Account) -> TrustPlaintext {
    TrustPlaintext {
        pins: vec![
            TrustPin {
                account: a.id,
                ik: a.ik_public(),
                av: v(2),
                how: PinHow::Compared,
                alert: false,
                replaced: Vec::new(),
            },
            TrustPin {
                account: m.id,
                ik: m.ik_public(),
                av: v(2),
                how: PinHow::Replaced,
                alert: true,
                replaced: vec![crate::trust::Replaced {
                    ik: Ed25519Seed::from_bytes(draw("wraps/M old IK")).public().unwrap(),
                    av: v(2),
                }],
            },
        ],
        versions: vec![
            TrustVersion {
                owner: a.id.0,
                purpose: KeyPurpose::Personal,
                version: v(2),
                record: draw("wraps/personal record"),
            },
            TrustVersion {
                owner: a.id.0,
                purpose: KeyPurpose::History,
                version: v(2),
                record: draw("wraps/history record"),
            },
            TrustVersion {
                owner: uuid_from_wire(TEAM_T).unwrap(),
                purpose: KeyPurpose::Team,
                version: v(7),
                record: draw("wraps/team record"),
            },
        ],
    }
}

#[expect(
    clippy::too_many_lines,
    reason = "one case per wrap purpose and recipient type, and each negative row"
)]
pub(super) fn wraps(cache: &HpkeCache) -> JsonValue {
    let a = Account::new("wraps/A", ACCOUNT_A, 2);
    let m = Account::new("wraps/M", ACCOUNT_M, 1);
    let approver = device("wraps/approver");
    let new_device = device("wraps/new device");
    let team = uuid_from_wire(TEAM_T).unwrap();
    let wrapper_a = Wrapper {
        account: a.id,
        av: v(2),
        key_device: approver.key_device,
    };

    let account_target = device_target(a.id, WrapPurpose::Account, v(2), new_device.key_device);
    let trust_target = device_target(a.id, WrapPurpose::Trust, v(2), new_device.key_device);
    let trust = trust_sample(&a, &m);
    let trust_padded = crate::padding::pad(trust.encode().as_bytes()).unwrap();
    let personal = scope_key("wraps/personal key");
    let history = scope_key("wraps/history key");
    let team_key = scope_key("wraps/team key");
    let personal_ref = KeyRef {
        owner: a.id.0,
        purpose: KeyPurpose::Personal,
        version: v(2),
    };
    let history_ref = KeyRef {
        owner: a.id.0,
        purpose: KeyPurpose::History,
        version: v(2),
    };
    let team_ref = KeyRef {
        owner: team,
        purpose: KeyPurpose::Team,
        version: v(7),
    };

    struct Made {
        name: &'static str,
        wrap: Wrap,
        recipient_secret: crate::keys::X25519Secret,
        plaintext: Vec<u8>,
        signer: Ed25519Seed,
    }
    let made = vec![
        Made {
            name: "account keys to a new device",
            wrap: cache.wrap(
                account_target,
                &new_device.dek,
                a.at(2).to_plaintext().as_slice(),
                wrapper_a,
                &approver.dsk,
            ),
            recipient_secret: new_device.dek.clone(),
            plaintext: a.at(2).to_plaintext().to_vec(),
            signer: approver.dsk.clone(),
        },
        Made {
            name: "trust to a new device",
            wrap: cache.wrap(trust_target, &new_device.dek, &trust_padded, wrapper_a, &approver.dsk),
            recipient_secret: new_device.dek.clone(),
            plaintext: trust_padded.to_vec(),
            signer: approver.dsk.clone(),
        },
        Made {
            name: "a personal key to the account",
            wrap: cache.wrap(
                scope_key_target(personal_ref, a.id, v(2)),
                &a.at(2).aek,
                personal.expose(),
                wrapper_a,
                &a.at(2).ask,
            ),
            recipient_secret: a.at(2).aek.clone(),
            plaintext: personal.expose().to_vec(),
            signer: a.at(2).ask.clone(),
        },
        Made {
            name: "a history key to the account",
            wrap: cache.wrap(
                scope_key_target(history_ref, a.id, v(2)),
                &a.at(2).aek,
                history.expose(),
                wrapper_a,
                &a.at(2).ask,
            ),
            recipient_secret: a.at(2).aek.clone(),
            plaintext: history.expose().to_vec(),
            signer: a.at(2).ask.clone(),
        },
        Made {
            name: "a team key to a member",
            wrap: cache.wrap(
                scope_key_target(team_ref, m.id, v(1)),
                &m.at(1).aek,
                team_key.expose(),
                wrapper_a,
                &a.at(2).ask,
            ),
            recipient_secret: m.at(1).aek.clone(),
            plaintext: team_key.expose().to_vec(),
            signer: a.at(2).ask.clone(),
        },
    ];
    let mut cases = Vec::new();
    for made in &made {
        let pk_r = made.recipient_secret.public().unwrap();
        let info = wrap_info(&origin(), made.wrap.target, &pk_r).unwrap();
        cases.push(case(
            made.name,
            "wrap",
            vec![
                ("origin", s(ORIGIN)),
                ("id", s(&KeyRecordId::Wrap(made.wrap.target).to_wire())),
                ("pk_r_hex", h(&pk_r.0)),
                ("sk_r_hex", h(made.recipient_secret.expose())),
                ("plaintext_hex", h(&made.plaintext)),
                ("signer_seed_hex", h(made.signer.expose())),
                ("signer_hex", h(&made.signer.public().unwrap().0)),
            ],
            vec![
                ("info_hex", h(&info)),
                ("enc_hex", h(&made.wrap.enc)),
                ("ct_hex", h(&made.wrap.ct)),
                (
                    "sig_message_hex",
                    h(&wrap_sig_message(&info, &made.wrap.enc, &made.wrap.ct, made.wrap.wrapper).unwrap()),
                ),
                ("sig_hex", h(&made.wrap.sig.0)),
                ("record", wrap_json(&made.wrap)),
            ],
        ));
    }

    let account_wrap = &made[0].wrap;
    let team_wrap = &made[4].wrap;
    let team_record =
        VersionRecord::sign(&origin(), team_ref, Start::Next, &team_key, a.id, v(2), &a.at(2).ask).unwrap();
    let open = |name: &str,
                row: &str,
                mode: &str,
                wrap: &Wrap,
                secret: &crate::keys::X25519Secret,
                certified: &[u8],
                signer: &[u8],
                extra: Vec<(&str, JsonValue)>,
                error: &str,
                server: Option<&str>| {
        let mut input = vec![
            ("origin", s(ORIGIN)),
            ("mode", s(mode)),
            ("record", wrap_json(wrap)),
            ("recipient_secret_hex", h(secret.expose())),
            ("certified_pk_hex", h(certified)),
            ("signer_hex", h(signer)),
        ];
        input.extend(extra);
        negative(name, "open_wrap", row, input, error, server)
    };
    let a_public = a.at(2).public().unwrap();
    let account_certificate = || {
        vec![
            ("certificate_ask_hex", h(&a_public.ask.0)),
            ("certificate_aek_hex", h(&a_public.aek.0)),
        ]
    };
    // A signature no key could make is keys.signature, even under the DSK this side compared.
    let mut s_past_l = account_wrap.clone();
    s_past_l.sig.0[32..].copy_from_slice(&add_l(&account_wrap.sig.0[32..]).expect("S + L fits 256 bits"));
    let mut r_not_canonical = account_wrap.clone();
    r_not_canonical.sig.0[..32]
        .copy_from_slice(&hex::decode("eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f").unwrap());
    let malformed: Vec<JsonValue> = [
        ("an approval wrap whose signature has S + L", s_past_l),
        (
            "an approval wrap whose signature has a non-canonical R",
            r_not_canonical,
        ),
    ]
    .into_iter()
    .map(|(name, wrap)| {
        open(
            name,
            "An Ed25519 A of small order, a non-canonical A or R, S at or above L",
            "account",
            &wrap,
            &new_device.dek,
            &new_device.dek.public().unwrap().0,
            &approver.dsk.public().unwrap().0,
            account_certificate(),
            "keys.signature",
            BAD_STATEMENT,
        )
    })
    .collect();
    let mut opens = vec![
        open(
            "an approval wrap signed by ASK",
            "An approval wrap signed by ASK, or by a DSK other than the compared one",
            "account",
            &cache.wrap(
                account_target,
                &new_device.dek,
                a.at(2).to_plaintext().as_slice(),
                wrapper_a,
                &a.at(2).ask,
            ),
            &new_device.dek,
            &new_device.dek.public().unwrap().0,
            &approver.dsk.public().unwrap().0,
            account_certificate(),
            "keys.not_compared",
            BAD_STATEMENT,
        ),
        open(
            "an approval wrap checked under a DSK this side did not compare",
            "An approval wrap signed by ASK, or by a DSK other than the compared one",
            "account",
            account_wrap,
            &new_device.dek,
            &new_device.dek.public().unwrap().0,
            &device("wraps/stranger").dsk.public().unwrap().0,
            account_certificate(),
            "keys.not_compared",
            BAD_STATEMENT,
        ),
        open(
            "a trust wrap checked under a DSK this side did not compare",
            "An approval wrap signed by ASK, or by a DSK other than the compared one",
            "trust",
            &made[1].wrap,
            &new_device.dek,
            &new_device.dek.public().unwrap().0,
            &device("wraps/stranger").dsk.public().unwrap().0,
            vec![],
            "keys.not_compared",
            BAD_STATEMENT,
        ),
        open(
            "account keys that do not give the certificate's public keys",
            "Account keys in a wrap or blob that do not match their certificate",
            "account",
            account_wrap,
            &new_device.dek,
            &new_device.dek.public().unwrap().0,
            &approver.dsk.public().unwrap().0,
            vec![
                ("certificate_ask_hex", h(&m.ask(1).0)),
                ("certificate_aek_hex", h(&a_public.aek.0)),
            ],
            "keys.mismatch",
            None,
        ),
        open(
            "a wrap whose pkR differs from the recipient's certificate",
            "A wrap whose signature fails, or whose `pkR` differs from the recipient's certificate",
            "scope_key",
            team_wrap,
            &m.at(1).aek,
            &a.aek(1).0,
            &a.ask(2).0,
            vec![("version_record", version_record_json(&team_record))],
            "keys.mismatch",
            BAD_STATEMENT,
        ),
        open(
            "a wrap whose signature fails",
            "A wrap whose signature fails, or whose `pkR` differs from the recipient's certificate",
            "scope_key",
            &Wrap {
                sig: Signature([0x11; 64]),
                ..team_wrap.clone()
            },
            &m.at(1).aek,
            &m.aek(1).0,
            &a.ask(2).0,
            vec![("version_record", version_record_json(&team_record))],
            "keys.signature",
            BAD_STATEMENT,
        ),
    ];
    let other_record = VersionRecord::sign(
        &origin(),
        team_ref,
        Start::Next,
        &scope_key("wraps/another team key"),
        a.id,
        v(2),
        &a.at(2).ask,
    )
    .unwrap();
    opens.push(open(
        "a wrapped key that does not match its version's kid",
        "A `kid` mismatch, from a wrap or a ring",
        "scope_key",
        team_wrap,
        &m.at(1).aek,
        &m.aek(1).0,
        &a.ask(2).0,
        vec![("version_record", version_record_json(&other_record))],
        "keys.kid",
        None,
    ));
    opens.push(case(
        "a team key opens for its member",
        "open_wrap",
        vec![
            ("origin", s(ORIGIN)),
            ("mode", s("scope_key")),
            ("record", wrap_json(team_wrap)),
            ("recipient_secret_hex", h(m.at(1).aek.expose())),
            ("certified_pk_hex", h(&m.aek(1).0)),
            ("signer_hex", h(&a.ask(2).0)),
            ("version_record", version_record_json(&team_record)),
        ],
        vec![("key_hex", h(team_key.expose()))],
    ));
    opens.push(case(
        "trust opens for the new device",
        "open_wrap",
        vec![
            ("origin", s(ORIGIN)),
            ("mode", s("trust")),
            ("record", wrap_json(&made[1].wrap)),
            ("recipient_secret_hex", h(new_device.dek.expose())),
            ("certified_pk_hex", h(&new_device.dek.public().unwrap().0)),
            ("signer_hex", h(&approver.dsk.public().unwrap().0)),
        ],
        vec![("trust", s(&trust.encode()))],
    ));
    opens.extend(malformed);

    let info = wrap_info(&origin(), team_wrap.target, &m.aek(1)).unwrap();
    let mut hpke = Vec::new();
    let row = "A wrong label, or each AAD or `info` field changed";
    let mut changed_infos: Vec<(&str, Vec<u8>)> = Vec::new();
    let other_origin = crate::encoding::Origin::parse("https://other.example.com").unwrap();
    changed_infos.push(("origin", wrap_info(&other_origin, team_wrap.target, &m.aek(1)).unwrap()));
    changed_infos.push((
        "owner",
        wrap_info(
            &origin(),
            crate::wrap::WrapTarget {
                owner: a.id.0,
                ..team_wrap.target
            },
            &m.aek(1),
        )
        .unwrap(),
    ));
    changed_infos.push((
        "purpose",
        wrap_info(
            &origin(),
            crate::wrap::WrapTarget {
                purpose: WrapPurpose::Key(KeyPurpose::Personal),
                ..team_wrap.target
            },
            &m.aek(1),
        )
        .unwrap(),
    ));
    changed_infos.push((
        "version",
        wrap_info(
            &origin(),
            crate::wrap::WrapTarget {
                version: v(8),
                ..team_wrap.target
            },
            &m.aek(1),
        )
        .unwrap(),
    ));
    changed_infos.push((
        "recipient id",
        wrap_info(
            &origin(),
            crate::wrap::WrapTarget {
                recipient: crate::wrap::Recipient::Account(a.id),
                ..team_wrap.target
            },
            &m.aek(1),
        )
        .unwrap(),
    ));
    changed_infos.push((
        "recipient version",
        wrap_info(
            &origin(),
            crate::wrap::WrapTarget {
                recipient_version: v(2),
                ..team_wrap.target
            },
            &m.aek(1),
        )
        .unwrap(),
    ));
    changed_infos.push(("pkR", wrap_info(&origin(), team_wrap.target, &a.aek(1)).unwrap()));
    let mut relabelled = info.clone();
    relabelled[4 + "tablepro/v1/".len()] = b'W';
    changed_infos.push(("label", relabelled));
    for (field, changed) in changed_infos {
        hpke.push(negative(
            &format!("the wrap info with its {field} changed"),
            "hpke_open",
            row,
            vec![
                ("sk_hex", h(m.at(1).aek.expose())),
                ("enc_hex", h(&team_wrap.enc)),
                ("ct_hex", h(&team_wrap.ct)),
                ("info_hex", h(&changed)),
            ],
            "keys.open",
            None,
        ));
    }
    let low_order = hex::decode("0000000000000000000000000000000000000000000000000000000000000000").unwrap();
    let order_eight = hex::decode("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800").unwrap();
    for (name, point) in [("zero", &low_order), ("a point of order 8", &order_eight)] {
        hpke.push(negative(
            &format!("an enc that is {name}"),
            "hpke_open",
            "Errors table: keys.public_key, an X25519 key whose shared secret is all zero (RFC 9180 section 7.1.4)",
            vec![
                ("sk_hex", h(m.at(1).aek.expose())),
                ("enc_hex", h(point)),
                ("ct_hex", h(&team_wrap.ct)),
                ("info_hex", h(&info)),
            ],
            "keys.public_key",
            None,
        ));
        hpke.push(negative(
            &format!("sealing to a recipient key that is {name}"),
            "hpke_seal",
            "Errors table: keys.public_key, an X25519 key whose shared secret is all zero (RFC 9180 section 7.1.4)",
            vec![
                ("pk_hex", h(point)),
                ("info_hex", h(&info)),
                ("plaintext_hex", h(team_key.expose())),
            ],
            "keys.public_key",
            None,
        ));
    }

    let stale = vec![negative(
        "a wrap signed under an older av than its signer's newest: it opens and adds no holder",
        "check_signed_under_newest",
        "A wrap signed under an older `av` than its signer's newest: opens, adds no holder",
        vec![("signed_under", n(1)), ("newest_known", n(2))],
        "keys.stale",
        None,
    )];

    file(
        "wraps",
        "Wraps of every purpose and recipient type, their signatures, opening them and HPKE refusals (ADR 0056, Signed objects and wraps)",
        vec![
            ("wraps", arr(cases)),
            ("open", arr(opens)),
            ("hpke", arr(hpke)),
            ("advancing", arr(stale)),
            (
                "trust",
                arr(vec![obj(vec![
                    ("name", s("the trust plaintext the trust wrap carries")),
                    ("text", s(&trust.encode())),
                ])]),
            ),
        ],
    )
}
