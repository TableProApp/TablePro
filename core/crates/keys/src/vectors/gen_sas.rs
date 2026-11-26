use super::fixtures::{ACCOUNT_A, ORIGIN, account_id, device, draw, draw_uuid, origin};
use super::out::{arr, b, case, file, h, n, negative, obj, s};
use crate::encoding::{Frame, KeyDeviceId, Label, RequestId};
use crate::json::JsonValue;
use crate::keys::{DeviceKeys, Ed25519Seed};
use crate::sas::{SasDevice, Transcript};
use crate::words::{word_indexes, words};

fn sas_device(keys: &DeviceKeys) -> SasDevice {
    SasDevice {
        key_device: keys.key_device,
        dek: keys.dek.public().unwrap(),
        dsk: keys.dsk.public().unwrap(),
    }
}

pub(super) fn device_json(side: &SasDevice) -> JsonValue {
    obj(vec![
        ("key_device", s(&side.key_device.to_wire())),
        ("dek_hex", h(&side.dek.0)),
        ("dsk_hex", h(&side.dsk.0)),
    ])
}

struct View {
    transcript: Transcript,
    n: SasDevice,
    r_n: [u8; 32],
    a: SasDevice,
    r_a: [u8; 32],
}

fn view_input(view: &View) -> Vec<(&'static str, JsonValue)> {
    vec![
        ("origin", s(view.transcript.origin.as_str())),
        ("account", s(&view.transcript.account.to_wire())),
        ("request", s(&view.transcript.request.to_wire())),
        ("ik_hex", h(&view.transcript.ik.0)),
        ("n", device_json(&view.n)),
        ("r_n_hex", h(&view.r_n)),
        ("a", device_json(&view.a)),
        ("r_a_hex", h(&view.r_a)),
    ]
}

#[expect(clippy::too_many_lines, reason = "one case per vector the ADR lists")]
pub(super) fn sas() -> JsonValue {
    let ik = Ed25519Seed::from_bytes(draw("sas/IK")).public().unwrap();
    let base = View {
        transcript: Transcript {
            origin: origin(),
            account: account_id(ACCOUNT_A),
            request: RequestId(draw_uuid("sas/request")),
            ik,
        },
        n: sas_device(&device("sas/new device")),
        r_n: draw("sas/r_N"),
        a: sas_device(&device("sas/approver")),
        r_a: draw("sas/r_A"),
    };
    let commit = base.transcript.commitment(&base.n, &base.r_n).unwrap();
    let digest = base.transcript.digest(&base.n, &base.r_n, &base.a, &base.r_a).unwrap();
    let mut commit_input = Frame::new(Label::SasCommit);
    commit_input
        .origin(&base.transcript.origin)
        .id(base.transcript.account.0)
        .id(base.transcript.request.0)
        .id(base.n.key_device.0)
        .lp(&ik.0)
        .lp(&base.n.dek.0)
        .lp(&base.n.dsk.0)
        .lp(&base.r_n);
    let mut digest_input = Frame::new(Label::Sas);
    digest_input
        .origin(&base.transcript.origin)
        .id(base.transcript.account.0)
        .id(base.transcript.request.0)
        .id(base.n.key_device.0)
        .lp(&ik.0)
        .lp(&base.n.dek.0)
        .lp(&base.n.dsk.0)
        .lp(&base.r_n)
        .id(base.a.key_device.0)
        .lp(&base.a.dek.0)
        .lp(&base.a.dsk.0)
        .lp(&base.r_a);
    let words_out = words(&digest, 5);
    let known = vec![case(
        "the commitment and the words; N computes them from its view and A from its own, which match",
        "sas",
        view_input(&base),
        vec![
            ("commit_input_hex", h(&commit_input.finish().unwrap())),
            ("commit_hex", h(&commit)),
            ("digest_input_hex", h(&digest_input.finish().unwrap())),
            ("digest_hex", h(&digest)),
            (
                "word_indexes",
                arr(word_indexes(&digest, 5)
                    .into_iter()
                    .map(|index| n(u64::from(index)))
                    .collect()),
            ),
            ("words", arr(words_out.iter().map(|word| s(word)).collect())),
        ],
    )];

    let commit_row = "An `r_N` that does not open `c`; a commitment over other keys";
    let other = sas_device(&device("sas/substituted"));
    let commitments = vec![
        negative(
            "an r_N that does not open c",
            "check_commitment",
            commit_row,
            {
                let mut input = view_input(&base);
                input.push(("commit_hex", h(&commit)));
                input.retain(|(name, _)| *name != "r_n_hex");
                input.push(("r_n_hex", h(&draw::<32>("sas/other r_N"))));
                input
            },
            "keys.commitment",
            None,
        ),
        negative(
            "a commitment over other keys",
            "check_commitment",
            commit_row,
            {
                let mut input = view_input(&View {
                    n: SasDevice {
                        dek: other.dek,
                        ..base.n
                    },
                    ..clone_view(&base)
                });
                input.push(("commit_hex", h(&commit)));
                input
            },
            "keys.commitment",
            None,
        ),
    ];

    let differ_row = "Words that differ, with one field changed on one side, N's key device id included";
    let mut differ = Vec::new();
    let changes: Vec<(&str, View)> = vec![
        (
            "N's key device id",
            View {
                n: SasDevice {
                    key_device: KeyDeviceId(draw_uuid("sas/other N id")),
                    ..base.n
                },
                ..clone_view(&base)
            },
        ),
        (
            "N's DEK",
            View {
                n: SasDevice {
                    dek: other.dek,
                    ..base.n
                },
                ..clone_view(&base)
            },
        ),
        (
            "N's DSK",
            View {
                n: SasDevice {
                    dsk: other.dsk,
                    ..base.n
                },
                ..clone_view(&base)
            },
        ),
        (
            "r_N",
            View {
                r_n: draw("sas/other r_N"),
                ..clone_view(&base)
            },
        ),
        (
            "the IK",
            View {
                transcript: Transcript {
                    ik: Ed25519Seed::from_bytes(draw("sas/other IK")).public().unwrap(),
                    ..base.transcript.clone()
                },
                ..clone_view(&base)
            },
        ),
        (
            "A's key device id",
            View {
                a: SasDevice {
                    key_device: KeyDeviceId(draw_uuid("sas/other A id")),
                    ..base.a
                },
                ..clone_view(&base)
            },
        ),
        (
            "A's DEK",
            View {
                a: SasDevice {
                    dek: other.dek,
                    ..base.a
                },
                ..clone_view(&base)
            },
        ),
        (
            "A's DSK",
            View {
                a: SasDevice {
                    dsk: other.dsk,
                    ..base.a
                },
                ..clone_view(&base)
            },
        ),
        (
            "r_A",
            View {
                r_a: draw("sas/other r_A"),
                ..clone_view(&base)
            },
        ),
        (
            "the request",
            View {
                transcript: Transcript {
                    request: RequestId(draw_uuid("sas/other request")),
                    ..base.transcript.clone()
                },
                ..clone_view(&base)
            },
        ),
        (
            "the account",
            View {
                transcript: Transcript {
                    account: account_id(super::fixtures::ACCOUNT_M),
                    ..base.transcript.clone()
                },
                ..clone_view(&base)
            },
        ),
        (
            "the origin",
            View {
                transcript: Transcript {
                    origin: crate::encoding::Origin::parse("https://other.example.com").unwrap(),
                    ..base.transcript.clone()
                },
                ..clone_view(&base)
            },
        ),
    ];
    for (field, changed) in changes {
        let other_words = changed
            .transcript
            .words(&changed.n, &changed.r_n, &changed.a, &changed.r_a)
            .unwrap();
        let mut input = vec![
            ("view", obj(view_input(&base))),
            ("other_view", obj(view_input(&changed))),
        ];
        input.push(("other_words", arr(other_words.iter().map(|word| s(word)).collect())));
        differ.push(negative(
            &format!("{field} changed on one side"),
            "sas_words_differ",
            differ_row,
            input,
            "keys.sas_mismatch",
            None,
        ));
    }

    let session_row = "A `reveal` before the `nonce`, any step after a `cancel`, an approval or `expires_at`, or an approval change set after `expires_at`";
    let session = |name: &str, role: &str, steps: &[&str]| {
        negative(
            name,
            "sas_session",
            session_row,
            vec![
                ("view", obj(view_input(&base))),
                ("role", s(role)),
                ("steps", arr(steps.iter().map(|step| s(step)).collect())),
            ],
            "keys.session",
            Some("request_closed"),
        )
    };
    let sessions = vec![
        session("N reveals before the nonce", "new_device", &["reveal"]),
        session(
            "A reads a reveal after a cancel",
            "approver",
            &["receive_cancel", "receive_reveal"],
        ),
        session(
            "N reads a nonce after its request expired",
            "new_device",
            &["expire", "receive_nonce"],
        ),
        session(
            "A compares a second time",
            "approver",
            &["receive_reveal", "words", "words"],
        ),
        session(
            "A reads a reveal after its approval",
            "approver",
            &["receive_reveal", "words", "confirm", "receive_reveal"],
        ),
        negative(
            "the person says the words differ: the session ends with a mismatch cancel",
            "sas_session",
            "Words that differ, with one field changed on one side, N's key device id included",
            vec![
                ("view", obj(view_input(&base))),
                ("role", s("approver")),
                (
                    "steps",
                    arr(["receive_reveal", "words", "words_differ"]
                        .iter()
                        .map(|step| s(step))
                        .collect()),
                ),
                (
                    "cancel_record",
                    obj(vec![
                        ("kind", s("key.sas")),
                        ("id", s(&format!("{}/cancel", base.transcript.request.to_wire()))),
                        ("fields", super::out::fields(r#"{"suite":"tp1","reason":"mismatch"}"#)),
                    ]),
                ),
            ],
            "keys.sas_mismatch",
            None,
        ),
        case(
            "the whole session in order, on N's side",
            "sas_session",
            vec![
                ("view", obj(view_input(&base))),
                ("role", s("new_device")),
                (
                    "steps",
                    arr(["receive_nonce", "reveal", "words", "confirm"]
                        .iter()
                        .map(|step| s(step))
                        .collect()),
                ),
            ],
            vec![
                ("ok", b(true)),
                ("words", arr(words_out.iter().map(|word| s(word)).collect())),
            ],
        ),
    ];

    file(
        "sas",
        "Device approval's commitment, its five words both ways, and the session's order (ADR 0056, Approving a device)",
        vec![
            ("origin", s(ORIGIN)),
            ("known", arr(known)),
            ("commitment", arr(commitments)),
            ("words_differ", arr(differ)),
            ("session", arr(sessions)),
        ],
    )
}

fn clone_view(view: &View) -> View {
    View {
        transcript: view.transcript.clone(),
        n: view.n,
        r_n: view.r_n,
        a: view.a,
        r_a: view.r_a,
    }
}
