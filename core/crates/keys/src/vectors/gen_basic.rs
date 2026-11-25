use secrecy::ExposeSecret;
use zeroize::Zeroizing;

use super::fixtures::{ACCOUNT_A, ORIGIN, account_id, draw, origin, v};
use super::out::{arr, case, file, h, n, negative, obj, s};
use crate::b64;
use crate::base32;
use crate::dpop::{self, DpopRequest};
use crate::encoding::{Frame, KeyPurpose, Label, Origin, Scope, TeamId, WrapPurpose, lp, uuid_from_wire};
use crate::fingerprint::{fingerprint, fingerprint_words, qr_text};
use crate::json::JsonValue;
use crate::keys::Ed25519Seed;
use crate::padding::padded_len;
use crate::recovery::{RecoveryKey, blob_aad};
use crate::state_mac::{StateSnapshot, state_mac, state_mac_input};
use crate::words::{EFF_LARGE_SHA256, word_indexes, words};

const LABELS: [Label; 22] = [
    Label::RecoveryChecksum,
    Label::Identity,
    Label::RecoveryWrap,
    Label::Recovery,
    Label::Account,
    Label::Replace,
    Label::Cancel,
    Label::Device,
    Label::KeyId,
    Label::Version,
    Label::Wrap,
    Label::WrapSig,
    Label::RingKey,
    Label::Ring,
    Label::EnvelopeKey,
    Label::Envelope,
    Label::HistoryKey,
    Label::History,
    Label::SasCommit,
    Label::Sas,
    Label::Fingerprint,
    Label::State,
];

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn encoding() -> JsonValue {
    let mut lps = vec![
        case(
            "LP of an empty field",
            "lp",
            vec![("bytes_hex", h(b""))],
            vec![("lp_hex", h(&lp(b"").unwrap()))],
        ),
        case(
            "LP of a field with zero bytes inside",
            "lp",
            vec![("bytes_hex", h(&[0, 1, 0, 0]))],
            vec![("lp_hex", h(&lp(&[0, 1, 0, 0]).unwrap()))],
        ),
    ];
    for count in [65_535_usize, 65_536] {
        let bytes = vec![0xab_u8; count];
        let framed = lp(&bytes).unwrap();
        lps.push(case(
            &format!("LP at {count} bytes"),
            "lp",
            vec![("repeat_byte_hex", h(&[0xab])), ("repeat_count", n(count as u64))],
            vec![
                ("lp_prefix_hex", h(&framed[..4])),
                ("lp_sha256_hex", h(&crate::crypto::sha256(&framed))),
            ],
        ));
    }

    let ids = [ACCOUNT_A, "DB09A1EA-A519-42FF-94F3-CEEE6232F1C2"].map(|text| {
        let uuid = uuid_from_wire(text).unwrap();
        case(
            &format!("UUID {text} as 16 bytes"),
            "uuid",
            vec![("uuid", s(text))],
            vec![
                ("bytes_hex", h(uuid.as_bytes())),
                ("lp_hex", h(&lp(uuid.as_bytes()).unwrap())),
            ],
        )
    });
    let record_ids = [
        "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/history/2",
        "connection/6F1C2A9E-0B4D-4C8E-9A51-3D7E2B1F0C44/password",
    ]
    .map(|id| {
        case(
            &format!("record id {id} as UTF-8 text"),
            "record_id_text",
            vec![("record_id", s(id))],
            vec![("lp_hex", h(&lp(id.as_bytes()).unwrap()))],
        )
    });

    let account = account_id(ACCOUNT_A);
    let scopes = [
        Scope::Personal(account),
        Scope::History(account),
        Scope::Team(TeamId(uuid_from_wire(super::fixtures::TEAM_T).unwrap())),
    ]
    .map(|scope| {
        case(
            &format!("{} scope", scope.type_name()),
            "scope",
            vec![
                ("type", s(scope.type_name())),
                ("owner", s(&crate::encoding::uuid_to_wire(scope.owner()))),
            ],
            vec![("bytes_hex", h(&scope.bytes()))],
        )
    });
    let purposes = [
        WrapPurpose::Account,
        WrapPurpose::Trust,
        WrapPurpose::Key(KeyPurpose::Personal),
        WrapPurpose::Key(KeyPurpose::History),
        WrapPurpose::Key(KeyPurpose::Team),
    ]
    .map(|purpose| {
        case(
            &format!("purpose {}", purpose.name()),
            "purpose",
            vec![("purpose", s(purpose.name()))],
            vec![("lp_hex", h(&lp(purpose.name().as_bytes()).unwrap()))],
        )
    });
    let labels = LABELS.map(|label| {
        case(
            label.as_str(),
            "label",
            vec![("label", s(label.as_str()))],
            vec![("prefix_hex", h(&Frame::new(label).finish().unwrap()))],
        )
    });
    let origins = [
        "https://sync.example.com:443/v2/sync",
        "https://Sync.Example.com",
        "https://sync.example.com:8443/",
        "http://localhost:8080",
    ]
    .map(|url| {
        let origin = Origin::of_url(url).unwrap();
        case(
            &format!("origin of {url}"),
            "origin",
            vec![("url", s(url))],
            vec![
                ("origin", s(origin.as_str())),
                ("lp_hex", h(&lp(origin.as_str().as_bytes()).unwrap())),
            ],
        )
    });

    let row_encoding = "Non-canonical base64url, a wrong length, a version of 0 or at or above 2^31; a key object body with a duplicate, missing, unknown or wrongly typed member; a plaintext with a duplicate, missing or wrongly typed member";
    let base64 = vec![
        case(
            "base64url of 32 bytes",
            "base64url",
            vec![("text", s(&b64::encode(&[1; 32]))), ("len", n(32))],
            vec![("bytes_hex", h(&[1; 32]))],
        ),
        negative(
            "non-zero pad bits",
            "base64url",
            row_encoding,
            vec![
                ("text", s("AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQF")),
                ("len", n(32)),
            ],
            "keys.encoding",
            Some("bad_statement"),
        ),
        negative(
            "padding",
            "base64url",
            row_encoding,
            vec![("text", s("AQ==")), ("len", n(1))],
            "keys.encoding",
            Some("bad_statement"),
        ),
        negative(
            "the standard alphabet",
            "base64url",
            row_encoding,
            vec![("text", s("+/8")), ("len", n(2))],
            "keys.encoding",
            Some("bad_statement"),
        ),
        negative(
            "a wrong length",
            "base64url",
            row_encoding,
            vec![("text", s(&b64::encode(&[1; 31]))), ("len", n(32))],
            "keys.encoding",
            Some("bad_statement"),
        ),
    ];
    let base32_cases = vec![
        case(
            "Base32 of 0xff, final bits zero",
            "base32",
            vec![("bytes_hex", h(&[0xff]))],
            vec![("text", s(&base32::encode(&[0xff])))],
        ),
        case(
            "Base32 of 5 bytes",
            "base32",
            vec![("bytes_hex", h(&[0x00, 0x44, 0x32, 0x14, 0xc7]))],
            vec![("text", s(&base32::encode(&[0x00, 0x44, 0x32, 0x14, 0xc7])))],
        ),
    ];
    let versions = vec![
        negative(
            "version 0",
            "version",
            row_encoding,
            vec![("value", n(0))],
            "keys.encoding",
            Some("bad_statement"),
        ),
        negative(
            "version 2^31",
            "version",
            row_encoding,
            vec![("value", n(1 << 31))],
            "keys.encoding",
            Some("bad_statement"),
        ),
        case(
            "version 2^31-1",
            "version",
            vec![("value", n((1 << 31) - 1))],
            vec![("ok", super::out::b(true))],
        ),
    ];
    let padding_steps: Vec<JsonValue> = [
        0_usize, 63, 64, 127, 128, 255, 256, 511, 512, 1023, 1024, 2047, 2048, 4095, 4096, 8191, 8192,
    ]
    .iter()
    .map(|size| {
        case(
            &format!("P({size})"),
            "padded_len",
            vec![("n", n(*size as u64))],
            vec![("padded_len", n(padded_len(*size).unwrap() as u64))],
        )
    })
    .collect();
    let row_padding = "Padding with no 0x80, a non-zero byte after it, or a length off the scale";
    let mut no_marker = vec![0_u8; 64];
    no_marker[0] = 0x41;
    let mut after = vec![0_u8; 64];
    after[0] = 0x41;
    after[1] = 0x80;
    after[40] = 0x01;
    let mut off_scale = vec![0_u8; 96];
    off_scale[1] = 0x80;
    let unpad = vec![
        negative(
            "no 0x80",
            "unpad",
            row_padding,
            vec![("padded_hex", h(&no_marker))],
            "keys.encoding",
            None,
        ),
        negative(
            "a non-zero byte after 0x80",
            "unpad",
            row_padding,
            vec![("padded_hex", h(&after))],
            "keys.encoding",
            None,
        ),
        negative(
            "a length off the scale",
            "unpad",
            row_padding,
            vec![("padded_hex", h(&off_scale))],
            "keys.encoding",
            None,
        ),
    ];

    file(
        "encoding",
        "LP framing, ids, scopes, purposes, labels, origins, base64url, Base32, versions and padding (ADR 0056, Suite and encoding)",
        vec![
            ("lp", arr(lps)),
            ("uuids", arr(ids.to_vec())),
            ("record_ids", arr(record_ids.to_vec())),
            ("scopes", arr(scopes.to_vec())),
            ("purposes", arr(purposes.to_vec())),
            ("labels", arr(labels.to_vec())),
            ("origins", arr(origins.to_vec())),
            ("base64url", arr(base64)),
            ("base32", arr(base32_cases)),
            ("versions", arr(versions)),
            ("padding", arr(padding_steps)),
            ("unpad", arr(unpad)),
        ],
    )
}

fn recovery_text_case(name: &str, r: &RecoveryKey) -> JsonValue {
    let mut frame = Frame::new(Label::RecoveryChecksum);
    frame.lp(r.expose());
    let input = frame.finish().unwrap();
    let checksum = crate::crypto::sha256(&input);
    let mut b = r.expose().to_vec();
    b.extend_from_slice(&checksum[..3]);
    case(
        name,
        "recovery_text",
        vec![("r_hex", h(r.expose()))],
        vec![
            ("checksum_input_hex", h(&input)),
            ("checksum_hex", h(&checksum[..3])),
            ("b_hex", h(&b)),
            ("text", s(r.to_text().unwrap().expose_secret())),
        ],
    )
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn recovery() -> JsonValue {
    let r = RecoveryKey::from_bytes(draw("recovery/R"));
    let mut zero_led = draw::<32>("recovery/zero-led R");
    zero_led[..3].copy_from_slice(&[0, 0, 0]);
    let zero_led = RecoveryKey::from_bytes(zero_led);
    let texts = vec![
        recovery_text_case("a recovery key", &r),
        recovery_text_case("a key that starts with zero bytes", &zero_led),
    ];

    let zero_text = zero_led.to_text().unwrap().expose_secret().to_owned();
    let mut parses = Vec::new();
    let forgiving = [
        ("lower case", zero_text.to_lowercase()),
        ("O read as 0", zero_text.replacen('0', "O", 3)),
        (
            "hyphens and spaces dropped",
            format!(" {} ", zero_text.replace('-', " - ")),
        ),
    ];
    for (name, text) in forgiving {
        parses.push(case(
            name,
            "recovery_parse",
            vec![("text", s(&text))],
            vec![("r_hex", h(zero_led.expose()))],
        ));
    }
    // I and L read as 1: a key whose text holds a 1.
    let mut counter = 0;
    let (one_key, one_text) = loop {
        let candidate = RecoveryKey::from_bytes(draw(&format!("recovery/with a one/{counter}")));
        let text = candidate.to_text().unwrap().expose_secret().to_owned();
        if text.matches('1').count() >= 2 {
            break (candidate, text);
        }
        counter += 1;
    };
    parses.push(case(
        "I and L read as 1",
        "recovery_parse",
        vec![("text", s(&one_text.replacen('1', "I", 1).replacen('1', "l", 1)))],
        vec![("r_hex", h(one_key.expose()))],
    ));
    let row = "Recovery key text with a bad checksum or length";
    let good = r.to_text().unwrap().expose_secret().to_owned();
    let mut flipped: Vec<char> = good.chars().collect();
    let last = flipped.len() - 1;
    flipped[last] = if flipped[last] == '2' { '3' } else { '2' };
    let flipped: String = flipped.into_iter().collect();
    parses.push(negative(
        "a bad checksum",
        "recovery_parse",
        row,
        vec![("text", s(&flipped))],
        "keys.recovery_key",
        None,
    ));
    parses.push(negative(
        "a symbol short",
        "recovery_parse",
        row,
        vec![("text", s(&good[..good.len() - 1]))],
        "keys.recovery_key",
        None,
    ));
    parses.push(negative(
        "a symbol over",
        "recovery_parse",
        row,
        vec![("text", s(&format!("{good}0")))],
        "keys.recovery_key",
        None,
    ));
    parses.push(negative(
        "U is not a symbol",
        "recovery_parse",
        row,
        vec![("text", s(&good.replacen(&good[..1], "U", 1)))],
        "keys.recovery_key",
        None,
    ));

    let account = account_id(ACCOUNT_A);
    let mut info = Frame::new(Label::Identity);
    info.origin(&origin()).id(account.0);
    let seed = r.identity_seed(&origin(), account).unwrap();
    let mut key_info = Frame::new(Label::RecoveryWrap);
    key_info.origin(&origin()).id(account.0);
    let identity = vec![case(
        "IK seed and K_rec",
        "identity_seed",
        vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("r_hex", h(r.expose())),
        ],
        vec![
            ("info_hex", h(&info.finish().unwrap())),
            ("seed_hex", h(seed.expose())),
            ("ik_hex", h(&seed.public().unwrap().0)),
            ("k_rec_info_hex", h(&key_info.finish().unwrap())),
            ("k_rec_hex", h(&*r.blob_key(&origin(), account).unwrap())),
        ],
    )];

    let keys = crate::keys::AccountKeys {
        ask: Ed25519Seed::from_bytes(draw("recovery/ask")),
        aek: crate::keys::X25519Secret::from_bytes(draw("recovery/aek")),
    };
    let nonce: [u8; 12] = draw("recovery/blob nonce");
    let av = v(3);
    let blob = r.seal_blob_with_nonce(&origin(), account, av, &keys, nonce).unwrap();
    let blob_fields = crate::body::body_json(&crate::body::KeyBody::Recovery(blob.clone()));
    let blob_input = || {
        vec![
            ("origin", s(ORIGIN)),
            ("account", s(ACCOUNT_A)),
            ("av", n(3)),
            ("r_hex", h(r.expose())),
            ("ask_seed_hex", h(keys.ask.expose())),
            ("aek_secret_hex", h(keys.aek.expose())),
            ("nonce_hex", h(&nonce)),
        ]
    };
    let mut blobs = vec![case(
        "the recovery blob",
        "recovery_blob",
        blob_input(),
        vec![
            ("aad_hex", h(&blob_aad(&origin(), account, av).unwrap())),
            ("plaintext_hex", h(keys.to_plaintext().as_slice())),
            ("ct_hex", h(&blob.ct)),
            (
                "record",
                record("key.recovery", &format!("{ACCOUNT_A}/3"), &blob_fields),
            ),
        ],
    )];
    let row_open = "A blob for another origin, account or `av`";
    let open_input = |origin_text: &str, account_text: &str, av_value: u64| {
        vec![
            ("origin", s(origin_text)),
            ("account", s(account_text)),
            ("av", n(av_value)),
            ("r_hex", h(r.expose())),
            ("fields", super::out::fields(&blob_fields)),
        ]
    };
    blobs.push(negative(
        "another origin",
        "recovery_blob_open",
        row_open,
        open_input("https://other.example.com", ACCOUNT_A, 3),
        "keys.open",
        None,
    ));
    blobs.push(negative(
        "another account",
        "recovery_blob_open",
        row_open,
        open_input(ORIGIN, super::fixtures::ACCOUNT_M, 3),
        "keys.open",
        None,
    ));
    blobs.push(negative(
        "another av",
        "recovery_blob_open",
        row_open,
        open_input(ORIGIN, ACCOUNT_A, 4),
        "keys.open",
        None,
    ));
    let other_keys = crate::keys::AccountKeys {
        ask: Ed25519Seed::from_bytes(draw("recovery/other ask")),
        aek: crate::keys::X25519Secret::from_bytes(draw("recovery/other aek")),
    };
    let mut mismatch = open_input(ORIGIN, ACCOUNT_A, 3);
    mismatch.push(("certificate_ask_hex", h(&other_keys.ask.public().unwrap().0)));
    mismatch.push(("certificate_aek_hex", h(&keys.aek.public().unwrap().0)));
    blobs.push(negative(
        "blob keys that do not give the certificate's public keys",
        "recovery_blob_open",
        "Account keys in a wrap or blob that do not match their certificate",
        mismatch,
        "keys.mismatch",
        None,
    ));

    file(
        "recovery",
        "The recovery key: text, checksum and reading, the identity key's seed, K_rec and the blob (ADR 0056, The recovery key)",
        vec![
            ("text", arr(texts)),
            ("parse", arr(parses)),
            ("identity", arr(identity)),
            ("blob", arr(blobs)),
        ],
    )
}

pub(super) fn record(kind: &str, id: &str, fields: &str) -> JsonValue {
    obj(vec![
        ("kind", s(kind)),
        ("id", s(id)),
        ("fields", super::out::fields(fields)),
    ])
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn fingerprints() -> JsonValue {
    let account = account_id(ACCOUNT_A);
    let ik = Ed25519Seed::from_bytes(draw("fingerprint/ik")).public().unwrap();
    let f = fingerprint(&origin(), account, &ik).unwrap();
    let mut info = Frame::new(Label::Fingerprint);
    info.origin(&origin()).id(account.0);
    let main = case(
        "an account's fingerprint",
        "fingerprint",
        vec![("origin", s(ORIGIN)), ("account", s(ACCOUNT_A)), ("ik_hex", h(&ik.0))],
        vec![
            ("info_hex", h(&info.finish().unwrap())),
            ("f_hex", h(&f)),
            (
                "word_indexes",
                arr(word_indexes(&f, 6)
                    .into_iter()
                    .map(|index| n(u64::from(index)))
                    .collect()),
            ),
            ("words", arr(fingerprint_words(&f).into_iter().map(s).collect())),
            ("qr", s(&qr_text(&f))),
        ],
    );
    let mut top = [0_u8; 32];
    top[30] = 0x1e;
    top[31] = 0x5f;
    let crafted = [
        ("every index 0", [0_u8; 32]),
        ("index 7775 first", top),
        ("all ones", [0xff; 32]),
    ]
    .map(|(name, digest)| {
        case(
            name,
            "words",
            vec![("digest_hex", h(&digest)), ("count", n(6))],
            vec![
                (
                    "word_indexes",
                    arr(word_indexes(&digest, 6)
                        .into_iter()
                        .map(|index| n(u64::from(index)))
                        .collect()),
                ),
                ("words", arr(words(&digest, 6).into_iter().map(s).collect())),
            ],
        )
    });
    let row = "Errors table: keys.encoding, QR text that does not parse";
    let good = qr_text(&f);
    let qr = vec![
        case(
            "QR text, its last 4 bits zero",
            "parse_qr",
            vec![("text", s(&qr_text(&[0xff; 32])))],
            vec![("f_hex", h(&[0xff; 32]))],
        ),
        negative(
            "another prefix",
            "parse_qr",
            row,
            vec![("text", s(&good.replace("TPF1:", "TPF2:")))],
            "keys.encoding",
            None,
        ),
        negative(
            "non-zero final bits",
            "parse_qr",
            row,
            vec![("text", s(&format!("{}H", &qr_text(&[0xff; 32])[..56])))],
            "keys.encoding",
            None,
        ),
        negative(
            "lower case",
            "parse_qr",
            row,
            vec![("text", s(&format!("TPF1:{}", good[5..].to_lowercase())))],
            "keys.encoding",
            None,
        ),
        negative(
            "grouped",
            "parse_qr",
            row,
            vec![("text", s(&format!("TPF1:{}-{}", &good[5..30], &good[30..])))],
            "keys.encoding",
            None,
        ),
    ];
    file(
        "fingerprint",
        "Fingerprint words, the word digits and the QR text (ADR 0056, Pins and Encoding)",
        vec![
            (
                "word_list",
                obj(vec![
                    ("name", s("EFF large word list")),
                    ("sha256", s(EFF_LARGE_SHA256)),
                    ("count", n(7776)),
                ]),
            ),
            ("fingerprint", arr(vec![main])),
            ("words", arr(crafted.to_vec())),
            ("qr", arr(qr)),
        ],
    )
}

pub(super) fn state_macs() -> JsonValue {
    let account = account_id(ACCOUNT_A);
    let key = Zeroizing::new(draw::<32>("state/key"));
    let file_id: [u8; 16] = draw("state/file id");
    let key_digest: [u8; 32] = draw("state/key digest");
    let sync_digest: [u8; 32] = draw("state/sync digest");
    let cases = [0_u64, 1, 0x0102_0304_0506_0708].map(|counter| {
        let snapshot = StateSnapshot {
            file_id: &file_id,
            counter,
            key_digest: &key_digest,
            sync_digest: &sync_digest,
        };
        case(
            &format!("counter {counter}"),
            "state_mac",
            vec![
                ("origin", s(ORIGIN)),
                ("account", s(ACCOUNT_A)),
                ("key_hex", h(key.as_slice())),
                ("file_id_hex", h(&file_id)),
                ("counter", n(counter)),
                ("key_digest_hex", h(&key_digest)),
                ("sync_digest_hex", h(&sync_digest)),
            ],
            vec![
                ("input_hex", h(&state_mac_input(&origin(), account, snapshot).unwrap())),
                ("mac_hex", h(&state_mac(&key, &origin(), account, snapshot).unwrap())),
            ],
        )
    });
    file(
        "state_mac",
        "The state file's MAC over its binding and digests (ADR 0054, Integrity and freshness)",
        vec![("cases", arr(cases.to_vec()))],
    )
}

pub(super) fn dpop_proofs() -> JsonValue {
    let dsk = Ed25519Seed::from_bytes(draw("dpop/dsk"));
    let cases = [
        (
            "a push",
            "POST",
            "https://sync.example.com/v2/sync/scopes/personal/changes",
            None,
        ),
        (
            "a pull with a query, after the server's nonce",
            "GET",
            "https://sync.example.com/v2/sync/scopes/personal/changes?cursor=abc&limit=500",
            Some("server-nonce-1"),
        ),
        (
            "a Sign Out revoke on a non-default port",
            "DELETE",
            "https://sync.example.com:8443/v2/sync/key-device",
            None,
        ),
    ]
    .map(|(name, method, url, nonce)| {
        let jti: [u8; 16] = draw(&format!("dpop/{name}/jti"));
        let request = DpopRequest {
            method,
            url,
            access_token: "access-token-for-vectors",
            iat: 1_764_000_000,
            nonce,
        };
        let proof = dpop::proof_with_jti(&dsk, request, jti).unwrap();
        let parts: Vec<&str> = proof.split('.').collect();
        let mut input = vec![
            ("dsk_seed_hex", h(dsk.expose())),
            ("dsk_hex", h(&dsk.public().unwrap().0)),
            ("method", s(method)),
            ("url", s(url)),
            ("access_token", s("access-token-for-vectors")),
            ("iat", n(1_764_000_000)),
            ("jti_hex", h(&jti)),
        ];
        if let Some(nonce) = nonce {
            input.push(("nonce", s(nonce)));
        }
        case(
            name,
            "dpop",
            input,
            vec![
                ("header", s(&String::from_utf8(b64::decode(parts[0]).unwrap()).unwrap())),
                ("claims", s(&String::from_utf8(b64::decode(parts[1]).unwrap()).unwrap())),
                ("proof", s(&proof)),
            ],
        )
    });
    file(
        "dpop",
        "DPoP proofs under a device's DSK, alg Ed25519 with an OKP jwk (ADR 0051, Keys on the wire)",
        vec![("cases", arr(cases.to_vec()))],
    )
}
