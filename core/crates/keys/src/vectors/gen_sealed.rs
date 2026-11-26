use super::fixtures::{
    ACCOUNT_A, ACCOUNT_M, ORIGIN, TEAM_T, account_id, draw, draw_uuid, origin, scope_key, team_id, v,
};
use super::out::{arr, b, case, case_row, fields, file, h, n, negative, obj, raw, s};
use crate::body::sealed_json;
use crate::encoding::{HistoryId, KeyPurpose, Scope, uuid_to_wire};
use crate::envelope::{
    EnvelopeId, ParentKind, Platform, SecretKind, envelope_aad, envelope_plaintext, envelope_subkey, history_aad,
    history_plaintext, history_subkey, seal_envelope_plaintext, seal_history_plaintext,
};
use crate::json::JsonValue;
use crate::keys::{Ed25519Public, ScopeKey};
use crate::padding;
use crate::trust::{PinHow, RECORD_LIMIT, TrustPin, TrustPlaintext, TrustVersion, trust_wrap_record_len};

const PADDING_SIZES: [usize; 16] = [
    63, 64, 127, 128, 255, 256, 511, 512, 1023, 1024, 2047, 2048, 4095, 4096, 8191, 8192,
];

fn scope_json(scope: Scope) -> JsonValue {
    obj(vec![
        ("type", s(scope.type_name())),
        ("owner", s(&uuid_to_wire(scope.owner()))),
    ])
}

// A plaintext of exactly `size` bytes: the secret grows to fill it.
fn envelope_of_size(size: usize, dest: &JsonValue) -> String {
    let base = envelope_plaintext("", dest).unwrap();
    let secret = "s".repeat(size - base.len());
    envelope_plaintext(&secret, dest).unwrap().to_string()
}

struct EnvelopeCase<'a> {
    name: String,
    key: &'a ScopeKey,
    scope: Scope,
    id: EnvelopeId,
    kv: u32,
    plaintext: String,
}

fn envelope_case(made: &EnvelopeCase<'_>) -> JsonValue {
    let nonce: [u8; 12] = draw(&format!("envelopes/{}/nonce", made.name));
    let sealed = seal_envelope_plaintext(
        made.key,
        &origin(),
        made.scope,
        &made.id,
        v(made.kv),
        made.plaintext.as_bytes(),
        nonce,
    )
    .unwrap();
    let mut info = crate::encoding::Frame::new(crate::encoding::Label::EnvelopeKey);
    info.origin(&origin())
        .scope(made.scope)
        .lp(made.id.parent_kind.name().as_bytes())
        .lp(made.id.parent_id.as_bytes())
        .lp(made.id.secret_kind.name().as_bytes());
    case(
        &made.name,
        "envelope",
        vec![
            ("origin", s(ORIGIN)),
            ("scope", scope_json(made.scope)),
            ("id", s(&made.id.to_wire())),
            ("kv", n(u64::from(made.kv))),
            ("key_hex", h(made.key.expose())),
            ("plaintext", s(&made.plaintext)),
            ("nonce_hex", h(&nonce)),
        ],
        vec![
            ("subkey_info_hex", h(&info.finish().unwrap())),
            (
                "subkey_hex",
                h(&*envelope_subkey(made.key, &origin(), made.scope, &made.id).unwrap()),
            ),
            (
                "aad_hex",
                h(&envelope_aad(&origin(), made.scope, &made.id, v(made.kv)).unwrap()),
            ),
            ("plaintext_len", n(made.plaintext.len() as u64)),
            (
                "padded_len",
                n(padding::padded_len(made.plaintext.len()).unwrap() as u64),
            ),
            ("ct_hex", h(&sealed.ct)),
            ("fields", fields(&sealed_json(&sealed))),
        ],
    )
}

#[expect(
    clippy::too_many_lines,
    reason = "one case per secret kind and padding step, and each negative row"
)]
pub(super) fn envelopes() -> JsonValue {
    let account = account_id(ACCOUNT_A);
    let personal = Scope::Personal(account);
    let team = Scope::Team(team_id());
    let pk = scope_key("envelopes/PK 3");
    let tk = scope_key("envelopes/TK 7");
    let connection = "6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44";
    let library = "6f1c2a9e-0b4d-4c8e-9a51-3d7e2b1f0c44";
    let database_dest = raw(
        r#"{"engine":"postgres","host":"db.internal","port":5432,"user":"app","database":"orders","tls_mode":"verify_full","ssh_route":[{"host":"bastion.example.com","port":22,"user":"ops","key_path":"~/.ssh/id_ed25519"}]}"#,
    );
    let ssh_dest = raw(r#"{"host":"bastion.example.com","port":22,"user":"ops","key_path":"~/.ssh/id_ed25519"}"#);
    let user_dest = raw(r#"{"user":"app"}"#);
    let ai_dest = raw(r#"{"provider_type":"openai_compatible","endpoint":"https://ai.example.com/v1"}"#);
    let kinds: Vec<(ParentKind, &str, SecretKind, &JsonValue, Scope, &ScopeKey, u32)> = vec![
        (
            ParentKind::Connection,
            connection,
            SecretKind::Password,
            &database_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Connection,
            connection,
            SecretKind::SslKeyPassphrase,
            &database_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Connection,
            connection,
            SecretKind::SshPassword,
            &ssh_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Connection,
            connection,
            SecretKind::SshKeyPassphrase,
            &ssh_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Connection,
            connection,
            SecretKind::SshTotpSecret,
            &ssh_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Connection,
            connection,
            SecretKind::Plugin("api_token".to_owned()),
            &database_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::LibraryConnection,
            library,
            SecretKind::Password,
            &database_dest,
            team,
            &tk,
            7,
        ),
        (
            ParentKind::SshProfile,
            connection,
            SecretKind::SshKeyPassphrase,
            &ssh_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::CredentialProfile,
            connection,
            SecretKind::Password,
            &user_dest,
            personal,
            &pk,
            3,
        ),
        (
            ParentKind::Settings(Platform::Macos),
            "ai",
            SecretKind::AiKey("openai".to_owned()),
            &ai_dest,
            personal,
            &pk,
            3,
        ),
    ];
    let mut cases = Vec::new();
    for (parent, parent_id, secret_kind, dest, scope, key, kv) in kinds {
        let id = EnvelopeId::new(parent, parent_id, secret_kind).unwrap();
        let name = format!("{} of a {}", id.secret_kind.name(), id.parent_kind.name());
        let plaintext = envelope_plaintext("correct horse battery staple", dest)
            .unwrap()
            .to_string();
        cases.push(envelope_case(&EnvelopeCase {
            name,
            key,
            scope,
            id,
            kv,
            plaintext,
        }));
    }
    let password = EnvelopeId::new(ParentKind::Connection, connection, SecretKind::Password).unwrap();
    let small_dest = raw(r#"{"host":"db"}"#);
    let mut steps = Vec::new();
    for size in PADDING_SIZES {
        let plaintext = envelope_of_size(size, &small_dest);
        steps.push(envelope_case(&EnvelopeCase {
            name: format!("a {size}-byte plaintext"),
            key: &pk,
            scope: personal,
            id: password.clone(),
            kv: 3,
            plaintext,
        }));
    }

    let sealed_with = |plaintext: &[u8], padded: Option<Vec<u8>>| {
        let nonce: [u8; 12] = draw("envelopes/negative nonce");
        match padded {
            None => seal_envelope_plaintext(&pk, &origin(), personal, &password, v(3), plaintext, nonce).unwrap(),
            Some(padded) => {
                let subkey = envelope_subkey(&pk, &origin(), personal, &password).unwrap();
                let ct = crate::crypto::aes_seal(
                    &subkey,
                    &nonce,
                    &envelope_aad(&origin(), personal, &password, v(3)).unwrap(),
                    &padded,
                )
                .unwrap();
                crate::envelope::Sealed { kv: v(3), nonce, ct }
            }
        }
    };
    let open = |name: &str,
                row: &str,
                scope: Scope,
                id: &str,
                origin_text: &str,
                sealed: &crate::envelope::Sealed,
                error: &str,
                server: Option<&str>| {
        negative(
            name,
            "open_envelope",
            row,
            vec![
                ("origin", s(origin_text)),
                ("scope", scope_json(scope)),
                ("id", s(id)),
                ("key_hex", h(pk.expose())),
                ("fields", fields(&sealed_json(sealed))),
            ],
            error,
            server,
        )
    };
    let good = sealed_with(envelope_plaintext("hunter2", &small_dest).unwrap().as_bytes(), None);
    let aad_row = "A wrong label, or each AAD or `info` field changed";
    let mut opens = vec![
        open(
            "another origin",
            aad_row,
            personal,
            &password.to_wire(),
            "https://other.example.com",
            &good,
            "keys.open",
            None,
        ),
        open(
            "another scope",
            aad_row,
            team,
            &password.to_wire(),
            ORIGIN,
            &good,
            "keys.open",
            None,
        ),
        open(
            "another parent kind",
            aad_row,
            personal,
            &format!("ssh_profile/{connection}/ssh_password"),
            ORIGIN,
            &good,
            "keys.open",
            None,
        ),
        open(
            "another record id",
            aad_row,
            personal,
            "connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C45/password",
            ORIGIN,
            &good,
            "keys.open",
            None,
        ),
        open(
            "another secret kind",
            aad_row,
            personal,
            &format!("connection/{connection}/ssl_key_passphrase"),
            ORIGIN,
            &good,
            "keys.open",
            None,
        ),
        open(
            "another kv",
            aad_row,
            personal,
            &password.to_wire(),
            ORIGIN,
            &crate::envelope::Sealed {
                kv: v(2),
                ..good.clone()
            },
            "keys.open",
            None,
        ),
    ];
    let plaintext_row = "Non-canonical base64url, a wrong length, a version of 0 or at or above 2^31; a key object body with a duplicate, missing, unknown or wrongly typed member; a plaintext with a duplicate, missing or wrongly typed member";
    for (name, text) in [
        (
            "a duplicate member",
            r#"{"v":1,"secret":"a","secret":"b","dest":{"host":"db"}}"#,
        ),
        (
            "a duplicate member inside dest",
            r#"{"v":1,"secret":"a","dest":{"host":"db","host":"evil"}}"#,
        ),
        ("a missing member", r#"{"v":1,"dest":{"host":"db"}}"#),
        ("a wrongly typed member", r#"{"v":1,"secret":7,"dest":{"host":"db"}}"#),
        ("dest not an object", r#"{"v":1,"secret":"a","dest":"db"}"#),
        ("an unknown v", r#"{"v":2,"secret":"a","dest":{"host":"db"}}"#),
        ("v as text", r#"{"v":"1","secret":"a","dest":{"host":"db"}}"#),
        ("not JSON", r#"{"v":1,"secret":"a","dest":{"host":"db"}"#),
    ] {
        opens.push(open(
            name,
            plaintext_row,
            personal,
            &password.to_wire(),
            ORIGIN,
            &sealed_with(text.as_bytes(), None),
            "keys.encoding",
            None,
        ));
    }
    let unknown = sealed_with(
        br#"{"v":1,"secret":"hunter2","dest":{"host":"db"},"later":{"x":1}}"#,
        None,
    );
    opens.push(case_row(
        "a member the reader does not know is ignored",
        "open_envelope",
        "A plaintext with a member the reader does not know",
        vec![
            ("origin", s(ORIGIN)),
            ("scope", scope_json(personal)),
            ("id", s(&password.to_wire())),
            ("key_hex", h(pk.expose())),
            ("fields", fields(&sealed_json(&unknown))),
        ],
        vec![("secret", s("hunter2")), ("dest", small_dest.clone())],
    ));
    let padding_row = "Padding with no 0x80, a non-zero byte after it, or a length off the scale";
    let text = br#"{"v":1,"secret":"a","dest":{}}"#;
    let mut no_marker = text.to_vec();
    no_marker.resize(64, 0);
    let mut after = padding::pad(text).unwrap().to_vec();
    after[60] = 1;
    let mut off_scale = padding::pad(text).unwrap().to_vec();
    off_scale.resize(96, 0);
    opens.push(open(
        "padding with no 0x80",
        padding_row,
        personal,
        &password.to_wire(),
        ORIGIN,
        &sealed_with(text, Some(no_marker)),
        "keys.encoding",
        None,
    ));
    opens.push(open(
        "a non-zero byte after 0x80",
        padding_row,
        personal,
        &password.to_wire(),
        ORIGIN,
        &sealed_with(text, Some(after)),
        "keys.encoding",
        None,
    ));
    opens.push(open(
        "a padded length off the scale",
        padding_row,
        personal,
        &password.to_wire(),
        ORIGIN,
        &sealed_with(text, Some(off_scale)),
        "keys.encoding",
        None,
    ));

    let truncated_row = "A truncated nonce, tag or `ct`, a ring `ct` other than 52 bytes";
    let mut sealed_fields = Vec::new();
    for (name, mutate) in [("a truncated nonce", 0), ("a truncated ct", 1), ("a ct with no tag", 2)] {
        let mut broken = good.clone();
        let text = match mutate {
            0 => sealed_json(&good).replace(&crate::b64::encode(&good.nonce), &crate::b64::encode(&good.nonce[..11])),
            1 => {
                broken.ct.truncate(broken.ct.len() - 1);
                sealed_json(&broken)
            }
            _ => {
                broken.ct.truncate(64);
                sealed_json(&broken)
            }
        };
        sealed_fields.push(negative(
            name,
            "sealed_fields",
            truncated_row,
            vec![("fields", fields(&text))],
            "keys.encoding",
            None,
        ));
    }
    sealed_fields.push(negative(
        "a suite not listed",
        "sealed_fields",
        "A suite not listed",
        vec![("fields", fields(&sealed_json(&good).replace("\"tp1\"", "\"tp2\"")))],
        "keys.suite",
        Some("bad_statement"),
    ));

    let destination = vec![
        case(
            "the same destination, members in another order",
            "check_destination",
            vec![
                ("sealed", database_dest.clone()),
                (
                    "current",
                    raw(
                        r#"{"ssh_route":[{"key_path":"~/.ssh/id_ed25519","user":"ops","port":22,"host":"bastion.example.com"}],"tls_mode":"verify_full","database":"orders","user":"app","port":5432,"host":"db.internal","engine":"postgres"}"#,
                    ),
                ),
            ],
            vec![("ok", b(true))],
        ),
        negative(
            "a host the server rewrote",
            "check_destination",
            "A sealed destination that differs from the record's",
            vec![
                ("sealed", database_dest.clone()),
                (
                    "current",
                    raw(
                        r#"{"engine":"postgres","host":"evil.example.com","port":5432,"user":"app","database":"orders","tls_mode":"verify_full","ssh_route":[{"host":"bastion.example.com","port":22,"user":"ops","key_path":"~/.ssh/id_ed25519"}]}"#,
                    ),
                ),
            ],
            "keys.destination",
            None,
        ),
        negative(
            "an SSH hop added",
            "check_destination",
            "A sealed destination that differs from the record's",
            vec![
                ("sealed", ssh_dest.clone()),
                (
                    "current",
                    raw(
                        r#"{"host":"bastion.example.com","port":22,"user":"ops","key_path":"~/.ssh/id_ed25519","extra":1}"#,
                    ),
                ),
            ],
            "keys.destination",
            None,
        ),
    ];
    let order = vec![
        negative(
            "an envelope below the copy held",
            "check_not_below",
            "An envelope below the version in force at its place in the order, or below the copy held; the same envelope before the rotation that follows it, taken",
            vec![("held", n(4)), ("offered", n(3))],
            "keys.stale",
            Some("key_version_stale"),
        ),
        case(
            "the same envelope at the version held",
            "check_not_below",
            vec![("held", n(4)), ("offered", n(4))],
            vec![("ok", b(true))],
        ),
    ];

    file(
        "envelopes",
        "Secret envelopes for each secret kind and on each side of every padding step, with their refusals (ADR 0056, Envelopes and history)",
        vec![
            ("kinds", arr(cases)),
            ("padding_steps", arr(steps)),
            ("open", arr(opens)),
            ("sealed_fields", arr(sealed_fields)),
            ("destination", arr(destination)),
            ("order", arr(order)),
        ],
    )
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn history() -> JsonValue {
    let account = account_id(ACCOUNT_A);
    let hk = scope_key("history/HK 2");
    let id = HistoryId(draw_uuid("history/entry id"));
    let mut cases = Vec::new();
    for size in PADDING_SIZES {
        let base = history_plaintext(&raw(r#"{"query":""}"#)).unwrap().len();
        let entry = raw(&format!(r#"{{"query":"{}"}}"#, "q".repeat(size - base)));
        let plaintext = history_plaintext(&entry).unwrap().to_string();
        let nonce: [u8; 12] = draw(&format!("history/{size}/nonce"));
        let sealed = seal_history_plaintext(&hk, &origin(), account, id, v(2), plaintext.as_bytes(), nonce).unwrap();
        let mut info = crate::encoding::Frame::new(crate::encoding::Label::HistoryKey);
        info.origin(&origin())
            .scope(Scope::History(account))
            .lp(id.to_wire().as_bytes());
        cases.push(case(
            &format!("a {size}-byte plaintext"),
            "history_entry",
            vec![
                ("origin", s(ORIGIN)),
                ("account", s(ACCOUNT_A)),
                ("id", s(&id.to_wire())),
                ("kv", n(2)),
                ("key_hex", h(hk.expose())),
                ("plaintext", s(&plaintext)),
                ("nonce_hex", h(&nonce)),
            ],
            vec![
                ("subkey_info_hex", h(&info.finish().unwrap())),
                ("subkey_hex", h(&*history_subkey(&hk, &origin(), account, id).unwrap())),
                ("aad_hex", h(&history_aad(&origin(), account, id, v(2)).unwrap())),
                ("plaintext_len", n(plaintext.len() as u64)),
                ("padded_len", n(padding::padded_len(plaintext.len()).unwrap() as u64)),
                ("ct_hex", h(&sealed.ct)),
                ("fields", fields(&sealed_json(&sealed))),
            ],
        ));
    }
    let entry = history_plaintext(&raw(r#"{"query":"select 1"}"#)).unwrap();
    let sealed = seal_history_plaintext(
        &hk,
        &origin(),
        account,
        id,
        v(2),
        entry.as_bytes(),
        draw("history/negative nonce"),
    )
    .unwrap();
    let open = |name: &str, account_text: &str, id_text: &str, sealed: &crate::envelope::Sealed| {
        negative(
            name,
            "open_history",
            "A wrong label, or each AAD or `info` field changed",
            vec![
                ("origin", s(ORIGIN)),
                ("account", s(account_text)),
                ("id", s(id_text)),
                ("key_hex", h(hk.expose())),
                ("fields", fields(&sealed_json(sealed))),
            ],
            "keys.open",
            None,
        )
    };
    let opens = vec![
        open(
            "another record id",
            ACCOUNT_A,
            &HistoryId(draw_uuid("history/other id")).to_wire(),
            &sealed,
        ),
        open("another account", ACCOUNT_M, &id.to_wire(), &sealed),
        open(
            "another kv",
            ACCOUNT_A,
            &id.to_wire(),
            &crate::envelope::Sealed {
                kv: v(1),
                ..sealed.clone()
            },
        ),
    ];
    let hk3 = scope_key("history/HK 3");
    let again = seal_history_plaintext(
        &hk3,
        &origin(),
        account,
        id,
        v(3),
        entry.as_bytes(),
        draw("history/again nonce"),
    )
    .unwrap();
    let pushed_again = vec![case(
        "an entry pushed again after an HK rotation, under the newest version",
        "open_history",
        vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("id", s(&id.to_wire())),
            ("key_hex", h(hk3.expose())),
            ("fields", fields(&sealed_json(&again))),
        ],
        vec![("entry", raw(r#"{"query":"select 1"}"#))],
    )];
    file(
        "history",
        "History entries on each side of every padding step (ADR 0056, Envelopes and history)",
        vec![
            ("padding_steps", arr(cases)),
            ("open", arr(opens)),
            ("pushed_again", arr(pushed_again)),
        ],
    )
}

// `count` compared pins, the account of pin i being 019A0000-0000-7000-8000- and i in 12 hex digits.
fn generated_trust_of(count: usize) -> TrustPlaintext {
    let ik = Ed25519Public(
        crate::keys::Ed25519Seed::from_bytes(draw("trust/generated IK"))
            .public()
            .unwrap()
            .0,
    );
    let pins = (0..count)
        .map(|index| TrustPin {
            account: crate::encoding::AccountId(uuid::Uuid::from_u128(
                0x019a_0000_0000_7000_8000_0000_0000_0000 + index as u128,
            )),
            ik,
            av: v(1),
            how: PinHow::Compared,
            alert: false,
            replaced: Vec::new(),
        })
        .collect();
    TrustPlaintext {
        pins,
        versions: Vec::new(),
    }
}

fn generated_json(count: usize) -> JsonValue {
    let ik = crate::keys::Ed25519Seed::from_bytes(draw("trust/generated IK"))
        .public()
        .unwrap();
    obj(vec![
        ("count", n(count as u64)),
        ("first_account", s("019A0000-0000-7000-8000-000000000000")),
        ("ik", s(&crate::b64::encode(&ik.0))),
        ("av", n(1)),
        ("how", s("compared")),
    ])
}

pub(super) fn generated_trust(value: &JsonValue) -> TrustPlaintext {
    let mut input = super::verify::In::of(value);
    generated_trust_of(usize::try_from(input.u64("count")).unwrap())
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn trust() -> JsonValue {
    let ik = |name: &str| Ed25519Public(crate::keys::Ed25519Seed::from_bytes(draw(name)).public().unwrap().0);
    let a = account_id(ACCOUNT_A);
    let m = account_id(ACCOUNT_M);
    let plaintext = TrustPlaintext {
        pins: vec![
            TrustPin {
                account: a,
                ik: ik("trust/A IK"),
                av: v(3),
                how: PinHow::Compared,
                alert: false,
                replaced: Vec::new(),
            },
            TrustPin {
                account: m,
                ik: ik("trust/M IK"),
                av: v(2),
                how: PinHow::Replaced,
                alert: true,
                replaced: vec![ik("trust/M old IK")],
            },
        ],
        versions: vec![
            TrustVersion {
                owner: a.0,
                purpose: KeyPurpose::Personal,
                version: v(3),
                record: draw("trust/personal record"),
            },
            TrustVersion {
                owner: a.0,
                purpose: KeyPurpose::History,
                version: v(3),
                record: draw("trust/history record"),
            },
            TrustVersion {
                owner: team_id().0,
                purpose: KeyPurpose::Team,
                version: v(7),
                record: draw("trust/team record"),
            },
        ],
    };
    let text = plaintext.encode();
    let encode = vec![case(
        "an open alert, a replaced IK and a version per purpose",
        "trust_plaintext",
        vec![("text", s(&text))],
        vec![
            ("padded_hex", h(&padding::pad(text.as_bytes()).unwrap())),
            ("pins", n(2)),
            ("versions", n(3)),
        ],
    )];
    let row = "Non-canonical base64url, a wrong length, a version of 0 or at or above 2^31; a key object body with a duplicate, missing, unknown or wrongly typed member; a plaintext with a duplicate, missing or wrongly typed member";
    let mut parse = vec![case_row(
        "a member the reader does not know",
        "trust_plaintext",
        "A plaintext with a member the reader does not know",
        vec![(
            "text",
            s(&text.replacen("{\"v\":1,", "{\"v\":1,\"later\":[1,2],", 1).replacen(
                "\"alert\":true,",
                "\"alert\":true,\"note\":\"x\",",
                1,
            )),
        )],
        vec![("pins", n(2)), ("versions", n(3))],
    )];
    for (name, changed) in [
        (
            "a duplicate member",
            text.replacen("\"alert\":true,", "\"alert\":true,\"alert\":false,", 1),
        ),
        ("a missing member", text.replacen("\"alert\":true,", "", 1)),
        ("a wrongly typed member", text.replacen("\"av\":3", "\"av\":\"3\"", 1)),
        ("an unknown v", text.replacen("\"v\":1", "\"v\":2", 1)),
        ("an av of 0", text.replacen("\"av\":3", "\"av\":0", 1)),
        ("a lower-case UUID", text.replace(ACCOUNT_A, &ACCOUNT_A.to_lowercase())),
        ("an unknown pin how", text.replacen("\"compared\"", "\"trusted\"", 1)),
        (
            "an IK of 31 bytes",
            text.replacen(
                &crate::b64::encode(&ik("trust/A IK").0),
                &crate::b64::encode(&ik("trust/A IK").0[..31]),
                1,
            ),
        ),
    ] {
        parse.push(negative(
            name,
            "trust_plaintext",
            row,
            vec![("text", s(&changed))],
            "keys.encoding",
            None,
        ));
    }
    let droppable = |account: &str| TrustPin {
        account: account_id(account),
        ik: ik(&format!("trust/{account}")),
        av: v(1),
        how: PinHow::FirstUse,
        alert: false,
        replaced: Vec::new(),
    };
    let crowded = TrustPlaintext {
        pins: vec![
            droppable("019A6B40-0000-7000-8000-000000000001"),
            TrustPin {
                replaced: vec![ik("trust/kept old IK")],
                ..droppable("019A6B40-0000-7000-8000-000000000002")
            },
            droppable("019A6B40-0000-7000-8000-000000000003"),
            TrustPin {
                alert: true,
                ..droppable("019A6B40-0000-7000-8000-000000000004")
            },
        ],
        versions: Vec::new(),
    };
    let encoded = crowded.encode();
    let av = v(2);
    let record_len = |trust: &TrustPlaintext| trust_wrap_record_len(trust.encode().len(), av).unwrap();
    let full = record_len(&crowded);
    let without_third = TrustPlaintext {
        pins: vec![
            crowded.pins[0].clone(),
            crowded.pins[1].clone(),
            crowded.pins[3].clone(),
        ],
        versions: Vec::new(),
    };
    let floor = TrustPlaintext {
        pins: vec![crowded.pins[1].clone(), crowded.pins[3].clone()],
        versions: Vec::new(),
    };
    let fit_case = |name: &str, limit: usize, expected: Option<&TrustPlaintext>| {
        let mut output = vec![("record_len", n(full as u64)), ("fits", b(expected.is_some()))];
        if let Some(expected) = expected {
            output.push(("text", s(&expected.encode())));
        }
        (name.to_owned(), limit, output)
    };
    let fitted = crowded.fit_record(record_len(&without_third), av).unwrap().unwrap();
    let mut fit = Vec::new();
    for (name, limit, output) in [
        fit_case("the whole plaintext fits", full, Some(&crowded)),
        fit_case(
            "first-use pins with no alert and no replaced IK are left out first, from the end",
            record_len(&without_third),
            Some(&fitted),
        ),
        fit_case(
            "only the alert and the replaced IK are left",
            record_len(&floor),
            Some(&floor),
        ),
    ] {
        fit.push(case(
            &name,
            "trust_fit",
            vec![
                ("text", s(&encoded)),
                ("record_limit", n(limit as u64)),
                ("wrapper_av", n(2)),
            ],
            output,
        ));
    }
    fit.push(case_row(
        "alerts and replaced IKs alone pass the limit: nothing is dropped and the approval fails, as the server's too_large would",
        "trust_fit",
        "A trust record whose alerts, comparisons and replaced IKs alone pass the record limit; a first-use pin with a replaced IK, kept",
        vec![("text", s(&encoded)), ("record_limit", n((record_len(&floor) - 1) as u64)), ("wrapper_av", n(2))],
        vec![("record_len", n(full as u64)), ("fits", b(false))],
    ));
    // At the record limit itself: compared pins, which are never left out, up to 1 MiB.
    let fits =
        |count: usize| trust_wrap_record_len(generated_trust_of(count).encode().len(), av).unwrap() <= RECORD_LIMIT;
    let (mut low, mut high) = (1_usize, 1_usize << 15);
    while low + 1 < high {
        let middle = usize::midpoint(low, high);
        if fits(middle) { low = middle } else { high = middle }
    }
    let at_limit = low;
    for (name, count, fits) in [
        ("the most compared pins that fit 1 MiB", at_limit, true),
        ("one compared pin more", at_limit + 1, false),
    ] {
        let trust = generated_trust_of(count);
        let len = trust_wrap_record_len(trust.encode().len(), av).unwrap();
        let mut output = vec![("record_len", n(len as u64)), ("fits", b(fits))];
        if fits {
            output.push(("pins", n(count as u64)));
        }
        fit.push(case_row(
            name,
            "trust_fit",
            "A rotation or a trust record at the record limit",
            vec![
                ("generated", generated_json(count)),
                ("record_limit", n(RECORD_LIMIT as u64)),
                ("wrapper_av", n(2)),
            ],
            output,
        ));
    }
    file(
        "trust",
        "The trust plaintext, its reading and what is left out for size (ADR 0056, Pins)",
        vec![
            ("encode", arr(encode)),
            ("parse", arr(parse)),
            ("fit", arr(fit)),
            ("team", s(TEAM_T)),
        ],
    )
}
