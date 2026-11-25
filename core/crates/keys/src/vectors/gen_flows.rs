// ADR 0056's Vectors rows whose outcome a flow or the server decides: the key objects each row
// is about, built with real keys from one world, with the row's client and server columns. This
// crate checks every object in them (it parses, and its signature holds under the key the record
// names); the flows and the server check the outcomes.

use super::fixtures::{
    ACCOUNT_A, ACCOUNT_M, HpkeCache, ORIGIN, TEAM_T, account_id, draw, draw_uuid, origin, scope_key, v,
};
use super::out::{arr, b, h, n, null, obj, s};
use super::verify::In;
use crate::body::{
    AccountBody, DeviceBody, KeyBody, KeyObject, RequestBody, ResetBody, SasBody, VersionBody, WrapBody, body_json,
};
use crate::cert::{AccountCertificate, CertKind, DeviceCertificate, sign_cancel};
use crate::encoding::{AccountId, KeyPurpose, RequestId, ResetId, WrapPurpose, uuid_from_wire, uuid_to_wire};
use crate::json::{JsonValue, Members};
use crate::keys::{AccountKeys, DeviceKeys, Ed25519Public, Ed25519Seed, ScopeKey, X25519Public, X25519Secret};
use crate::record_id::{KeyRecordId, SasStep};
use crate::recovery::RecoveryKey;
use crate::scope_key::{KeyRef, Ring, Start, VersionRecord};
use crate::trust::{PinHow, TrustPin, TrustPlaintext, TrustVersion};
use crate::wrap::{Wrapper, device_target, scope_key_target};

struct Person {
    name: &'static str,
    id: AccountId,
    ik: Ed25519Seed,
    r: RecoveryKey,
    keys: Vec<AccountKeys>,
}

impl Person {
    fn new(name: &'static str, id: AccountId, avs: u32) -> Self {
        let r = RecoveryKey::from_bytes(draw(&format!("flows/{name}/R")));
        let ik = r.identity_seed(&origin(), id).expect("ik");
        let keys = (1..=avs)
            .map(|av| AccountKeys {
                ask: Ed25519Seed::from_bytes(draw(&format!("flows/{name}/av{av}/ask"))),
                aek: X25519Secret::from_bytes(draw(&format!("flows/{name}/av{av}/aek"))),
            })
            .collect();
        Self { name, id, ik, r, keys }
    }

    fn at(&self, av: u32) -> &AccountKeys {
        &self.keys[av as usize - 1]
    }
}

fn device(name: &str) -> DeviceKeys {
    super::fixtures::device(&format!("flows/{name}"))
}

struct World<'a> {
    cache: &'a HpkeCache,
    a: Person,
    m: Person,
    e: Person,
    o: Person,
    p: Person,
    // P's account as another device's genesis would make it: its own R, IK and keys.
    p_other: Person,
    team: uuid::Uuid,
}

fn team_key(version: u32) -> ScopeKey {
    scope_key(&format!("flows/TK{version}"))
}

fn personal_key(name: &str, version: u32) -> ScopeKey {
    scope_key(&format!("flows/{name}/PK{version}"))
}

fn scope_json(owner: uuid::Uuid, team: bool) -> JsonValue {
    obj(vec![
        ("type", s(if team { "team" } else { "personal" })),
        ("owner", s(&uuid_to_wire(owner))),
    ])
}

fn rec(
    label: &str,
    team: Option<uuid::Uuid>,
    owner: uuid::Uuid,
    id: &KeyRecordId,
    body: &KeyBody,
    verify: Vec<(&str, JsonValue)>,
) -> JsonValue {
    obj(vec![
        ("label", s(label)),
        ("scope", scope_json(team.unwrap_or(owner), team.is_some())),
        ("kind", s(id.kind().name())),
        ("id", s(&id.to_wire())),
        ("fields", super::out::fields(&body_json(body))),
        ("verify", obj(verify)),
    ])
}

impl World<'_> {
    fn person(&self, name: &str) -> &Person {
        match name {
            "A" => &self.a,
            "M" => &self.m,
            "E" => &self.e,
            "O" => &self.o,
            "P'" => &self.p_other,
            _ => &self.p,
        }
    }

    fn certificate(
        &self,
        who: &str,
        av: u32,
        kind: CertKind,
        ik: &Ed25519Seed,
        previous: Option<&Ed25519Seed>,
    ) -> AccountCertificate {
        let person = self.person(who);
        AccountCertificate::sign(
            &origin(),
            person.id,
            v(av),
            kind,
            ik,
            person.at(av).public().expect("public"),
            previous,
        )
        .expect("certificate")
    }

    fn account(&self, label: &str, who: &str, av: u32) -> JsonValue {
        let person = self.person(who);
        let certificate = self.certificate(who, av, CertKind::GenesisOrRotation, &person.ik, None);
        let id = KeyRecordId::Account {
            account: person.id,
            av: v(av),
        };
        rec(
            label,
            None,
            person.id.0,
            &id,
            &KeyBody::Account(AccountBody::of(&certificate)),
            vec![("ik_hex", h(&certificate.ik.0))],
        )
    }

    fn account_with(&self, label: &str, who: &str, av: u32, kind: CertKind, ik: &Ed25519Seed) -> JsonValue {
        let person = self.person(who);
        let certificate = self.certificate(who, av, kind, ik, None);
        let id = KeyRecordId::Account {
            account: person.id,
            av: v(av),
        };
        rec(
            label,
            None,
            person.id.0,
            &id,
            &KeyBody::Account(AccountBody::of(&certificate)),
            vec![("ik_hex", h(&certificate.ik.0))],
        )
    }

    fn member(&self, label: &str, who: &str, av: u32) -> JsonValue {
        let person = self.person(who);
        let certificate = self.certificate(who, av, CertKind::GenesisOrRotation, &person.ik, None);
        let id = KeyRecordId::Member {
            account: person.id,
            av: v(av),
        };
        rec(
            label,
            Some(self.team),
            person.id.0,
            &id,
            &KeyBody::Member(AccountBody::of(&certificate)),
            vec![("ik_hex", h(&certificate.ik.0))],
        )
    }

    fn device_cert(&self, label: &str, who: &str, av: u32, device: &DeviceKeys) -> JsonValue {
        let person = self.person(who);
        let certificate = DeviceCertificate::sign(
            &origin(),
            person.id,
            v(av),
            device.key_device,
            device.dek.public().expect("public"),
            device.dsk.public().expect("public"),
            &person.at(av).ask,
        )
        .expect("device");
        let id = KeyRecordId::Device {
            account: person.id,
            key_device: device.key_device,
            av: v(av),
        };
        rec(
            label,
            None,
            person.id.0,
            &id,
            &KeyBody::Device(DeviceBody::of(&certificate)),
            vec![("signer_hex", h(&person.at(av).ask.public().expect("public").0))],
        )
    }

    // A version record of the team key or of `who`'s personal key, signed by `signer` at `signer_av`.
    #[expect(clippy::too_many_arguments, reason = "an object names its key, signer and recipient")]
    fn version(
        &self,
        label: &str,
        key: KeyRef,
        start: Start,
        scope_key: &ScopeKey,
        signer: &str,
        signer_av: u32,
        signing: &Ed25519Seed,
    ) -> JsonValue {
        let person = self.person(signer);
        let record =
            VersionRecord::sign(&origin(), key, start, scope_key, person.id, v(signer_av), signing).expect("version");
        let team = (key.purpose == KeyPurpose::Team).then_some(self.team);
        rec(
            label,
            team,
            key.owner,
            &KeyRecordId::Version(key),
            &KeyBody::Version(VersionBody::of(&record)),
            vec![
                ("signer_hex", h(&signing.public().expect("public").0)),
                ("digest_hex", h(&record.digest(&origin()).expect("digest"))),
            ],
        )
    }

    fn team_version(&self, label: &str, version: u32, start: Start, signer: &str, signer_av: u32) -> JsonValue {
        let key = KeyRef {
            owner: self.team,
            purpose: KeyPurpose::Team,
            version: v(version),
        };
        self.version(
            label,
            key,
            start,
            &team_key(version),
            signer,
            signer_av,
            &self.person(signer).at(signer_av).ask,
        )
    }

    fn team_ring(&self, label: &str, version: u32) -> JsonValue {
        let key = KeyRef {
            owner: self.team,
            purpose: KeyPurpose::Team,
            version: v(version),
        };
        let ring = Ring::seal_with_nonce(
            &origin(),
            key,
            &team_key(version),
            &team_key(version - 1),
            draw(&format!("flows/ring {version}")),
        )
        .expect("ring");
        rec(
            label,
            Some(self.team),
            self.team,
            &KeyRecordId::Ring(key),
            &KeyBody::Ring(ring),
            vec![
                ("newer_key_hex", h(team_key(version).expose())),
                ("below_kid_hex", h(&team_key(version - 1).kid().expect("kid").0)),
            ],
        )
    }

    #[expect(clippy::too_many_arguments, reason = "a wrap names its key, recipient and wrapper")]
    fn scope_wrap(
        &self,
        label: &str,
        key: KeyRef,
        scope_key: &ScopeKey,
        to: &str,
        to_av: u32,
        from: &str,
        from_av: u32,
        signing: &Ed25519Seed,
        from_device: &DeviceKeys,
    ) -> JsonValue {
        let recipient = self.person(to);
        let wrapper = Wrapper {
            account: self.person(from).id,
            av: v(from_av),
            key_device: from_device.key_device,
        };
        let target = scope_key_target(key, recipient.id, v(to_av));
        let wrap = self
            .cache
            .wrap(target, &recipient.at(to_av).aek, scope_key.expose(), wrapper, signing);
        let team = (key.purpose == KeyPurpose::Team).then_some(self.team);
        rec(
            label,
            team,
            key.owner,
            &KeyRecordId::Wrap(target),
            &KeyBody::Wrap(WrapBody::of(&wrap)),
            vec![
                ("signer_hex", h(&signing.public().expect("public").0)),
                ("pk_r_hex", h(&recipient.at(to_av).aek.public().expect("public").0)),
                ("recipient_secret_hex", h(recipient.at(to_av).aek.expose())),
                ("kid_hex", h(&scope_key.kid().expect("kid").0)),
            ],
        )
    }

    #[expect(clippy::too_many_arguments, reason = "an object names its key, signer and recipient")]
    fn team_wrap(
        &self,
        label: &str,
        version: u32,
        to: &str,
        to_av: u32,
        from: &str,
        from_av: u32,
        from_device: &DeviceKeys,
    ) -> JsonValue {
        let key = KeyRef {
            owner: self.team,
            purpose: KeyPurpose::Team,
            version: v(version),
        };
        self.scope_wrap(
            label,
            key,
            &team_key(version),
            to,
            to_av,
            from,
            from_av,
            &self.person(from).at(from_av).ask,
            from_device,
        )
    }

    #[expect(clippy::too_many_arguments, reason = "an object names its key, signer and recipient")]
    fn device_wrap(
        &self,
        label: &str,
        who: &str,
        av: u32,
        purpose: WrapPurpose,
        to: &DeviceKeys,
        from: &DeviceKeys,
        signing: &Ed25519Seed,
        plaintext: &[u8],
    ) -> JsonValue {
        let person = self.person(who);
        let target = device_target(person.id, purpose, v(av), to.key_device);
        let wrapper = Wrapper {
            account: person.id,
            av: v(av),
            key_device: from.key_device,
        };
        let wrap = self.cache.wrap(target, &to.dek, plaintext, wrapper, signing);
        let mut verify = vec![
            ("signer_hex", h(&signing.public().expect("public").0)),
            ("pk_r_hex", h(&to.dek.public().expect("public").0)),
            ("recipient_secret_hex", h(to.dek.expose())),
        ];
        if purpose == WrapPurpose::Account {
            let keys = AccountKeys::from_plaintext(plaintext)
                .expect("account keys")
                .public()
                .expect("public");
            verify.push(("certificate_ask_hex", h(&keys.ask.0)));
            verify.push(("certificate_aek_hex", h(&keys.aek.0)));
        }
        rec(
            label,
            None,
            person.id.0,
            &KeyRecordId::Wrap(target),
            &KeyBody::Wrap(WrapBody::of(&wrap)),
            verify,
        )
    }

    fn approval(
        &self,
        label: &str,
        who: &str,
        av: u32,
        to: &DeviceKeys,
        from: &DeviceKeys,
        trust: &TrustPlaintext,
    ) -> Vec<JsonValue> {
        let person = self.person(who);
        let padded = crate::padding::pad(trust.encode().as_bytes()).expect("pad");
        vec![
            self.device_cert(&format!("{label}: the new device's certificate"), who, av, to),
            self.device_wrap(
                &format!("{label}: account wrap"),
                who,
                av,
                WrapPurpose::Account,
                to,
                from,
                &from.dsk,
                person.at(av).to_plaintext().as_slice(),
            ),
            self.device_wrap(
                &format!("{label}: trust wrap"),
                who,
                av,
                WrapPurpose::Trust,
                to,
                from,
                &from.dsk,
                &padded,
            ),
        ]
    }

    fn recovery(&self, label: &str, who: &str, av: u32) -> JsonValue {
        let person = self.person(who);
        let blob = person
            .r
            .seal_blob_with_nonce(
                &origin(),
                person.id,
                v(av),
                person.at(av),
                draw(&format!("flows/{label}/nonce")),
            )
            .expect("blob");
        rec(
            label,
            None,
            person.id.0,
            &KeyRecordId::Recovery {
                account: person.id,
                av: v(av),
            },
            &KeyBody::Recovery(blob),
            blob_verify(&person.r, person.at(av)),
        )
    }

    // The personal and history keys of one `av`: version records, rings unless they start over, and wraps to AEK.
    fn scope_keys_at(
        &self,
        label: &str,
        who: &str,
        av: u32,
        start: Start,
        wrapper_device: &DeviceKeys,
    ) -> Vec<JsonValue> {
        let person = self.person(who);
        let ask = &person.at(av).ask;
        let mut records = Vec::new();
        for (purpose, name) in [
            (KeyPurpose::Personal, person.name.to_owned()),
            (KeyPurpose::History, format!("{} history", person.name)),
        ] {
            let key = KeyRef {
                owner: person.id.0,
                purpose,
                version: v(av),
            };
            let scope_key = personal_key(&name, av);
            records.push(self.version(
                &format!("{label}: {} version {av}", purpose.name()),
                key,
                start,
                &scope_key,
                who,
                av,
                ask,
            ));
            if start == Start::Next {
                records.push(personal_ring(
                    key,
                    person.name,
                    &format!("{label}: {} ring {av}", purpose.name()),
                ));
            }
            records.push(self.scope_wrap(
                &format!("{label}: {} wrap {av}", purpose.name()),
                key,
                &scope_key,
                who,
                av,
                who,
                av,
                ask,
                wrapper_device,
            ));
        }
        records
    }

    // ADR 0056, Genesis: the certificate at av 1, the blob, the device certificate, PK and HK v1 with wraps.
    fn genesis(&self, label: &str, who: &str, device: &DeviceKeys) -> Vec<JsonValue> {
        let mut records = vec![
            self.account(&format!("{label}: certificate at av 1"), who, 1),
            self.recovery(&format!("{label}: recovery blob"), who, 1),
            self.device_cert(&format!("{label}: device certificate"), who, 1, device),
        ];
        records.extend(self.scope_keys_at(label, who, 1, Start::Over, device));
        records
    }

    // ADR 0056, Rotation: the certificate at av + 1 under IK, the blob, each kept device's certificate and
    // account wrap from the rotating device, and PK and HK at their next versions with rings and wraps.
    fn rotation(&self, label: &str, who: &str, av: u32, keep: &[&DeviceKeys], by: &DeviceKeys) -> Vec<JsonValue> {
        let person = self.person(who);
        let mut records = vec![
            self.account(&format!("{label}: certificate at av {av}"), who, av),
            self.recovery(&format!("{label}: recovery blob"), who, av),
        ];
        for (index, device) in keep.iter().enumerate() {
            records.push(self.device_cert(&format!("{label}: kept device {index}"), who, av, device));
            records.push(self.device_wrap(
                &format!("{label}: account wrap to kept device {index}"),
                who,
                av,
                WrapPurpose::Account,
                device,
                by,
                &by.dsk,
                person.at(av).to_plaintext().as_slice(),
            ));
        }
        records.extend(self.scope_keys_at(label, who, av, Start::Next, by));
        records
    }

    // ADR 0056, Reset, Activation: the proposal's certificate, device certificate and blob as it holds
    // them, and PK and HK at their next versions: with rings for kind 2, starting over for kind 3.
    fn activation(&self, proposal: &str, who: &str, av: u32, kind: CertKind, device: &DeviceKeys) -> Vec<JsonValue> {
        let person = self.person(who);
        let new_ik = self.reset_ik(proposal, who);
        let new_ik = &new_ik;
        let new_r = RecoveryKey::from_bytes(draw(&format!("flows/{proposal}/R'")));
        let blob = new_r
            .seal_blob_with_nonce(
                &origin(),
                person.id,
                v(av),
                person.at(av),
                draw(&format!("flows/{proposal}/blob nonce")),
            )
            .expect("blob");
        let start = if kind == CertKind::ResetEmpty {
            Start::Over
        } else {
            Start::Next
        };
        let mut records = vec![
            self.account_with(&format!("{proposal}: the proposed certificate"), who, av, kind, new_ik),
            rec(
                &format!("{proposal}: the proposed blob"),
                None,
                person.id.0,
                &KeyRecordId::Recovery {
                    account: person.id,
                    av: v(av),
                },
                &KeyBody::Recovery(blob),
                blob_verify(&new_r, person.at(av)),
            ),
            self.device_cert(&format!("{proposal}: the proposed device certificate"), who, av, device),
        ];
        records.extend(self.scope_keys_at(proposal, who, av, start, device));
        records
    }

    // A reset's IK comes from its own new recovery key, so each attempt has its own (ADR 0056, Reset).
    fn reset_ik(&self, proposal: &str, who: &str) -> Ed25519Seed {
        let person = self.person(who);
        RecoveryKey::from_bytes(draw(&format!("flows/{proposal}/R'")))
            .identity_seed(&origin(), person.id)
            .expect("ik")
    }

    // N's view: the account's IK, its own keys and r_N, which its reveal opens the commitment with.
    fn sas_view(
        &self,
        who: &str,
        request: RequestId,
        device: &DeviceKeys,
    ) -> (crate::sas::Transcript, crate::sas::SasDevice, [u8; 32]) {
        let person = self.person(who);
        let transcript = crate::sas::Transcript {
            origin: origin(),
            account: person.id,
            request,
            ik: person.ik.public().expect("public"),
        };
        let n = crate::sas::SasDevice {
            key_device: device.key_device,
            dek: device.dek.public().expect("public"),
            dsk: device.dsk.public().expect("public"),
        };
        (transcript, n, draw(&format!("flows/request {}/r_N", request.to_wire())))
    }

    fn request(&self, label: &str, who: &str, request: RequestId, device: &DeviceKeys) -> JsonValue {
        let person = self.person(who);
        let (transcript, n, r_n) = self.sas_view(who, request, device);
        let body = RequestBody {
            key_device: n.key_device,
            dek: n.dek,
            dsk: n.dsk,
            commit: transcript.commitment(&n, &r_n).expect("commit"),
        };
        rec(
            label,
            None,
            person.id.0,
            &KeyRecordId::Request { request },
            &KeyBody::Request(body),
            vec![("ik_hex", h(&transcript.ik.0)), ("r_n_hex", h(&r_n))],
        )
    }

    fn nonce(&self, label: &str, who: &str, request: RequestId, device: &DeviceKeys) -> JsonValue {
        let body = SasBody::Nonce {
            key_device: device.key_device,
            dek: device.dek.public().expect("public"),
            dsk: device.dsk.public().expect("public"),
            r: draw(&format!("flows/{label}/r")),
        };
        rec(
            label,
            None,
            self.person(who).id.0,
            &KeyRecordId::Sas {
                request,
                step: SasStep::Nonce,
            },
            &KeyBody::Sas(body),
            vec![],
        )
    }

    // N's reveal of the r_N its request committed to.
    fn reveal(&self, label: &str, who: &str, request: RequestId, device: &DeviceKeys) -> JsonValue {
        let (transcript, n, r_n) = self.sas_view(who, request, device);
        rec(
            label,
            None,
            self.person(who).id.0,
            &KeyRecordId::Sas {
                request,
                step: SasStep::Reveal,
            },
            &KeyBody::Sas(SasBody::Reveal { r: r_n }),
            vec![
                ("ik_hex", h(&transcript.ik.0)),
                ("commit_hex", h(&transcript.commitment(&n, &r_n).expect("commit"))),
                ("n_key_device", s(&n.key_device.to_wire())),
                ("n_dek_hex", h(&n.dek.0)),
                ("n_dsk_hex", h(&n.dsk.0)),
            ],
        )
    }

    fn reset(&self, label: &str, who: &str, reset: ResetId, av: u32, kind: CertKind, device: &DeviceKeys) -> JsonValue {
        let person = self.person(who);
        let new_ik = self.reset_ik(label, who);
        let new_ik = &new_ik;
        let certificate = AccountCertificate::sign(
            &origin(),
            person.id,
            v(av),
            kind,
            new_ik,
            person.at(av).public().expect("public"),
            None,
        )
        .expect("certificate");
        let device_certificate = DeviceCertificate::sign(
            &origin(),
            person.id,
            v(av),
            device.key_device,
            device.dek.public().expect("public"),
            device.dsk.public().expect("public"),
            &person.at(av).ask,
        )
        .expect("device");
        let new_r = RecoveryKey::from_bytes(draw(&format!("flows/{label}/R'")));
        let blob = new_r
            .seal_blob_with_nonce(
                &origin(),
                person.id,
                v(av),
                person.at(av),
                draw(&format!("flows/{label}/blob nonce")),
            )
            .expect("blob");
        let body = ResetBody {
            av: v(av),
            key_device: device.key_device,
            account: AccountBody::of(&certificate),
            device: DeviceBody::of(&device_certificate),
            recovery: blob,
        };
        rec(
            label,
            None,
            person.id.0,
            &KeyRecordId::Reset {
                account: person.id,
                reset,
            },
            &KeyBody::Reset(Box::new(body)),
            vec![
                ("ik_hex", h(&new_ik.public().expect("public").0)),
                ("r_hex", h(new_r.expose())),
            ],
        )
    }

    fn cancel(
        &self,
        label: &str,
        who: &str,
        reset: ResetId,
        reset_av: u32,
        proposed_ik: &Ed25519Public,
        with_r: bool,
    ) -> JsonValue {
        let person = self.person(who);
        let sig =
            with_r.then(|| sign_cancel(&origin(), person.id, v(reset_av), proposed_ik, &person.ik).expect("cancel"));
        let verify = if with_r {
            vec![
                ("ik_hex", h(&person.ik.public().expect("public").0)),
                ("reset_av", n(u64::from(reset_av))),
                ("proposed_ik_hex", h(&proposed_ik.0)),
            ]
        } else {
            Vec::new()
        };
        rec(
            label,
            None,
            person.id.0,
            &KeyRecordId::Cancel {
                account: person.id,
                reset,
            },
            &KeyBody::Cancel { sig },
            verify,
        )
    }
}

struct Row<'a> {
    row: &'a str,
    client: &'a str,
    server: &'a str,
    // Who decides the outcome: "flow" (the client's flows), "server", or both.
    layer: &'a [&'a str],
    given: JsonValue,
    steps: Vec<JsonValue>,
}

fn step(who: &str, does: &str, records: Vec<JsonValue>, client: &str, server: &str) -> JsonValue {
    obj(vec![
        ("who", s(who)),
        ("does", s(does)),
        ("records", arr(records)),
        ("client", s(client)),
        ("server", s(server)),
    ])
}

fn codes(text: &str) -> JsonValue {
    let mut found = Vec::new();
    for word in text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == '.')) {
        let word = word.trim_end_matches('.');
        let known_server = [
            "bad_statement",
            "role",
            "applied",
            "create_only",
            "device_not_approved",
            "request_closed",
            "request_pending",
            "change_set",
            "device_removed",
            "step_up_required",
            "reset_held",
            "writer_bound",
            "key_dependency",
            "key_version_stale",
            "too_large",
            "tombstoned",
            "rotation_due",
        ];
        if ((word.starts_with("keys.") && word.len() > 5) || known_server.contains(&word)) && !found.contains(&word) {
            found.push(word);
        }
    }
    arr(found.into_iter().map(s).collect())
}

fn scenario(name: &str, row: Row<'_>) -> JsonValue {
    obj(vec![
        ("name", s(name)),
        ("op", s("scenario")),
        ("row", s(row.row)),
        ("layer", arr(row.layer.iter().map(|layer| s(layer)).collect())),
        ("client", s(row.client)),
        ("client_codes", codes(row.client)),
        ("server", s(row.server)),
        ("server_codes", codes(row.server)),
        ("given", row.given),
        ("steps", arr(row.steps)),
    ])
}

fn roster(entries: &[(&str, &str)]) -> JsonValue {
    arr(entries
        .iter()
        .map(|(who, role)| obj(vec![("account", s(who)), ("role", s(role))]))
        .collect())
}

fn holds(version: u32, holders: &[&str]) -> JsonValue {
    obj(vec![
        ("team_version", n(u64::from(version))),
        ("holders", arr(holders.iter().map(|holder| s(holder)).collect())),
    ])
}

#[expect(
    clippy::too_many_lines,
    reason = "one scenario per row of ADR 0056's Vectors table that a flow or the server decides"
)]
pub(super) fn flows(cache: &HpkeCache) -> JsonValue {
    let w = World {
        cache,
        a: Person::new("A", account_id(ACCOUNT_A), 3),
        m: Person::new("M", account_id(ACCOUNT_M), 2),
        e: Person::new("E", AccountId(draw_uuid("flows/E id")), 1),
        o: Person::new("O", AccountId(draw_uuid("flows/O id")), 2),
        p: Person::new("P", AccountId(draw_uuid("flows/P id")), 2),
        p_other: Person::new("P from C", AccountId(draw_uuid("flows/P id")), 1),
        team: uuid_from_wire(TEAM_T).expect("team"),
    };
    let a1 = device("A device 1");
    let a_lost = device("A lost device");
    let m1 = device("M device 1");
    let o1 = device("O device 1");
    let dev_b = device("P device B");
    let dev_c = device("P device C");
    let dev_n = device("P device N");
    let dev_n2 = device("P device N approved again");
    let mut rows = Vec::new();

    let base_roster = roster(&[
        ("A", "admin"),
        ("O", "owner"),
        ("M", "member"),
        ("E", "editor"),
        ("P", "member"),
    ]);
    let given = |extra: Vec<(&str, JsonValue)>| {
        let mut members = vec![("roster", base_roster.clone())];
        members.extend(extra);
        obj(members)
    };

    rows.push(scenario("team version from a non-holder, and from a holder under an older av", Row {
        row: "A team version signed by an account that is not a holder of the one before, or by a holder under an older `av`",
        client: "keys.not_holder; keys.stale",
        server: "role; bad_statement",
        layer: &["flow", "server"],
        given: given(vec![("client_holds", holds(5, &["A@2", "M@1"])), ("account_av", obj(vec![("A", n(2)), ("E", n(1))])), ("rotation_due", b(false))]),
        steps: vec![
            step("E", "push", vec![w.member("E's certificate in the team", "E", 1), w.team_version("version 6 signed by E", 6, Start::Next, "E", 1), w.team_ring("its ring", 6)], "keys.not_holder", "role"),
            step("A", "push", vec![w.team_version("version 6 signed by A under av 1", 6, Start::Next, "A", 1), w.team_ring("its ring", 6)], "keys.stale", "bad_statement"),
        ],
    }));

    rows.push(scenario(
        "an older-av signature on the way to a newer version",
        Row {
            row: "A version signed under an older `av` than the client knows for its signer, on the way to a newer one",
            client: "keys.stale; stops at the version before",
            server: "none",
            layer: &["flow"],
            given: given(vec![
                ("client_holds", holds(5, &["A@2"])),
                ("client_knows_av", obj(vec![("A", n(2))])),
            ]),
            steps: vec![step(
                "server",
                "pull",
                vec![
                    w.team_version("version 6 signed by A under av 1", 6, Start::Next, "A", 1),
                    w.team_version("version 7 signed by A under av 2", 7, Start::Next, "A", 2),
                ],
                "keys.stale at version 6; the client stays at version 5",
                "none",
            )],
        },
    ));

    rows.push(scenario("version 7 under a removed device's old key, then version 8 by its recipient", Row {
        row: "Version 7 signed with a removed device's old account key and wrapping to account M, then version 8 signed by M under its current key, in one pull",
        client: "keys.stale at version 7; M is no holder",
        server: "none",
        layer: &["flow"],
        given: given(vec![("client_holds", holds(6, &["A@2", "P@2"])), ("client_knows_av", obj(vec![("A", n(2)), ("M", n(2))]))]),
        steps: vec![step("server", "pull", vec![
            w.team_version("version 7 signed under A's old av 1", 7, Start::Next, "A", 1),
            w.team_wrap("version 7 to M, under A's av 1", 7, "M", 2, "A", 1, &a_lost),
            w.team_version("version 8 signed by M under av 2", 8, Start::Next, "M", 2),
            w.team_wrap("version 8 to P, by M", 8, "P", 2, "M", 2, &m1),
        ], "keys.stale at version 7; M is no holder", "none")],
    }));

    let stopped = |extra: Vec<(&str, JsonValue)>| {
        let mut members = vec![
            ("roster", base_roster.clone()),
            ("client_holds", holds(6, &["A@2", "P@2"])),
            ("state", s("stopped")),
        ];
        members.extend(extra);
        obj(members)
    };
    rows.push(scenario("a stopped device offered a rotation by a holder, and by a non-holder", Row {
        row: "A stopped device offered an owner's next rotation whose signer held the last version it verified; one from an account that did not",
        client: "taken; keys.not_holder",
        server: "applied",
        layer: &["flow", "server"],
        given: stopped(vec![]),
        steps: vec![
            step("A", "push change set", vec![w.team_version("version 7 by A, a holder of 6", 7, Start::Next, "A", 2), w.team_ring("its ring", 7), w.team_wrap("version 7 to P", 7, "P", 2, "A", 2, &a1)], "taken", "applied"),
            step("O", "push change set", vec![w.team_version("version 7 by O, not a holder of 6", 7, Start::Next, "O", 2), w.team_ring("its ring", 7), w.team_wrap("version 7 to P, by O", 7, "P", 2, "O", 2, &o1)], "keys.not_holder", "applied"),
        ],
    }));

    rows.push(scenario("a stopped device whose qualifying admin rotated its account keys since", Row {
        row: "A stopped device whose qualifying admin rotated its account keys since, signing the new wrap under its newest `av`",
        client: "taken",
        server: "applied",
        layer: &["flow", "server"],
        given: stopped(vec![("account_av", obj(vec![("A", n(3))])), ("holders_accepted_for_6", arr(vec![s("A with the IK of av 2"), s("P")]))]),
        steps: vec![step("A", "push change set", vec![
            w.account("A's certificate at av 3", "A", 3),
            w.member("A's certificate in the team at av 3", "A", 3),
            w.team_version("version 7 by A under av 3", 7, Start::Next, "A", 3),
            w.team_ring("its ring", 7),
            w.team_wrap("version 7 to P, by A under av 3", 7, "P", 2, "A", 3, &a1),
        ], "taken", "applied")],
    }));

    rows.push(scenario(
        "a stopped device with no owner or admin that held its version",
        Row {
            row: "A stopped device with no owner or admin on the roster that held its version",
            client: "the team ends on the device",
            server: "the device withdraws its report",
            layer: &["flow"],
            given: obj(vec![
                ("roster", roster(&[("O", "owner"), ("M", "member"), ("P", "member")])),
                ("client_holds", holds(6, &["A@2", "P@2"])),
                ("state", s("stopped")),
                ("members_caught_up", b(true)),
            ]),
            steps: vec![step(
                "P",
                "decide",
                vec![],
                "the team ends on the device",
                "DELETE /v2/sync/scopes/{team}/stopped",
            )],
        },
    ));

    rows.push(scenario("while stopped at 6, a wrap of 6 under a removed key, then M's rotation", Row {
        row: "While stopped at version 6, a new wrap of version 6 to account M signed under a removed device's old account key, then M's rotation wrapping to the device under M's current key",
        client: "keys.not_holder; the device stays stopped",
        server: "none",
        layer: &["flow"],
        given: stopped(vec![("client_knows_av", obj(vec![("A", n(2)), ("M", n(2))]))]),
        steps: vec![step("server", "pull", vec![
            w.team_wrap("version 6 to M, under A's old av 1", 6, "M", 2, "A", 1, &a_lost),
            w.team_version("version 7 by M", 7, Start::Next, "M", 2),
            w.team_ring("its ring", 7),
            w.team_wrap("version 7 to P, by M", 7, "P", 2, "M", 2, &m1),
        ], "keys.not_holder; the device stays stopped", "none")],
    }));

    rows.push(scenario(
        "stopped on the personal key with no device to approve it",
        Row {
            row: "A device stopped on its personal or history key, with no device to approve it",
            client: "recovery with R or a reset is offered",
            server: "none",
            layer: &["flow"],
            given: obj(vec![
                ("personal_state", s("stopped")),
                ("other_devices", arr(Vec::new())),
            ]),
            steps: vec![step(
                "P",
                "decide",
                vec![],
                "recovery with R or a reset is offered",
                "none",
            )],
        },
    ));

    rows.push(scenario("a member rotates while a rotation is due", Row {
        row: "A rotation by a member that is not an owner or admin, while due, wrapping to several holders of the version before",
        client: "taken",
        server: "applied",
        layer: &["flow", "server"],
        given: given(vec![("server_holds", holds(6, &["A@2", "M@2", "P@2"])), ("rotation_due", b(true))]),
        steps: vec![step("M", "push change set", vec![
            w.team_version("version 7 by M", 7, Start::Next, "M", 2),
            w.team_ring("its ring", 7),
            w.team_wrap("version 7 to A", 7, "A", 2, "M", 2, &m1),
            w.team_wrap("version 7 to M", 7, "M", 2, "M", 2, &m1),
            w.team_wrap("version 7 to P", 7, "P", 2, "M", 2, &m1),
        ], "taken", "applied")],
    }));

    rows.push(scenario(
        "a member rotates while no rotation is due",
        Row {
            row: "A next team version from a member that is not an owner or admin while no rotation is due",
            client: "none",
            server: "role",
            layer: &["server"],
            given: given(vec![
                ("server_holds", holds(6, &["A@2", "M@2"])),
                ("rotation_due", b(false)),
            ]),
            steps: vec![step(
                "M",
                "push change set",
                vec![
                    w.team_version("version 7 by M", 7, Start::Next, "M", 2),
                    w.team_ring("its ring", 7),
                    w.team_wrap("version 7 to A", 7, "A", 2, "M", 2, &m1),
                ],
                "none",
                "role",
            )],
        },
    ));

    rows.push(scenario(
        "a member the server added with no confirming wrap",
        Row {
            row: "A member the server added with no confirming wrap",
            client: "gets no key",
            server: "none",
            layer: &["flow"],
            given: obj(vec![
                ("roster", roster(&[("A", "admin"), ("E", "member")])),
                ("server_holds", holds(6, &["A@2"])),
            ]),
            steps: vec![step(
                "E",
                "pull",
                vec![w.member("E's certificate in the team", "E", 1)],
                "gets no key",
                "none",
            )],
        },
    ));

    rows.push(scenario(
        "a team version or wrap naming an account with no key.member at that av",
        Row {
            row: "A team version or wrap naming an account with no `key.member` at that `av`",
            client: "held until the certificate arrives",
            server: "key_dependency",
            layer: &["flow", "server"],
            given: given(vec![("team_members_held", arr(vec![s("A@2"), s("M@1")]))]),
            steps: vec![
                step(
                    "A",
                    "push",
                    vec![w.team_wrap(
                        "version 6 to M at av 2, whose key.member at av 2 is missing",
                        6,
                        "M",
                        2,
                        "A",
                        2,
                        &a1,
                    )],
                    "held until the certificate arrives",
                    "key_dependency",
                ),
                step(
                    "M",
                    "push",
                    vec![w.member("M's certificate in the team at av 2", "M", 2)],
                    "the held wrap now verifies",
                    "applied",
                ),
            ],
        },
    ));

    let pk = |version: u32| KeyRef {
        owner: w.p.id.0,
        purpose: KeyPurpose::Personal,
        version: v(version),
    };
    rows.push(scenario("an envelope below the version in force at its place, and one before the rotation", Row {
        row: "An envelope below the version in force at its place in the order, or below the copy held; the same envelope before the rotation that follows it, taken",
        client: "keys.stale",
        server: "key_version_stale",
        layer: &["flow", "server"],
        given: obj(vec![("pull_order", arr(vec![s("envelope under PK 2"), s("PK version 3"), s("envelope under PK 2")]))]),
        steps: vec![step("server", "pull", vec![
            w.version("PK version 3", pk(3), Start::Next, &personal_key("P", 3), "P", 2, &w.p.at(2).ask),
        ], "the envelope before version 3 is taken; the one after it is keys.stale", "key_version_stale for a write under 2 once 3 is current")],
    }));

    let request = RequestId(draw_uuid("flows/request"));
    rows.push(scenario(
        "a nonce step from a device that is not approved, and a second nonce",
        Row {
            row: "A `nonce` step from a device that is not approved; a second `nonce`",
            client: "none",
            server: "device_not_approved; create_only",
            layer: &["server"],
            given: obj(vec![("approved_devices", arr(vec![s("B")])), ("request_from", s("N"))]),
            steps: vec![
                step(
                    "N",
                    "push",
                    vec![w.request("N's request", "P", request, &dev_n)],
                    "none",
                    "applied",
                ),
                step(
                    "C",
                    "push",
                    vec![w.nonce("a nonce from C, not approved", "P", request, &dev_c)],
                    "none",
                    "device_not_approved",
                ),
                step(
                    "B",
                    "push",
                    vec![w.nonce("B's nonce", "P", request, &dev_b)],
                    "none",
                    "applied",
                ),
                step(
                    "B",
                    "push",
                    vec![w.nonce("a second nonce", "P", request, &dev_b)],
                    "none",
                    "create_only",
                ),
            ],
        },
    ));

    rows.push(scenario("a reveal before the nonce, steps after the session ended", Row {
        row: "A `reveal` before the `nonce`, any step after a `cancel`, an approval or `expires_at`, or an approval change set after `expires_at`",
        client: "keys.session",
        server: "request_closed",
        layer: &["flow", "server"],
        given: obj(vec![("session", s("open"))]),
        steps: vec![step("N", "push", vec![w.reveal("N's reveal before any nonce", "P", request, &dev_n)], "keys.session", "request_closed")],
    }));

    rows.push(scenario(
        "a second open request from one device row",
        Row {
            row: "A second open request from one device row",
            client: "none",
            server: "request_pending",
            layer: &["server"],
            given: obj(vec![("open_requests_on_row", n(1))]),
            steps: vec![step(
                "N",
                "push",
                vec![w.request(
                    "a second request from N's row",
                    "P",
                    RequestId(draw_uuid("flows/second request")),
                    &dev_n2,
                )],
                "none",
                "request_pending",
            )],
        },
    ));

    let trust_for_p = TrustPlaintext {
        pins: vec![TrustPin {
            account: w.p.id,
            ik: w.p.ik.public().expect("public"),
            av: v(2),
            how: PinHow::Compared,
            alert: false,
            replaced: Vec::new(),
        }],
        versions: vec![TrustVersion {
            owner: w.p.id.0,
            purpose: KeyPurpose::Personal,
            version: v(2),
            record: labelled_version(&w, "P PK2").1,
        }],
    };
    let mut stale_approval = w.approval("an approval built at av 1", "P", 1, &dev_n, &dev_b, &trust_for_p);
    stale_approval.truncate(3);
    let mut fresh = w.approval("built again at av 2", "P", 2, &dev_n, &dev_b, &trust_for_p);
    fresh.truncate(3);
    rows.push(scenario("an approval built at an av a rotation passed, then again; a replace during a session", Row {
        row: "An approval built at an `av` a rotation passed, then built again at the new `av`, taken; a replace during a session",
        client: "keys.session after a replace",
        server: "bad_statement, then applied",
        layer: &["flow", "server"],
        given: obj(vec![("account_av", n(2)), ("session", s("revealed"))]),
        steps: vec![
            step("B", "push change set", stale_approval, "none", "bad_statement"),
            step("B", "push change set", fresh, "none", "applied"),
            step("N", "decide", vec![], "after a replace the IK the words covered changed: keys.session, and N asks again", "none"),
        ],
    }));

    rows.push(scenario("a rotation that keeps a device that is not an own-device pin", Row {
        row: "A rotation that keeps a device that is not an own-device pin; an own-device pin whose DEK came from a certificate",
        client: "keys.not_compared",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("own_device_pins", arr(vec![s("B")])), ("certified_devices", arr(vec![s("B"), s("C")]))]),
        steps: vec![step("B", "decide", vec![w.device_cert("C's certificate, never compared", "P", 2, &dev_c)], "keys.not_compared", "none")],
    }));

    let mut bad_genesis = w.genesis("B's genesis", "P", &dev_b);
    let mut broken_version = w.version(
        "B's genesis: personal version 1, signed by the wrong key",
        pk(1),
        Start::Over,
        &personal_key("P", 1),
        "P",
        1,
        &w.p.ik,
    );
    set_verify(
        &mut broken_version,
        "signer_hex",
        h(&w.p.at(1).ask.public().expect("public").0),
    );
    set_verify(&mut broken_version, "valid", b(false));
    bad_genesis[3] = broken_version;
    rows.push(scenario(
        "a change set with one bad object",
        Row {
            row: "A genesis, rotation, approval, reset or team rotation change set with one bad object",
            client: "that object's error",
            server: "that object's code, change_set for the rest; nothing applies",
            layer: &["flow", "server"],
            given: obj(vec![("account_has_keys", b(false))]),
            steps: vec![step(
                "B",
                "push change set",
                bad_genesis,
                "keys.signature for the version record",
                "bad_statement for it, change_set for the rest",
            )],
        },
    ));

    rows.push(scenario(
        "two genesis change sets, and an identical retry",
        Row {
            row: "Two genesis change sets; an identical retry after a timeout",
            client: "none",
            server: "create_only for the loser; applied for the retry",
            layer: &["server"],
            given: obj(vec![("account_has_keys", b(false))]),
            steps: vec![
                step(
                    "B",
                    "push change set",
                    w.genesis("B's genesis", "P", &dev_b),
                    "none",
                    "applied",
                ),
                step(
                    "C",
                    "push change set",
                    w.genesis("C's genesis", "P'", &dev_c),
                    "none",
                    "create_only",
                ),
                step(
                    "B",
                    "push change set",
                    w.genesis("B's genesis", "P", &dev_b),
                    "none",
                    "applied",
                ),
            ],
        },
    ));

    rows.push(scenario("a device left out of a rotation", Row {
        row: "A device left out of a rotation, shown the certificate but not yet the whole change set; then all of it",
        client: "waits; then locks, erases nothing",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("device", s("C")), ("account_av", n(1))]),
        steps: vec![
            step("server", "pull", vec![w.account("the certificate at av 2", "P", 2)], "waits", "none"),
            step("server", "pull", w.rotation("B's rotation, which leaves C out", "P", 2, &[&dev_b], &dev_b), "the whole change set: locks, erases nothing", "none"),
        ],
    }));

    rows.push(scenario("recovery from zero devices carries the old keys into the new rings", Row {
        row: "Recovery from zero devices that reads the old PK and HK versions and rings before approval and carries them into the new rings",
        client: "succeeds",
        server: "applied",
        layer: &["flow", "server"],
        given: obj(vec![("account_av", n(1)), ("recovery_key", h(w.p.r.expose()))]),
        steps: vec![step("N", "push change set", w.rotation("N's recovery", "P", 2, &[&dev_n], &dev_n), "succeeds", "applied")],
    }));

    let reset_id = ResetId(draw_uuid("flows/reset"));
    let proposal = w.reset(
        "P's reset proposal",
        "P",
        reset_id,
        2,
        CertKind::ResetKeepingKeys,
        &dev_b,
    );
    rows.push(scenario(
        "a cancel from a removed row's device",
        Row {
            row: "A cancel from a removed row's device",
            client: "none",
            server: "device_removed",
            layer: &["server"],
            given: obj(vec![("pending_reset", b(true)), ("removed_rows", arr(vec![s("C")]))]),
            steps: vec![step(
                "C",
                "push",
                vec![w.cancel(
                    "C's cancel",
                    "P",
                    reset_id,
                    2,
                    &w.reset_ik("P's reset proposal", "P").public().expect("public"),
                    false,
                )],
                "none",
                "device_removed",
            )],
        },
    ));
    rows.push(scenario(
        "a reset while one is pending; kinds from the wrong caller",
        Row {
            row: "A reset proposal while one is pending; kind 2 from a sign-in, kind 3 from an approved device",
            client: "none",
            server: "bad_statement",
            layer: &["server"],
            given: obj(vec![("pending_reset", b(false))]),
            steps: vec![
                step("B", "push", vec![proposal.clone()], "none", "applied"),
                step(
                    "C",
                    "push",
                    vec![w.reset(
                        "a second proposal",
                        "P",
                        ResetId(draw_uuid("flows/second reset")),
                        2,
                        CertKind::ResetKeepingKeys,
                        &dev_c,
                    )],
                    "none",
                    "bad_statement",
                ),
                step(
                    "N, not approved",
                    "push",
                    vec![w.reset(
                        "kind 2 from a sign-in",
                        "P",
                        ResetId(draw_uuid("flows/kind 2 reset")),
                        2,
                        CertKind::ResetKeepingKeys,
                        &dev_n,
                    )],
                    "none",
                    "bad_statement",
                ),
                step(
                    "B",
                    "push",
                    vec![w.reset(
                        "kind 3 from an approved device",
                        "P",
                        ResetId(draw_uuid("flows/kind 3 reset")),
                        2,
                        CertKind::ResetEmpty,
                        &dev_b,
                    )],
                    "none",
                    "bad_statement",
                ),
            ],
        },
    ));
    let kind3 = w.reset(
        "a kind 3 proposal",
        "P",
        ResetId(draw_uuid("flows/kind 3 proposal")),
        2,
        CertKind::ResetEmpty,
        &dev_n,
    );
    rows.push(scenario(
        "a kind 3 proposal without a step-up",
        Row {
            row: "A kind 3 proposal without a step-up",
            client: "none",
            server: "step_up_required",
            layer: &["server"],
            given: obj(vec![("step_up", null())]),
            steps: vec![step(
                "N, not approved",
                "push",
                vec![kind3.clone()],
                "none",
                "step_up_required",
            )],
        },
    ));
    rows.push(scenario(
        "a kind 3 proposal while lost devices' rows remain",
        Row {
            row: "A kind 3 proposal while lost devices' rows remain; one of those devices cancels it",
            client: "none",
            server: "applied; the cancel ends it",
            layer: &["server"],
            given: obj(vec![
                ("step_up_seconds_ago", n(30)),
                ("device_rows", arr(vec![s("B"), s("C")])),
            ]),
            steps: vec![
                step("N, not approved", "push", vec![kind3.clone()], "none", "applied"),
                step(
                    "B",
                    "push",
                    vec![w.cancel(
                        "B's cancel",
                        "P",
                        ResetId(draw_uuid("flows/kind 3 proposal")),
                        2,
                        &w.reset_ik("a kind 3 proposal", "P").public().expect("public"),
                        false,
                    )],
                    "none",
                    "applied; the cancel ends it",
                ),
            ],
        },
    ));
    rows.push(scenario("the proposing device signs out", Row {
        row: "The proposing device signs out while its reset is pending, under the reset's DSK; a proof under another key on that row",
        client: "the reset ends; nothing changes",
        server: "204 both",
        layer: &["server"],
        given: obj(vec![("pending_reset", b(true)), ("reset_dsk_hex", h(&dev_b.dsk.public().expect("public").0))]),
        steps: vec![step("B", "DELETE /v2/sync/key-device", vec![proposal.clone()], "the reset ends with the reset's DSK; nothing changes under another key", "204 both")],
    }));
    rows.push(scenario(
        "a pending reset 7 days past held_until",
        Row {
            row: "A pending reset 7 days past `held_until` with no activation",
            client: "the reset ends",
            server: "tombstoned",
            layer: &["server", "flow"],
            given: obj(vec![("pending_reset", b(true)), ("days_past_held_until", n(7))]),
            steps: vec![step(
                "server",
                "expire",
                vec![proposal.clone()],
                "the reset ends",
                "tombstoned",
            )],
        },
    ));
    let activation = w.activation("P's reset proposal", "P", 2, CertKind::ResetKeepingKeys, &dev_b);
    rows.push(scenario(
        "activations out of time or from another device",
        Row {
            row: "An activation before `held_until`; after the reset ended; from another device",
            client: "none",
            server: "reset_held; bad_statement; writer_bound",
            layer: &["server"],
            given: obj(vec![("pending_reset", b(true))]),
            steps: vec![
                step("B", "push change set", activation.clone(), "none", "reset_held"),
                step("B", "push change set", activation.clone(), "none", "bad_statement"),
                step("C", "push change set", activation.clone(), "none", "writer_bound"),
            ],
        },
    ));
    rows.push(scenario(
        "a rotation while a reset is pending",
        Row {
            row: "A rotation while a reset is pending, which ends it",
            client: "the reset ends",
            server: "applied",
            layer: &["server", "flow"],
            given: obj(vec![("pending_reset", b(true)), ("account_av", n(1))]),
            steps: vec![step(
                "B",
                "push change set",
                w.rotation("B's rotation", "P", 2, &[&dev_b], &dev_b),
                "the reset ends",
                "applied",
            )],
        },
    ));
    rows.push(scenario("kind 3 and kind 2 activations", Row {
        row: "Kind 3 activation with no old PK and HK; kind 2 activation with rings",
        client: "start 1 and no ring; start 0 with rings",
        server: "applied; every other device row removed, every team held just before marked rotation_due, the personal and history records gone only for kind 3",
        layer: &["server", "flow"],
        given: obj(vec![("pending_reset", b(true)), ("held_until_passed", b(true))]),
        steps: vec![
            step("N", "push change set", w.activation("a kind 3 proposal", "P", 2, CertKind::ResetEmpty, &dev_n), "start 1 and no ring", "applied"),
            step("B", "push change set", w.activation("P's reset proposal", "P", 2, CertKind::ResetKeepingKeys, &dev_b), "start 0 with rings", "applied"),
        ],
    }));

    rows.push(scenario(
        "a team rotation with a wrap to a removed member or a superseded av",
        Row {
            row: "A team rotation with a wrap to a removed member or to a member's superseded `av`",
            client: "none",
            server: "bad_statement, change_set for the rest; rotation_due stays",
            layer: &["server"],
            given: given(vec![
                ("removed", arr(vec![s("E")])),
                ("account_av", obj(vec![("M", n(2))])),
                ("rotation_due", b(true)),
            ]),
            steps: vec![
                step(
                    "A",
                    "push change set",
                    vec![
                        w.team_version("version 7", 7, Start::Next, "A", 2),
                        w.team_ring("its ring", 7),
                        w.team_wrap("version 7 to E, removed", 7, "E", 1, "A", 2, &a1),
                    ],
                    "none",
                    "bad_statement, change_set for the rest",
                ),
                step(
                    "A",
                    "push change set",
                    vec![
                        w.team_version("version 7", 7, Start::Next, "A", 2),
                        w.team_ring("its ring", 7),
                        w.team_wrap("version 7 to M at its superseded av 1", 7, "M", 1, "A", 2, &a1),
                    ],
                    "none",
                    "bad_statement, change_set for the rest",
                ),
            ],
        },
    ));

    rows.push(scenario("a member's rotation wrapping to a member left out of the version before", Row {
        row: "A rotation by a member that is not an owner or admin, with a wrap to a member left out of the version before",
        client: "none",
        server: "role",
        layer: &["server"],
        given: given(vec![("server_holds", holds(6, &["A@2", "M@2"])), ("rotation_due", b(true))]),
        steps: vec![step("M", "push change set", vec![w.team_version("version 7 by M", 7, Start::Next, "M", 2), w.team_ring("its ring", 7), w.team_wrap("version 7 to P, left out of 6", 7, "P", 2, "M", 2, &m1)], "none", "role")],
    }));

    rows.push(scenario("a restart shown to a holder, and a restart while a holder is on the roster", Row {
        row: "A restart shown to a client whose account holds the current version; a restart while a holder is on the roster",
        client: "keys.not_holder",
        server: "role",
        layer: &["flow", "server"],
        given: given(vec![("server_holds", holds(6, &["M@2"])), ("client", s("M"))]),
        steps: vec![step("O", "push change set", vec![w.team_version("version 7 by O with start 1", 7, Start::Over, "O", 2), w.team_wrap("version 7 to O", 7, "O", 2, "O", 2, &o1)], "keys.not_holder", "role")],
    }));

    rows.push(scenario(
        "a sole owner who reset restarts its team",
        Row {
            row: "A sole owner who reset and restarts its team from the device that held the key",
            client: "takes its own restart",
            server: "applied",
            layer: &["flow", "server"],
            given: obj(vec![
                ("roster", roster(&[("O", "owner")])),
                ("server_holds", holds(6, &["O with its IK before the reset"])),
            ]),
            steps: vec![step(
                "O",
                "push change set",
                vec![
                    w.team_version("version 7 by O with start 1", 7, Start::Over, "O", 2),
                    w.team_ring("a ring, since its device holds version 6", 7),
                    w.team_wrap("version 7 to O", 7, "O", 2, "O", 2, &o1),
                ],
                "takes its own restart",
                "applied",
            )],
        },
    ));

    rows.push(scenario(
        "a history entry pushed again after an HK rotation",
        Row {
            row: "A history entry pushed again after an HK rotation, encrypted under the newest version",
            client: "taken",
            server: "applied; under an older version key_version_stale",
            layer: &["server"],
            given: obj(vec![("hk_current", n(3))]),
            steps: vec![step(
                "B",
                "push",
                vec![],
                "taken (history.json, pushed_again)",
                "applied; under an older version key_version_stale",
            )],
        },
    ));

    rows.push(scenario("a team version pushed back after a restore by its signer's device", Row {
        row: "After a restore that lost a team version, its signer's device pushes it back with the same fields, every ordinary check passing",
        client: "verifies",
        server: "applied",
        layer: &["flow", "server"],
        given: obj(vec![("new_epoch", b(true)), ("server_holds", holds(6, &["A@2", "M@2"]))]),
        steps: vec![step("A", "push change set", vec![w.team_version("version 7 by A", 7, Start::Next, "A", 2), w.team_ring("its ring", 7), w.team_wrap("version 7 to M", 7, "M", 2, "A", 2, &a1)], "verifies", "applied")],
    }));
    rows.push(scenario(
        "a version only another member signed, missing after a restore",
        Row {
            row: "A version only another member signed, missing after a restore",
            client: "the team stops on the device until that member's device pushes it back",
            server: "none",
            layer: &["flow"],
            given: obj(vec![
                ("new_epoch", b(true)),
                ("client_holds", holds(7, &["A@2", "P@2"])),
                ("server_holds", holds(6, &["A@2", "P@2"])),
            ]),
            steps: vec![step(
                "A",
                "push change set",
                vec![
                    w.team_version("version 7 by A", 7, Start::Next, "A", 2),
                    w.team_ring("its ring", 7),
                    w.team_wrap("version 7 to P", 7, "P", 2, "A", 2, &a1),
                ],
                "P's team is stopped until this applies",
                "none",
            )],
        },
    ));
    rows.push(scenario(
        "a rotation and a confirmation by two admins, after a restore",
        Row {
            row: "A version one admin rotated and a member another admin confirmed, after a restore",
            client: "both go back, each from its own signer's device",
            server: "applied each",
            layer: &["flow", "server"],
            given: obj(vec![
                ("new_epoch", b(true)),
                ("roster", roster(&[("A", "admin"), ("O", "admin"), ("P", "member")])),
            ]),
            steps: vec![
                step(
                    "A",
                    "push change set",
                    vec![
                        w.team_version("version 7 by A", 7, Start::Next, "A", 2),
                        w.team_ring("its ring", 7),
                        w.team_wrap("version 7 to O", 7, "O", 2, "A", 2, &a1),
                    ],
                    "verifies",
                    "applied",
                ),
                step(
                    "O",
                    "push",
                    vec![w.team_wrap("O confirms P at version 7", 7, "P", 2, "O", 2, &o1)],
                    "verifies",
                    "applied",
                ),
            ],
        },
    ));
    rows.push(scenario(
        "a refused push, another device puts the version back, a restart",
        Row {
            row: "A refused push of the device's own version, then another device puts it back, then a restart",
            client: "the scope stays ended",
            server: "applied for the other device",
            layer: &["flow", "server"],
            given: obj(vec![
                ("new_epoch", b(true)),
                ("scope_state", s("ended after the refusal")),
            ]),
            steps: vec![step(
                "other device of A",
                "push change set",
                vec![
                    w.team_version("version 7 by A", 7, Start::Next, "A", 2),
                    w.team_ring("its ring", 7),
                ],
                "the scope stays ended",
                "applied for the other device",
            )],
        },
    ));
    rows.push(scenario(
        "a lost confirmation pushed back by a plain member",
        Row {
            row: "After a restore that lost a confirmation, a member that is not an owner or admin pushes it back",
            client: "none",
            server: "role; an owner or admin confirms the member at the next team version",
            layer: &["server"],
            given: obj(vec![("new_epoch", b(true)), ("roster", base_roster.clone())]),
            steps: vec![step(
                "M",
                "push",
                vec![w.team_wrap("M's copy of the confirmation of P at version 6", 6, "P", 2, "M", 2, &m1)],
                "none",
                "role",
            )],
        },
    ));
    rows.push(scenario(
        "a completed reset a restore lost",
        Row {
            row: "A completed reset a restore lost",
            client: "the account's devices sign out; the person recovers or resets",
            server: "bad_statement",
            layer: &["flow", "server"],
            given: obj(vec![("new_epoch", b(true))]),
            steps: vec![step(
                "B",
                "push change set",
                activation.clone(),
                "the account's devices sign out; the person recovers or resets",
                "bad_statement",
            )],
        },
    ));
    rows.push(scenario(
        "a device whose approval a restore lost",
        Row {
            row: "A device whose approval a restore lost",
            client: "locks; approved again with a new key device id",
            server: "device_not_approved until then",
            layer: &["flow", "server"],
            given: obj(vec![("new_epoch", b(true)), ("lost", s("N's approval"))]),
            steps: vec![step(
                "N",
                "pull",
                vec![],
                "locks; approved again with a new key device id",
                "device_not_approved",
            )],
        },
    ));
    rows.push(scenario(
        "a removed device's new key device offered from another row",
        Row {
            row: "A removed device's new key device, certified under the current ASK, offered from another row",
            client: "none",
            server: "device_not_approved",
            layer: &["server"],
            given: obj(vec![("removed_rows", arr(vec![s("C")]))]),
            steps: vec![step(
                "C on another row",
                "push",
                vec![w.device_cert(
                    "a new key device certified under the current ASK",
                    "P",
                    2,
                    &device("P device C again"),
                )],
                "none",
                "device_not_approved",
            )],
        },
    ));

    rows.extend(approval_rows(&w, &dev_b, &dev_c, &dev_n, &a1));

    rows.push(scenario(
        "a recovery from a fresh row, then a call that needs approval",
        Row {
            row: "A recovery from a fresh row, then a call that needs approval",
            client: "succeeds",
            server: "applied, then approved",
            layer: &["flow", "server"],
            given: obj(vec![("account_av", n(1)), ("device_row", s("fresh"))]),
            steps: vec![step(
                "N",
                "push change set",
                w.rotation("N's recovery from a fresh row", "P", 2, &[&dev_n], &dev_n),
                "succeeds",
                "applied, then approved",
            )],
        },
    ));
    rows.push(scenario(
        "a rotation or trust record at the record limit",
        Row {
            row: "A rotation or a trust record at the record limit",
            client: "succeeds",
            server: "applied; over it too_large",
            layer: &["server", "flow"],
            given: obj(vec![
                ("record_limit_bytes", n(1 << 20)),
                ("measure", s("fields encoded without HTML escaping")),
                (
                    "records",
                    s("trust.json, fit: the generated compared pins at and one past 1 MiB, with their record lengths"),
                ),
            ]),
            steps: vec![step(
                "B",
                "push change set",
                vec![],
                "succeeds at the limit (trust.json, fit)",
                "applied; over it too_large",
            )],
        },
    ));
    rows.push(scenario("a certificate under an IK seen replaced", Row {
        row: "A certificate under an IK seen replaced, offered as the newest; the same certificate verifying an object signed before the replace",
        client: "keys.retired_ik; taken",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("pin", obj(vec![("account", s("A")), ("replaced", arr(vec![s("A's IK")]))]))]),
        steps: vec![step("server", "pull", vec![w.account("A's certificate at av 3 under its old IK", "A", 3)], "keys.retired_ik as the newest; taken for objects signed under it before the replace", "none")],
    }));

    super::out::file(
        "flows",
        "ADR 0056's Vectors rows a flow or the server decides: each row's key objects from one world, with its client and server columns. tablepro-keys checks every object; the flows and the server check the outcomes.",
        vec![
            ("origin", s(ORIGIN)),
            ("world", world_json(&w)),
            ("scenarios", arr(rows)),
        ],
    )
}

// What opens a blob and what its keys must give: the recovery key and the certificate's public keys.
fn blob_verify(r: &RecoveryKey, keys: &AccountKeys) -> Vec<(&'static str, JsonValue)> {
    let public = keys.public().expect("public");
    vec![
        ("r_hex", h(r.expose())),
        ("certificate_ask_hex", h(&public.ask.0)),
        ("certificate_aek_hex", h(&public.aek.0)),
    ]
}

fn personal_ring(key: KeyRef, who: &str, label: &str) -> JsonValue {
    let name = if key.purpose == KeyPurpose::History {
        format!("{who} history")
    } else {
        who.to_owned()
    };
    let newer = personal_key(&name, key.version.get());
    let older = personal_key(&name, key.version.get() - 1);
    let ring =
        Ring::seal_with_nonce(&origin(), key, &newer, &older, draw(&format!("flows/{label}/nonce"))).expect("ring");
    rec(
        label,
        None,
        key.owner,
        &KeyRecordId::Ring(key),
        &KeyBody::Ring(ring),
        vec![
            ("newer_key_hex", h(newer.expose())),
            ("below_kid_hex", h(&older.kid().expect("kid").0)),
        ],
    )
}

#[expect(clippy::too_many_lines, reason = "one scenario per approval row")]
fn approval_rows(
    w: &World<'_>,
    dev_b: &DeviceKeys,
    dev_c: &DeviceKeys,
    dev_n: &DeviceKeys,
    a1: &DeviceKeys,
) -> Vec<JsonValue> {
    let pk = |version: u32| KeyRef {
        owner: w.p.id.0,
        purpose: KeyPurpose::Personal,
        version: v(version),
    };
    let pin = |who: &Person, av: u32, how: PinHow, alert: bool, replaced: Vec<Ed25519Public>| TrustPin {
        account: who.id,
        ik: who.ik.public().expect("public"),
        av: v(av),
        how,
        alert,
        replaced,
    };
    let record_of = |label: &str| labelled_version(w, label).1;
    let trust = |pins: Vec<TrustPin>, versions: Vec<TrustVersion>| TrustPlaintext { pins, versions };
    let pv = |version: u32, label: &str| TrustVersion {
        owner: w.p.id.0,
        purpose: KeyPurpose::Personal,
        version: v(version),
        record: record_of(label),
    };
    let tv = |version: u32, label: &str| TrustVersion {
        owner: w.team,
        purpose: KeyPurpose::Team,
        version: v(version),
        record: record_of(label),
    };
    let mut rows = Vec::new();

    rows.push(scenario(
        "an approver at av 1 approves a device that knows av 2",
        Row {
            row: "An approver at `av` 1 approves a device that knows `av` 2 under the same IK, the words matching",
            client: "keys.stale; the device keeps its keys",
            server: "none",
            layer: &["flow"],
            given: obj(vec![("device_av", n(2)), ("approver_av", n(1))]),
            steps: vec![step(
                "C approves N",
                "pull",
                w.approval(
                    "C at av 1",
                    "P",
                    1,
                    dev_n,
                    dev_c,
                    &trust(
                        vec![pin(&w.p, 1, PinHow::Compared, false, Vec::new())],
                        vec![pv(1, "P PK1")],
                    ),
                ),
                "keys.stale; the device keeps its keys",
                "none",
            )],
        },
    ));
    let other_ik_a = Ed25519Seed::from_bytes(draw("flows/A other IK"))
        .public()
        .expect("public");
    rows.push(scenario(
        "an approval whose trust pins another account under another IK",
        Row {
            row: "An approval whose trust pins another account under a different IK than the device's pin",
            client: "an alert for that account",
            server: "none",
            layer: &["flow"],
            given: obj(vec![(
                "device_pins",
                arr(vec![obj(vec![
                    ("account", s("A")),
                    ("ik_hex", h(&w.a.ik.public().expect("public").0)),
                ])]),
            )]),
            steps: vec![step(
                "B approves N",
                "pull",
                w.approval(
                    "B with A pinned otherwise",
                    "P",
                    2,
                    dev_n,
                    dev_b,
                    &trust(
                        vec![
                            pin(&w.p, 2, PinHow::Compared, false, Vec::new()),
                            TrustPin {
                                ik: other_ik_a,
                                ..pin(&w.a, 2, PinHow::FirstUse, false, Vec::new())
                            },
                        ],
                        vec![pv(2, "P PK2")],
                    ),
                ),
                "an alert for A",
                "none",
            )],
        },
    ));
    rows.push(scenario("an approval whose trust lists the device's pinned IK as replaced", Row {
        row: "An approval whose trust lists the device's pinned IK as replaced, with and without the endorsement held",
        client: "follows the new IK; an alert",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("device_pins", arr(vec![obj(vec![("account", s("A")), ("ik_hex", h(&other_ik_a.0))])]))]),
        steps: vec![step("B approves N", "pull", w.approval("B with A's old IK replaced", "P", 2, dev_n, dev_b, &trust(
            vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new()), pin(&w.a, 3, PinHow::Replaced, false, vec![other_ik_a])],
            vec![pv(2, "P PK2")],
        )), "with the endorsement held: follows the new IK; without it: an alert", "none")],
    }));
    rows.push(scenario("an approver with a lower personal version, and one with another record at an equal version", Row {
        row: "An approver at the same `av` with a lower personal version, and one with another record at an equal version",
        client: "keeps its own; keys.conflict",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("device_holds", obj(vec![("personal", n(3)), ("record_hex", h(&record_of("P PK3 held")))]))]),
        steps: vec![
            step("B approves N", "pull", w.approval("B with PK 2", "P", 2, dev_n, dev_b, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(2, "P PK2")])), "keeps its own", "none"),
            step("C approves N", "pull", w.approval("C with another PK 3 record", "P", 2, dev_n, dev_c, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(3, "P PK3 other")])), "keys.conflict", "none"),
        ],
    }));
    rows.push(scenario("B keeps team version 6 when approved from a C the server kept behind", Row {
        row: "B saw A's rotation and holds team version 6, stopped or not. The person approves B from C, which took version 7 under A's old account key with a wrap to M, and version 8 signed by M, because the server withheld A's rotation from C",
        client: "B keeps version 6 with its holders and state; version 8 stays a hint its own checks refuse (keys.stale)",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("b_holds", holds(6, &["A@2", "P@2"])), ("b_knows_av", obj(vec![("A", n(2))]))]),
        steps: vec![
            step("C approves B", "pull", w.approval("C's view with team version 8", "P", 2, dev_b, dev_c, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![tv(8, "team 8 by M")])), "B keeps version 6", "none"),
            step("server", "pull", vec![w.team_version("version 7 under A's old av 1", 7, Start::Next, "A", 1), w.team_wrap("version 7 to M under A's av 1", 7, "M", 2, "A", 1, a1), w.team_version("version 8 by M", 8, Start::Next, "M", 2)], "keys.stale", "none"),
        ],
    }));
    let c_old = |version: u32| {
        w.version(
            &format!("C's personal version {version} under the old av 1"),
            pk(version),
            Start::Next,
            &personal_key("P old", version),
            "P",
            1,
            &w.p.at(1).ask,
        )
    };
    let b_v2 = w.version(
        "B's personal version 2 under av 2",
        pk(2),
        Start::Next,
        &personal_key("P", 2),
        "P",
        2,
        &w.p.at(2).ask,
    );
    rows.push(scenario("C kept on av 1 holds versions 2 and 3 under the old key; B approves C", Row {
        row: "C, kept on `av` 1 by the server, took personal versions 2 and 3 signed under the old account key and still holds its version 2. B, at `av` 2 with personal version 2 signed under it, approves C",
        client: "keys.conflict at version 2; the approval fails, and no old-key version becomes current through it",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("c_holds", arr(vec![c_old(2), c_old(3)])), ("b_holds", arr(vec![b_v2.clone()]))]),
        steps: vec![step("B approves C", "pull", w.approval("B with PK 2 under av 2", "P", 2, dev_c, dev_b, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(2, "P PK2 under av 2")])), "keys.conflict at version 2", "none")],
    }));
    rows.push(scenario(
        "the same C after an anchored rebuild that kept only version 3",
        Row {
            row: "The same C after an anchored rebuild that kept only its version 3, approved by B",
            client: "C takes av 2 and B's version 2; its version 3 is never current",
            server: "none",
            layer: &["flow"],
            given: obj(vec![
                ("c_holds", arr(vec![c_old(3)])),
                ("b_holds", arr(vec![b_v2.clone()])),
            ]),
            steps: vec![step(
                "B approves C",
                "pull",
                w.approval(
                    "B with PK 2, again",
                    "P",
                    2,
                    dev_c,
                    dev_b,
                    &trust(
                        vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())],
                        vec![pv(2, "P PK2 under av 2")],
                    ),
                ),
                "C takes av 2 and B's version 2",
                "none",
            )],
        },
    ));
    rows.push(scenario("the pair the other way", Row {
        row: "The same pair the other way: C, at `av` 2 but holding personal version 3 signed under `av` 1, approves B",
        client: "B keeps its version 2; C's version 3 is never current",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("c_holds", arr(vec![c_old(3)])), ("b_holds", arr(vec![b_v2.clone()]))]),
        steps: vec![step("C approves B", "pull", w.approval("C at av 2 with the old-key PK 3", "P", 2, dev_b, dev_c, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(3, "P PK3 under av 1")])), "B keeps its version 2", "none")],
    }));
    rows.push(scenario(
        "neither side holds a personal version under the merged av",
        Row {
            row: "An approval where neither side holds a personal version signed under the merged current `av`",
            client: "keys.stale; the device keeps its prior state",
            server: "none",
            layer: &["flow"],
            given: obj(vec![("both_hold", arr(vec![c_old(2)])), ("merged_av", n(2))]),
            steps: vec![step(
                "C approves B",
                "pull",
                w.approval(
                    "C with only old-key versions",
                    "P",
                    2,
                    dev_b,
                    dev_c,
                    &trust(
                        vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())],
                        vec![pv(2, "P PK2 under av 1")],
                    ),
                ),
                "keys.stale",
                "none",
            )],
        },
    ));
    rows.push(scenario("an approval over a stopped personal key and over an ended scope", Row {
        row: "An approval over a stopped personal key that brings the version signed under the current `av`, over an ended scope, and a restart after each",
        client: "clears; stays ended; the same after restart",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("personal_state", s("stopped")), ("team_state", s("ended"))]),
        steps: vec![step("B approves N", "pull", w.approval("B with PK 2 and the ended team", "P", 2, dev_n, dev_b, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(2, "P PK2 under av 2"), tv(6, "team 6")])), "the personal stop clears; the team stays ended", "none")],
    }));
    rows.push(scenario(
        "a team scope new to the device",
        Row {
            row: "A team scope new to the device, imported from the approver",
            client: "takes its version and record, ok, holders from the wraps it accepts",
            server: "none",
            layer: &["flow"],
            given: obj(vec![("device_teams", arr(Vec::new()))]),
            steps: vec![step(
                "B approves N",
                "pull",
                w.approval(
                    "B with team version 6",
                    "P",
                    2,
                    dev_n,
                    dev_b,
                    &trust(
                        vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())],
                        vec![pv(2, "P PK2 under av 2"), tv(6, "team 6")],
                    ),
                ),
                "takes version 6 and its record, ok",
                "none",
            )],
        },
    ));
    rows.push(scenario(
        "a device locked by its own account's reset",
        Row {
            row: "A device locked by its own account's reset, approved by the resetting device",
            client: "the lock clears",
            server: "none",
            layer: &["flow"],
            given: obj(vec![("own_account", s("locked: an unendorsed IK"))]),
            steps: vec![step(
                "B, which reset, approves C",
                "pull",
                w.approval(
                    "B after its reset",
                    "P",
                    2,
                    dev_c,
                    dev_b,
                    &trust(
                        vec![pin(&w.p, 2, PinHow::Compared, true, Vec::new())],
                        vec![pv(2, "P PK2 under av 2")],
                    ),
                ),
                "the lock clears",
                "none",
            )],
        },
    ));
    rows.push(scenario("a device approved again", Row {
        row: "A device approved again: its own-device pins become the approver alone, and its next rotation can keep no other",
        client: "as stated",
        server: "none",
        layer: &["flow"],
        given: obj(vec![("own_device_pins", arr(vec![s("B"), s("C")]))]),
        steps: vec![step("B approves N", "pull", w.approval("B approves N again", "P", 2, dev_n, dev_b, &trust(vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())], vec![pv(2, "P PK2 under av 2")])), "own-device pins: B alone", "none")],
    }));
    rows.push(scenario(
        "a device approved again after a lock or a lost anchor",
        Row {
            row: "A device approved again after a lock or a lost anchor",
            client: "new key device id; old keys kept until it applies",
            server: "applied",
            layer: &["flow", "server"],
            given: obj(vec![
                ("device", s("N, locked")),
                ("old_key_device", s(&dev_n.key_device.to_wire())),
            ]),
            steps: vec![step(
                "B approves N",
                "push change set",
                w.approval(
                    "B approves N under a new key device",
                    "P",
                    2,
                    &device("P device N approved again"),
                    dev_b,
                    &trust(
                        vec![pin(&w.p, 2, PinHow::Compared, false, Vec::new())],
                        vec![pv(2, "P PK2 under av 2")],
                    ),
                ),
                "new key device id",
                "applied",
            )],
        },
    ));
    rows
}

fn set_verify(record: &mut JsonValue, name: &str, value: JsonValue) {
    if let JsonValue::Object(members) = record
        && let Some((_, JsonValue::Object(verify))) = members.iter_mut().find(|(member, _)| member == "verify")
    {
        match verify.iter_mut().find(|(member, _)| member == name) {
            Some((_, existing)) => *existing = value,
            None => verify.push((name.to_owned(), value)),
        }
    }
}

// The version records the approval rows' trust plaintexts name, by label; `record` is each one's digest.
const LABELLED_VERSIONS: [&str; 9] = [
    "P PK1",
    "P PK2",
    "P PK2 under av 2",
    "P PK3 held",
    "P PK3 other",
    "P PK3 under av 1",
    "P PK2 under av 1",
    "team 6",
    "team 8 by M",
];

fn labelled_version(w: &World<'_>, label: &str) -> (JsonValue, [u8; 32]) {
    let personal = |version: u32| KeyRef {
        owner: w.p.id.0,
        purpose: KeyPurpose::Personal,
        version: v(version),
    };
    let record = match label {
        "P PK1" => w.version(
            label,
            personal(1),
            Start::Over,
            &personal_key("P", 1),
            "P",
            1,
            &w.p.at(1).ask,
        ),
        "P PK2" | "P PK2 under av 2" => w.version(
            label,
            personal(2),
            Start::Next,
            &personal_key("P", 2),
            "P",
            2,
            &w.p.at(2).ask,
        ),
        "P PK3 held" => w.version(
            label,
            personal(3),
            Start::Next,
            &personal_key("P", 3),
            "P",
            2,
            &w.p.at(2).ask,
        ),
        "P PK3 other" => w.version(
            label,
            personal(3),
            Start::Next,
            &personal_key("P other", 3),
            "P",
            2,
            &w.p.at(2).ask,
        ),
        "P PK3 under av 1" => w.version(
            label,
            personal(3),
            Start::Next,
            &personal_key("P old", 3),
            "P",
            1,
            &w.p.at(1).ask,
        ),
        "P PK2 under av 1" => w.version(
            label,
            personal(2),
            Start::Next,
            &personal_key("P old", 2),
            "P",
            1,
            &w.p.at(1).ask,
        ),
        "team 6" => w.team_version(label, 6, Start::Next, "A", 2),
        _ => w.team_version(label, 8, Start::Next, "M", 2),
    };
    let mut verify = In::of(&record).sub("verify");
    let digest = verify.hex32("digest_hex");
    (record, digest)
}

// Every device a scenario names, under its fixture name; its keys are drawn from the name.
const DEVICES: [&str; 9] = [
    "A device 1",
    "A lost device",
    "M device 1",
    "O device 1",
    "P device B",
    "P device C",
    "P device C again",
    "P device N",
    "P device N approved again",
];

fn world_json(w: &World<'_>) -> JsonValue {
    let person = |p: &Person| {
        obj(vec![
            ("name", s(p.name)),
            ("account", s(&p.id.to_wire())),
            ("r_hex", h(p.r.expose())),
            ("ik_hex", h(&p.ik.public().expect("public").0)),
            (
                "account_keys",
                arr(p
                    .keys
                    .iter()
                    .enumerate()
                    .map(|(index, keys)| {
                        obj(vec![
                            ("av", n(index as u64 + 1)),
                            ("ask_seed_hex", h(keys.ask.expose())),
                            ("ask_hex", h(&keys.ask.public().expect("public").0)),
                            ("aek_secret_hex", h(keys.aek.expose())),
                            ("aek_hex", h(&keys.aek.public().expect("public").0)),
                        ])
                    })
                    .collect()),
            ),
        ])
    };
    let team_keys = arr((1..=9)
        .map(|version| {
            obj(vec![
                ("version", n(u64::from(version))),
                ("key_hex", h(team_key(version).expose())),
            ])
        })
        .collect());
    obj(vec![
        (
            "accounts",
            arr(vec![
                person(&w.a),
                person(&w.m),
                person(&w.e),
                person(&w.o),
                person(&w.p),
                person(&w.p_other),
            ]),
        ),
        (
            "devices",
            arr(DEVICES
                .iter()
                .map(|name| {
                    let keys = device(name);
                    obj(vec![
                        ("name", s(name)),
                        ("key_device", s(&keys.key_device.to_wire())),
                        ("dek_secret_hex", h(keys.dek.expose())),
                        ("dek_hex", h(&keys.dek.public().expect("public").0)),
                        ("dsk_seed_hex", h(keys.dsk.expose())),
                        ("dsk_hex", h(&keys.dsk.public().expect("public").0)),
                    ])
                })
                .collect()),
        ),
        ("team", s(&uuid_to_wire(w.team))),
        ("team_keys", team_keys),
        (
            "roles",
            s(
                "A admin, O owner, M member, E editor, P member; B, C and N are P's devices. \"P from C\" is P's account as device C's own genesis made it, with its own R, IK and keys",
            ),
        ),
        (
            "version_records",
            arr(LABELLED_VERSIONS
                .iter()
                .map(|label| labelled_version(w, label).0)
                .collect()),
        ),
    ])
}

// Checks every record of a scenario, in its steps and in `given`: it parses, every signature its
// `verify` names holds, and every ring, blob and wrap opens to what it should. The outcomes the
// rows declare are the flows' and the server's to check.
pub(super) fn check(_file: &str, case: &JsonValue) {
    let mut members = Members::of(case).expect("case");
    let name = members.string("name").expect("name").to_owned();
    let mut records = Vec::new();
    collect_records(members.required("steps").expect("steps"), &mut records);
    collect_records(members.required("given").expect("given"), &mut records);
    for record in records {
        check_record(&name, record);
    }
}

fn collect_records<'a>(value: &'a JsonValue, out: &mut Vec<&'a JsonValue>) {
    match value {
        JsonValue::Object(members) => {
            let has = |name: &str| members.iter().any(|(member, _)| member == name);
            if has("kind") && has("id") && has("fields") && has("verify") {
                out.push(value);
            } else {
                members.iter().for_each(|(_, member)| collect_records(member, out));
            }
        }
        JsonValue::Array(items) => items.iter().for_each(|item| collect_records(item, out)),
        _ => {}
    }
}

#[expect(clippy::too_many_lines, reason = "one arm per key kind")]
fn check_record(name: &str, record: &JsonValue) {
    let mut input = In::of(record);
    let label = input.str("label").to_owned();
    let kind = input.str("kind").to_owned();
    let id = input.str("id").to_owned();
    let fields = input.value("fields").to_json();
    let object =
        KeyObject::parse(&kind, &id, fields.as_bytes()).unwrap_or_else(|error| panic!("{name}: {label}: {error:?}"));
    let mut verify = input.sub("verify");
    let valid = !matches!(verify.optional("valid"), Some(JsonValue::Bool(false)));
    let o = origin();
    let certificate_keys = |verify: &mut In<'_>| crate::keys::AccountPublicKeys {
        ask: Ed25519Public(verify.hex32("certificate_ask_hex")),
        aek: X25519Public(verify.hex32("certificate_aek_hex")),
    };
    let result: Result<(), crate::KeysError> = match (&object.id, &object.body) {
        (
            KeyRecordId::Account { account, av } | KeyRecordId::Member { account, av },
            KeyBody::Account(body) | KeyBody::Member(body),
        ) => {
            let certificate = body.certificate(*account, *av);
            certificate.verify(&o).and_then(|()| {
                if verify.has("previous_ik_hex") {
                    certificate
                        .ik_change(&o, &Ed25519Public(verify.hex32("previous_ik_hex")))
                        .map(|_| ())
                } else {
                    Ok(())
                }
            })
        }
        (
            KeyRecordId::Device {
                account,
                key_device,
                av,
            },
            KeyBody::Device(body),
        ) => body
            .certificate(*account, *key_device, *av)
            .verify(&o, &Ed25519Public(verify.hex32("signer_hex"))),
        (KeyRecordId::Version(_), KeyBody::Version(_)) => {
            let record = object.version_record().expect("version");
            let signed = record.verify(&o, &Ed25519Public(verify.hex32("signer_hex")));
            if signed.is_ok() {
                assert_eq!(
                    record.digest(&o).expect("digest"),
                    verify.hex32("digest_hex"),
                    "{name}: {label}"
                );
            }
            signed
        }
        (KeyRecordId::Wrap(target), KeyBody::Wrap(_)) => {
            let wrap = object.wrap().expect("wrap");
            let pk_r = X25519Public(verify.hex32("pk_r_hex"));
            let signer = Ed25519Public(verify.hex32("signer_hex"));
            let secret = X25519Secret::from_bytes(verify.hex32("recipient_secret_hex"));
            wrap.verify(&o, &pk_r, &signer).and_then(|()| match target.purpose {
                WrapPurpose::Account => wrap
                    .open_account(&o, &secret, &pk_r, &signer, &certificate_keys(&mut verify))
                    .map(|_| ()),
                WrapPurpose::Trust => wrap.open_trust(&o, &secret, &pk_r, &signer).map(|_| ()),
                WrapPurpose::Key(purpose) => {
                    let key = KeyRef {
                        owner: target.owner,
                        purpose,
                        version: target.version,
                    };
                    let record = kid_record(key, verify.hex32("kid_hex"));
                    wrap.open_scope_key(&o, &secret, &pk_r, &signer, &record).map(|_| ())
                }
            })
        }
        (KeyRecordId::Ring(key), KeyBody::Ring(ring)) => {
            let below = KeyRef {
                version: key.version.previous().expect("below"),
                ..*key
            };
            ring.open(
                &o,
                *key,
                &ScopeKey::from_bytes(verify.hex32("newer_key_hex")),
                &kid_record(below, verify.hex32("below_kid_hex")),
            )
            .map(|_| ())
        }
        (KeyRecordId::Recovery { account, av }, KeyBody::Recovery(blob)) => {
            let r = RecoveryKey::from_bytes(verify.hex32("r_hex"));
            let keys = certificate_keys(&mut verify);
            r.open_blob(&o, *account, *av, blob)
                .and_then(|opened| opened.check_against(&keys.ask, &keys.aek))
        }
        (KeyRecordId::Reset { account, .. }, KeyBody::Reset(reset)) => {
            let certificate = reset.account.certificate(*account, reset.av);
            let r = RecoveryKey::from_bytes(verify.hex32("r_hex"));
            certificate
                .verify(&o)
                .and_then(|()| {
                    let ik = r.identity_seed(&o, *account)?.public()?;
                    if ik == certificate.ik {
                        Ok(())
                    } else {
                        Err(crate::KeysError::Signature)
                    }
                })
                .and_then(|()| {
                    reset
                        .device
                        .certificate(*account, reset.key_device, reset.av)
                        .verify(&o, &certificate.ask)
                })
                .and_then(|()| r.open_blob(&o, *account, reset.av, &reset.recovery))
                .and_then(|opened| opened.check_against(&certificate.ask, &certificate.aek))
        }
        (KeyRecordId::Cancel { account, .. }, KeyBody::Cancel { sig }) => match sig {
            Some(sig) => crate::cert::verify_cancel(
                &o,
                *account,
                verify.version("reset_av"),
                &Ed25519Public(verify.hex32("proposed_ik_hex")),
                sig,
                &Ed25519Public(verify.hex32("ik_hex")),
            ),
            // A device's own cancel carries no signature; the server checks who sends it.
            None => Ok(()),
        },
        (KeyRecordId::Request { request }, KeyBody::Request(body)) => {
            let transcript = crate::sas::Transcript {
                origin: o.clone(),
                account: AccountId(input_owner(record)),
                request: *request,
                ik: Ed25519Public(verify.hex32("ik_hex")),
            };
            let n = crate::sas::SasDevice {
                key_device: body.key_device,
                dek: body.dek,
                dsk: body.dsk,
            };
            transcript.check_commitment(&n, &verify.hex32("r_n_hex"), &body.commit)
        }
        (KeyRecordId::Sas { request, .. }, KeyBody::Sas(SasBody::Reveal { r })) => {
            let transcript = crate::sas::Transcript {
                origin: o.clone(),
                account: AccountId(input_owner(record)),
                request: *request,
                ik: Ed25519Public(verify.hex32("ik_hex")),
            };
            let n = crate::sas::SasDevice {
                key_device: crate::encoding::KeyDeviceId::from_wire(verify.str("n_key_device")).expect("id"),
                dek: X25519Public(verify.hex32("n_dek_hex")),
                dsk: Ed25519Public(verify.hex32("n_dsk_hex")),
            };
            transcript.check_commitment(&n, r, &verify.hex32("commit_hex"))
        }
        // A `nonce` step's r_A and a `cancel` step's reason have nothing to check but their form.
        (KeyRecordId::Sas { .. }, KeyBody::Sas(_)) => Ok(()),
        _ => panic!("{name}: {label}: a kind the checker does not know"),
    };
    if valid {
        result.unwrap_or_else(|error| panic!("{name}: {label}: {error:?}"));
    } else {
        assert!(result.is_err(), "{name}: {label} should not verify");
    }
}

// A record's owner, from its scope.
fn input_owner(record: &JsonValue) -> uuid::Uuid {
    let mut input = In::of(record);
    let mut scope = input.sub("scope");
    uuid_from_wire(scope.str("owner")).expect("owner")
}

// A version record standing in for the one a key is checked against: only its key and `kid` count.
fn kid_record(key: KeyRef, kid: [u8; 32]) -> VersionRecord {
    VersionRecord {
        key,
        start: Start::Next,
        kid: crate::keys::Kid(kid),
        signer: AccountId(uuid::Uuid::nil()),
        signer_av: v(1),
        sig: crate::keys::Signature([0; 64]),
    }
}
