use super::fixtures::{ACCOUNT_A, Account, ORIGIN, TEAM_T, device, draw, origin, scope_key, v};
use super::out::{arr, b, case, file, negative, obj, s};
use crate::body::{AccountBody, DeviceBody, KeyBody, ResetBody, VersionBody, body_json};
use crate::cert::{AccountCertificate, CertKind, DeviceCertificate};
use crate::encoding::{KeyPurpose, uuid_from_wire};
use crate::json::JsonValue;
use crate::record_id::KeyRecordId;
use crate::scope_key::{KeyRef, Start, VersionRecord};

const ROW_SUITE: &str = "A suite not listed";
const ROW_ENCODING: &str = "Non-canonical base64url, a wrong length, a version of 0 or at or above 2^31; a key object body with a duplicate, missing, unknown or wrongly typed member; a plaintext with a duplicate, missing or wrongly typed member";

fn object(kind: &str, id: &str, fields_text: &str) -> JsonValue {
    obj(vec![("kind", s(kind)), ("id", s(id)), ("fields_text", s(fields_text))])
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn bodies() -> JsonValue {
    let a = Account::new("bodies/A", ACCOUNT_A, 2);
    let account = AccountCertificate::sign(
        &origin(),
        a.id,
        v(1),
        CertKind::GenesisOrRotation,
        &a.ik,
        a.at(1).public().unwrap(),
        None,
    )
    .unwrap();
    let account_id = KeyRecordId::Account {
        account: a.id,
        av: v(1),
    }
    .to_wire();
    let account_text = body_json(&KeyBody::Account(AccountBody::of(&account)));
    let laptop = device("bodies/laptop");
    let device_certificate = DeviceCertificate::sign(
        &origin(),
        a.id,
        v(1),
        laptop.key_device,
        laptop.dek.public().unwrap(),
        laptop.dsk.public().unwrap(),
        &a.at(1).ask,
    )
    .unwrap();
    let device_text = body_json(&KeyBody::Device(DeviceBody::of(&device_certificate)));
    let team = uuid_from_wire(TEAM_T).unwrap();
    let key_ref = KeyRef {
        owner: team,
        purpose: KeyPurpose::Team,
        version: v(2),
    };
    let version = VersionRecord::sign(
        &origin(),
        key_ref,
        Start::Next,
        &scope_key("bodies/TK"),
        a.id,
        v(1),
        &a.at(1).ask,
    )
    .unwrap();
    let version_id = KeyRecordId::Version(key_ref).to_wire();
    let version_text = body_json(&KeyBody::Version(VersionBody::of(&version)));

    let mut cases = vec![
        case(
            "a genesis certificate",
            "key_object",
            vec![("object", object("key.account", &account_id, &account_text))],
            vec![("ok", b(true))],
        ),
        case(
            "a version record",
            "key_object",
            vec![("object", object("key.version", &version_id, &version_text))],
            vec![("ok", b(true))],
        ),
    ];
    let bad = |name: &str, row: &str, kind: &str, id: &str, text: String, error: &str| {
        negative(
            name,
            "key_object",
            row,
            vec![("object", object(kind, id, &text))],
            error,
            Some("bad_statement"),
        )
    };
    let sig = crate::b64::encode(&account.sig.0);
    let ik = crate::b64::encode(&account.ik.0);
    cases.extend([
        bad(
            "suite tp2",
            ROW_SUITE,
            "key.account",
            &account_id,
            account_text.replace("\"tp1\"", "\"tp2\""),
            "keys.suite",
        ),
        bad(
            "a duplicate member",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(",\"kind\":0", ",\"kind\":0,\"kind\":0", 1),
            "keys.encoding",
        ),
        bad(
            "a missing member",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(&format!(",\"sig\":\"{sig}\""), "", 1),
            "keys.encoding",
        ),
        bad(
            "an unknown member",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen("{\"suite\"", "{\"note\":\"x\",\"suite\"", 1),
            "keys.encoding",
        ),
        bad(
            "replace_sig on a kind 0 certificate",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen('}', &format!(",\"replace_sig\":\"{sig}\"}}"), 1),
            "keys.encoding",
        ),
        bad(
            "a wrongly typed member",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen("\"kind\":0", "\"kind\":\"0\"", 1),
            "keys.encoding",
        ),
        bad(
            "an integer with a fraction",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen("\"kind\":0", "\"kind\":0.0", 1),
            "keys.encoding",
        ),
        bad(
            "a kind out of range",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen("\"kind\":0", "\"kind\":4", 1),
            "keys.encoding",
        ),
        bad(
            "a key of 31 bytes",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(&ik, &crate::b64::encode(&account.ik.0[..31]), 1),
            "keys.encoding",
        ),
        bad(
            "padded base64url",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(&ik, &format!("{ik}="), 1),
            "keys.encoding",
        ),
        bad(
            "non-zero pad bits",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(&ik, &nudge_last(&ik), 1),
            "keys.encoding",
        ),
        bad(
            "the standard alphabet",
            ROW_ENCODING,
            "key.account",
            &account_id,
            account_text.replacen(&ik, &format!("+{}", &ik[1..]), 1),
            "keys.encoding",
        ),
        bad(
            "signer_av 0",
            ROW_ENCODING,
            "key.version",
            &version_id,
            version_text.replacen("\"signer_av\":1", "\"signer_av\":0", 1),
            "keys.encoding",
        ),
        bad(
            "signer_av 2^31",
            ROW_ENCODING,
            "key.version",
            &version_id,
            version_text.replacen("\"signer_av\":1", "\"signer_av\":2147483648", 1),
            "keys.encoding",
        ),
        bad(
            "start 2",
            ROW_ENCODING,
            "key.version",
            &version_id,
            version_text.replacen("\"start\":0", "\"start\":2", 1),
            "keys.encoding",
        ),
        bad(
            "a lower-case signer",
            ROW_ENCODING,
            "key.version",
            &version_id,
            version_text.replacen(ACCOUNT_A, &ACCOUNT_A.to_lowercase(), 1),
            "keys.encoding",
        ),
        bad(
            "a version of 0 in the id",
            ROW_ENCODING,
            "key.version",
            &format!("{TEAM_T}/team/0"),
            version_text.clone(),
            "keys.encoding",
        ),
        bad(
            "a version of 2^31 in the id",
            ROW_ENCODING,
            "key.version",
            &format!("{TEAM_T}/team/2147483648"),
            version_text.clone(),
            "keys.encoding",
        ),
        bad(
            "a version with a leading zero in the id",
            ROW_ENCODING,
            "key.version",
            &format!("{TEAM_T}/team/02"),
            version_text.clone(),
            "keys.encoding",
        ),
        bad(
            "not an object",
            ROW_ENCODING,
            "key.device",
            &format!("{ACCOUNT_A}/{}/1", laptop.key_device.to_wire()),
            format!("[{device_text}]"),
            "keys.encoding",
        ),
    ]);

    let reset_certificate = AccountCertificate::sign(
        &origin(),
        a.id,
        v(2),
        CertKind::ResetKeepingKeys,
        &crate::keys::Ed25519Seed::from_bytes(draw("bodies/reset IK")),
        a.at(2).public().unwrap(),
        None,
    )
    .unwrap();
    let reset_device = DeviceCertificate::sign(
        &origin(),
        a.id,
        v(2),
        laptop.key_device,
        laptop.dek.public().unwrap(),
        laptop.dsk.public().unwrap(),
        &a.at(2).ask,
    )
    .unwrap();
    let blob =
        a.r.seal_blob_with_nonce(&origin(), a.id, v(2), a.at(2), draw("bodies/reset blob nonce"))
            .unwrap();
    let reset = ResetBody {
        av: v(2),
        key_device: laptop.key_device,
        account: AccountBody::of(&reset_certificate),
        device: DeviceBody::of(&reset_device),
        recovery: blob,
    };
    let reset_id = format!(
        "{ACCOUNT_A}/{}",
        crate::encoding::ResetId(super::fixtures::draw_uuid("bodies/reset id")).to_wire()
    );
    let reset_text = body_json(&KeyBody::Reset(Box::new(reset.clone())));
    cases.push(case(
        "a reset proposal",
        "key_object",
        vec![("object", object("key.reset", &reset_id, &reset_text))],
        vec![("ok", b(true))],
    ));
    let kind_zero = ResetBody {
        account: AccountBody {
            kind: CertKind::GenesisOrRotation,
            ..reset.account.clone()
        },
        ..reset.clone()
    };
    cases.push(bad(
        "a reset proposing a kind 0 certificate",
        ROW_ENCODING,
        "key.reset",
        &reset_id,
        body_json(&KeyBody::Reset(Box::new(kind_zero))),
        "keys.encoding",
    ));
    cases.push(bad(
        "a suite not listed inside a reset",
        ROW_SUITE,
        "key.reset",
        &reset_id,
        reset_text
            .replacen("\"tp1\"", "\"tp2\"", 2)
            .replacen("\"tp2\"", "\"tp1\"", 1),
        "keys.suite",
    ));

    let same = vec![
        case(
            "the same object, members in another order",
            "same_object",
            vec![
                ("held", object("key.account", &account_id, &account_text)),
                ("offered", object("key.account", &account_id, &reorder(&account_text))),
            ],
            vec![("ok", b(true))],
        ),
        negative(
            "another object at a held id",
            "same_object",
            "A key object pushed again or pulled at a held id with other fields",
            vec![
                ("held", object("key.account", &account_id, &account_text)),
                (
                    "offered",
                    object(
                        "key.account",
                        &account_id,
                        &account_text.replacen(&sig, &crate::b64::encode(&[7; 64]), 1),
                    ),
                ),
            ],
            "keys.conflict",
            Some("create_only"),
        ),
    ];

    file(
        "bodies",
        "Key object bodies and ids as records carry them, and when two key objects are the same (ADR 0051, Key object bodies; ADR 0052, Key objects)",
        vec![
            ("origin", s(ORIGIN)),
            ("key_objects", arr(cases)),
            ("same_object", arr(same)),
        ],
    )
}

// The last base64url symbol of a 32-byte value moved to one with a non-zero pad bit.
fn nudge_last(text: &str) -> String {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let last = text.chars().last().unwrap_or('A');
    let index = alphabet.find(last).unwrap_or(0);
    let nudged = alphabet.chars().nth(index ^ 1).unwrap_or('B');
    format!("{}{nudged}", &text[..text.len() - 1])
}

// The same members, reversed.
fn reorder(text: &str) -> String {
    match crate::json::parse(text.as_bytes()).unwrap() {
        JsonValue::Object(mut members) => {
            members.reverse();
            JsonValue::Object(members).to_json()
        }
        other => other.to_json(),
    }
}
