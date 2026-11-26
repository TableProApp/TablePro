// The key and sync digests and the state MAC over them (0054, Integrity): the framing written out by hand, vectors for
// the key tables' encodings, and the file's own MAC computed again from its rows.

use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, RequestId, TeamId, Version};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::{Role as ComparisonRole, SessionState};
use tablepro_keys::state_mac::{StateSnapshot, state_mac};
use tablepro_keys::trust::{PinHow, Replaced};
use tablepro_records::Kind;
use tablepro_records::limits::MAX_RECORD_BYTES;
use tablepro_sync::api::device_store::{DeviceItem, HostDeviceStore};
use tablepro_sync::api::ids::{ChangeTag, EpochId, KindName, RecordKey, ScopeName};
use tablepro_sync::api::state::{
    BaseRow, DeletedHistoryRow, Holder, KeyComparisonRow, KeyDevicePinRow, KeyEnvelopeRow, KeyObjectRow, KeyPendingRow,
    KeyPinRow, KeyVersionRow, KeyVersionState, PendingFlow, Provider, Row, RowKey, Served, StoppedCause,
};
use tablepro_sync::state::integrity::{key_digest, sync_digest};
use tablepro_sync::state::state_name;
use uuid::Uuid;
use zeroize::Zeroizing;

use super::support::{Disk, account, every_row, identity, origin, put};

fn v(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn id(n: u128) -> AccountId {
    AccountId(Uuid::from_u128(n))
}

fn ik(byte: u8) -> Ed25519Public {
    Ed25519Public([byte; 32])
}

fn value(bytes: &[u8]) -> Vec<u8> {
    let mut out = vec![1];
    out.extend_from_slice(&u32::try_from(bytes.len()).unwrap().to_be_bytes());
    out.extend_from_slice(bytes);
    out
}

fn framed(name: &str, count: u32) -> Vec<u8> {
    [
        &u32::try_from(name.len()).unwrap().to_be_bytes()[..],
        name.as_bytes(),
        &count.to_be_bytes(),
    ]
    .concat()
}

fn sha256(bytes: &[u8]) -> [u8; 32] {
    use sha2::Digest;
    sha2::Sha256::digest(bytes).into()
}

fn version_row(purpose: KeyPurpose) -> KeyVersionRow {
    KeyVersionRow {
        scope: ScopeName::Personal,
        purpose,
        version: v(1),
        record: [0xab; 32],
        holders: Vec::new(),
        state: KeyVersionState::Ok,
        stopped_cause: None,
        epoch: None,
    }
}

#[test]
fn the_key_digest_frames_each_table_its_rows_and_their_values_as_0054_writes_them() {
    let rows = vec![
        Row::DeletedHistory(DeletedHistoryRow {
            record_id: "A".to_owned(),
        }),
        Row::KeyVersion(version_row(KeyPurpose::Personal)),
        Row::KeyObject(KeyObjectRow {
            scope: ScopeName::Personal,
            kind: KindName::of(Kind::KeyReset),
            record_id: "R".to_owned(),
            fields: "{}".to_owned(),
            applied: true,
            served: Some(Served {
                taken_at_us: 7,
                held_until_us: Some(9),
            }),
        }),
        Row::KeyPin(KeyPinRow {
            account: id(1),
            ik: ik(2),
            av: v(3),
            how: PinHow::Replaced,
            alert: false,
            replaced: vec![Replaced { ik: ik(1), av: v(3) }],
        }),
    ];
    let mut input = Vec::new();
    for name in [
        "key_objects",
        "key_pins",
        "key_device_pins",
        "key_versions",
        "key_envelopes",
        "key_comparisons",
        "key_pending",
        "deleted_history",
    ] {
        match name {
            "key_objects" => {
                input.extend(framed(name, 1));
                input.extend(value(b"personal"));
                input.extend(value(b"key.reset"));
                input.extend(value(b"R"));
                input.extend(value(b"{}"));
                input.extend(value(&1_u64.to_be_bytes()));
                // `served`: `taken_at`, then `held_until`, 8 bytes big-endian each (0066).
                input.extend(value(&[7_i64.to_be_bytes(), 9_i64.to_be_bytes()].concat()));
            }
            "key_pins" => {
                input.extend(framed(name, 1));
                input.extend(value(id(1).0.as_bytes()));
                input.extend(value(&[2; 32]));
                input.extend(value(&3_u64.to_be_bytes()));
                input.extend(value(b"replaced"));
                input.extend(value(&0_u64.to_be_bytes()));
                // Each replaced entry: the IK's 32 bytes, then the replace `av` as a `u32` big-endian (0066).
                input.extend(value(&[&[1; 32][..], &3_u32.to_be_bytes()].concat()));
            }
            "key_versions" => {
                input.extend(framed(name, 1));
                input.extend(value(b"personal"));
                input.extend(value(b"personal"));
                input.extend(value(&1_u64.to_be_bytes()));
                input.extend(value(&[0xab; 32]));
                input.extend(value(&0_u32.to_be_bytes()));
                input.extend(value(b"ok"));
                // `stopped_cause` and `epoch` are null: one zero byte each.
                input.extend([0, 0]);
            }
            "deleted_history" => {
                input.extend(framed(name, 1));
                input.extend(value(b"A"));
            }
            _ => input.extend(framed(name, 0)),
        }
    }

    assert_eq!(key_digest(Provider::Service, &rows), sha256(&input));
    // An iCloud file has no key tables, so its key digest covers none.
    assert_eq!(key_digest(Provider::ICloud, &rows), sha256(&[]));
}

#[test]
fn rows_go_in_by_the_byte_order_of_their_encoded_keys_whatever_order_they_come_in() {
    let pins: Vec<Row> = [3_u128, 1, 2]
        .into_iter()
        .map(|n| {
            Row::KeyPin(KeyPinRow {
                account: id(n),
                ik: ik(1),
                av: v(1),
                how: PinHow::FirstUse,
                alert: false,
                replaced: Vec::new(),
            })
        })
        .collect();
    let mut reversed = pins.clone();
    reversed.reverse();

    assert_eq!(
        key_digest(Provider::Service, &pins),
        key_digest(Provider::Service, &reversed)
    );
    assert_ne!(
        key_digest(Provider::Service, &pins),
        key_digest(Provider::Service, &pins[..2])
    );
}

fn team() -> ScopeName {
    ScopeName::Team(TeamId(Uuid::from_u128(0x7e)))
}

fn team_row(holders: Vec<Holder>, state: KeyVersionState, cause: Option<StoppedCause>) -> Row {
    Row::KeyVersion(KeyVersionRow {
        scope: team(),
        purpose: KeyPurpose::Team,
        version: v(4),
        record: [0x44; 32],
        holders,
        state,
        stopped_cause: cause,
        epoch: None,
    })
}

fn pin(account: AccountId, ik: Ed25519Public, av: u32, how: PinHow, alert: bool, replaced: Vec<Replaced>) -> Row {
    Row::KeyPin(KeyPinRow {
        account,
        ik,
        av: v(av),
        how,
        alert,
        replaced,
    })
}

fn hex(bytes: [u8; 32]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

// One case of the key digest vectors: its name, the key tables of one file, and their digest.
type Case = (&'static str, Vec<Row>, &'static str);

fn retired(byte: u8, av: u32) -> Replaced {
    Replaced {
        ik: ik(byte),
        av: v(av),
    }
}

fn table_cases() -> Vec<Case> {
    vec![
        (
            "a null and an empty value",
            vec![
                Row::KeyVersion(version_row(KeyPurpose::History)),
                Row::KeyPending(KeyPendingRow {
                    flow: PendingFlow::AccountRotation { av: v(2) },
                    state: Vec::new(),
                }),
                Row::KeyComparison(KeyComparisonRow {
                    session: RequestId(Uuid::from_u128(0x5e)),
                    role: ComparisonRole::Approver,
                    peer: vec![1, 2],
                    view: Vec::new(),
                    state: SessionState::Open,
                    expires_at_us: -1,
                }),
                Row::KeyDevicePin(KeyDevicePinRow {
                    key_device: KeyDeviceId(Uuid::from_u128(0xd)),
                    dek: X25519Public([0xde; 32]),
                    dsk: Ed25519Public([0xd5; 32]),
                }),
                Row::KeyEnvelope(KeyEnvelopeRow {
                    scope: ScopeName::Personal,
                    record_id: "connection/A/password".to_owned(),
                    kv: v(1),
                }),
            ],
            "d3f2ccc8b5ad01c59dc8fe9a22c58c8647e53aabe35bf3ade87e3f151f3140e5",
        ),
        (
            "a key object at the record limit",
            vec![Row::KeyObject(KeyObjectRow {
                scope: ScopeName::Personal,
                kind: KindName::of(Kind::KeyRecovery),
                record_id: format!("{}/1", account().to_wire()),
                fields: format!("{{\"q\":\"{}\"}}", "a".repeat(MAX_RECORD_BYTES - 8)),
                applied: true,
                served: None,
            })],
            "9bb99af21cafadcaa38b239ed09febadc5e5dfce184f2a529a746dce8b965aec",
        ),
    ]
}

fn holder_cases() -> Vec<Case> {
    let a = id(0xa);
    let b = id(0xb);
    let holds = |byte: u8| {
        vec![Holder {
            account: a,
            ik: ik(byte),
        }]
    };
    vec![
        (
            "holders in order",
            vec![team_row(
                vec![Holder { account: a, ik: ik(1) }, Holder { account: b, ik: ik(2) }],
                KeyVersionState::Ok,
                None,
            )],
            "667072113e34259d1641f839e9969f3114ae6b0ebf3db301b66956c35d14db49",
        ),
        (
            "holders empty",
            vec![team_row(Vec::new(), KeyVersionState::Ok, None)],
            "6f307887c5294d72785f8f3a0a1f027434b97b164e624ad30cd842804d60cc60",
        ),
        (
            "holders after one endorsed replacement",
            vec![
                team_row(holds(1), KeyVersionState::Ok, None),
                pin(a, ik(2), 2, PinHow::FirstUse, false, vec![retired(1, 2)]),
            ],
            "20f6b84a3c15de74ec2ba13caef84083dc3a86382e4b2f36ec3a42a1cb8dd242",
        ),
        (
            "holders after two endorsed replacements during a stop",
            vec![
                team_row(holds(1), KeyVersionState::Stopped, Some(StoppedCause::CatchUp)),
                pin(a, ik(3), 3, PinHow::FirstUse, false, vec![retired(1, 2), retired(2, 3)]),
            ],
            "54ed04f5871a6a7d09922f5da7fc6128dcbe67decedb0b1fe3e26eee93eab982",
        ),
        (
            "holders after a reset during a stop",
            vec![
                team_row(holds(1), KeyVersionState::Stopped, Some(StoppedCause::RestartHeld)),
                pin(a, ik(9), 3, PinHow::FirstUse, true, Vec::new()),
            ],
            "fac60a2ce6ffa01f0ca16e7f95cb8144adc46a661b03f1a8c379b56d18b6ebdc",
        ),
    ]
}

// Vectors for the key digest (0054, Verification). Each case is the key tables of one file.
#[test]
fn key_digest_vectors() {
    let cases: Vec<Case> = table_cases().into_iter().chain(holder_cases()).collect();

    let digests: Vec<(&str, String)> = cases
        .iter()
        .map(|(name, rows, _)| (*name, hex(key_digest(Provider::Service, rows))))
        .collect();
    let expected: Vec<(&str, String)> = cases
        .iter()
        .map(|(name, _, digest)| (*name, (*digest).to_owned()))
        .collect();

    assert_eq!(digests, expected);
}

fn base(record: &str, tag: &str) -> Row {
    Row::Base(BaseRow {
        key: RecordKey::new(ScopeName::Personal, Kind::Connection, record),
        tag: ChangeTag::Service(tag.to_owned()),
        version: Some(1),
        revision: Some(1),
        epoch: Some(EpochId(Uuid::from_u128(1))),
        deleted: None,
        fields: None,
        created_ms: None,
    })
}

#[tokio::test]
async fn writing_the_mac_changes_neither_digest_and_the_file_s_mac_is_over_its_rows() {
    let disk = Disk::new();
    let state = disk.open().await;
    put(
        &state,
        vec![
            base("A", "t1"),
            Row::KeyEnvelope(KeyEnvelopeRow {
                scope: ScopeName::Personal,
                record_id: "connection/A/password".to_owned(),
                kv: v(2),
            }),
        ],
    )
    .await;
    let rows = every_row(&state).await;
    let Some(Row::Binding(binding)) = rows.iter().find(|row| matches!(row, Row::Binding(_))).cloned() else {
        panic!("no binding row");
    };
    let mut remacked = rows.clone();
    for row in &mut remacked {
        if let Row::Binding(binding) = row {
            binding.state_mac = [0x99; 32];
        }
    }
    let key = disk
        .store
        .load(DeviceItem::StateMacKey {
            state: state_name(&identity()),
        })
        .await
        .unwrap()
        .unwrap();
    let key = Zeroizing::new(<[u8; 32]>::try_from(key.as_slice()).unwrap());
    let key_digest = key_digest(Provider::Service, &rows);
    let sync_digest = sync_digest(&rows);
    let snapshot = StateSnapshot {
        file_id: &binding.file_id.0,
        counter: binding.counter,
        key_digest: &key_digest,
        sync_digest: &sync_digest,
    };

    assert_eq!(sync_digest, tablepro_sync::state::integrity::sync_digest(&remacked));
    assert_eq!(
        key_digest,
        tablepro_sync::state::integrity::key_digest(Provider::Service, &remacked)
    );
    assert_eq!(
        state_mac(&key, &origin(), account(), snapshot).unwrap(),
        binding.state_mac
    );
    assert!(matches!(
        state.begin().await.unwrap().get(&RowKey::Binding).await.unwrap(),
        Some(Row::Binding(held)) if held.counter == binding.counter
    ));
}
