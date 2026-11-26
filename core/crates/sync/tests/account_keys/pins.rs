// Pins and fingerprints (0056, Pins): first use, following, a replace with a notice, an alert on any other change,
// re-confirming bound to the IK shown, and an IK seen replaced never coming back.

use tablepro_keys::body::{AccountBody, KeyBody, KeyObject};
use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{AccountId, TeamId, Version, random_uuid};
use tablepro_keys::fingerprint::{fingerprint, fingerprint_words, qr_text};
use tablepro_keys::keys::{AccountKeys, Ed25519Public, Ed25519Seed};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::trust::{PinHow, Replaced};
use tablepro_sync::api::ids::{KindName, ScopeName};
use tablepro_sync::api::key_flows::{Acceptance, AccountFlows, KeyNoticeKind};
use tablepro_sync::api::state::{KeyObjectRow, KeyPinRow, Row, RowKey};
use tablepro_sync::keys::{IkStanding, PinChange};
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, new_account, origin};
use crate::vectors::fixture;

fn av(value: u32) -> Version {
    Version::new(value).unwrap()
}

fn team() -> ScopeName {
    ScopeName::Team(TeamId(random_uuid().unwrap()))
}

struct Member {
    account: AccountId,
    ik: Ed25519Seed,
}

impl Member {
    fn new() -> Self {
        Self {
            account: new_account(),
            ik: Ed25519Seed::generate().unwrap(),
        }
    }

    fn certificate(&self, at: u32) -> AccountCertificate {
        AccountCertificate::sign(
            &origin(),
            self.account,
            av(at),
            CertKind::GenesisOrRotation,
            &self.ik,
            AccountKeys::generate().unwrap().public().unwrap(),
            None,
        )
        .unwrap()
    }

    // A replace to `next` at `at`, endorsed by this member's IK.
    fn replace(&self, at: u32, next: &Ed25519Seed) -> AccountCertificate {
        AccountCertificate::sign(
            &origin(),
            self.account,
            av(at),
            CertKind::Replace,
            next,
            AccountKeys::generate().unwrap().public().unwrap(),
            Some(&self.ik),
        )
        .unwrap()
    }
}

fn member_row(scope: ScopeName, certificate: &AccountCertificate) -> Row {
    let object = KeyObject {
        id: KeyRecordId::Member {
            account: certificate.account,
            av: certificate.av,
        },
        body: KeyBody::Member(AccountBody::of(certificate)),
    };
    Row::KeyObject(KeyObjectRow {
        scope,
        kind: KindName::parse("key.member").unwrap(),
        record_id: object.id.to_wire(),
        fields: object.fields_json(),
        applied: true,
        served: None,
    })
}

async fn device() -> Device {
    let server = FakeServer::new();
    let device = Device::new(&server, new_account(), "dev_b").await;
    device.genesis().await;
    device
}

async fn offer(device: &Device, scope: ScopeName, certificate: &AccountCertificate) -> Result<PinChange, String> {
    device.put(vec![member_row(scope, certificate)]).await;
    let mut txn = device.txn().await;
    let change = device.service.offer_certificate(txn.as_mut(), scope, certificate).await;
    txn.commit().await.unwrap();
    change.map_err(|error| error.code().to_owned())
}

#[tokio::test]
async fn a_teammate_is_pinned_on_first_use_then_followed_silently_at_a_higher_av() {
    let device = device().await;
    let scope = team();
    let member = Member::new();

    assert_eq!(
        offer(&device, scope, &member.certificate(1)).await,
        Ok(PinChange::FirstUse)
    );
    assert_eq!(
        offer(&device, scope, &member.certificate(2)).await,
        Ok(PinChange::Followed { from: av(1) })
    );

    let pin = device.pin(member.account).await.unwrap();
    assert_eq!((pin.av, pin.how, pin.alert), (av(2), PinHow::FirstUse, false));
    assert_eq!(
        offer(&device, scope, &member.certificate(1)).await,
        Ok(PinChange::Unchanged)
    );
    assert_eq!(device.pin(member.account).await.unwrap().av, av(2));
    assert!(device.service.notices().await.unwrap().is_empty());
}

#[tokio::test]
async fn a_replace_the_pinned_ik_endorsed_is_followed_with_a_notice_and_the_old_ik_never_returns() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let next = Ed25519Seed::generate().unwrap();

    let change = offer(&device, scope, &member.replace(2, &next)).await;

    let old = member.ik.public().unwrap();
    assert_eq!(change, Ok(PinChange::Replaced { previous: old }));
    let pin = device.pin(member.account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.how, pin.replaced.clone()),
        (
            next.public().unwrap(),
            PinHow::Replaced,
            vec![Replaced { ik: old, av: av(2) }]
        )
    );
    assert!(device.service.notices().await.unwrap().iter().any(|notice| notice.kind
        == KeyNoticeKind::RecoveryKeyReplaced {
            account: member.account
        }));
    assert_eq!(
        offer(&device, scope, &member.certificate(3)).await,
        Err("keys.retired_ik".to_owned())
    );
    // The certificate under the retired IK still verifies what was signed before the replace.
    let mut txn = device.txn().await;
    let standing = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(1))
        .await
        .unwrap();
    assert_eq!(standing, IkStanding::Replaced);
}

#[tokio::test]
async fn an_unendorsed_change_opens_an_alert_that_re_confirming_closes_only_for_the_ik_shown() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let reset = Member {
        account: member.account,
        ik: Ed25519Seed::generate().unwrap(),
    };

    assert_eq!(offer(&device, scope, &reset.certificate(2)).await, Ok(PinChange::Alert));

    let pin = device.pin(member.account).await.unwrap();
    assert!(pin.alert);
    assert_eq!(pin.ik, member.ik.public().unwrap());
    let change = device.service.key_change(member.account).await.unwrap().unwrap();
    assert_eq!(change.offered_ik, reset.ik.public().unwrap());
    assert_eq!(change.offered.words.len(), 6);
    assert_ne!(change.offered, change.pinned);
    assert!(device.service.notices().await.unwrap().iter().any(|notice| notice.kind
        == KeyNoticeKind::KeysChanged {
            account: member.account
        }));
    let someone_else = Ed25519Seed::generate().unwrap().public().unwrap();
    let refused = device
        .service
        .accept_key_change(member.account, someone_else, Acceptance::Compared)
        .await
        .unwrap_err();
    assert_eq!(refused.code(), "sync.unknown");

    device
        .service
        .accept_key_change(member.account, reset.ik.public().unwrap(), Acceptance::WithoutComparing)
        .await
        .unwrap();

    let pin = device.pin(member.account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.av, pin.how, pin.alert, pin.replaced.clone()),
        (
            reset.ik.public().unwrap(),
            av(2),
            PinHow::FirstUse,
            false,
            vec![Replaced {
                ik: member.ik.public().unwrap(),
                av: av(2)
            }]
        )
    );
    assert!(device.service.key_change(member.account).await.unwrap().is_none());
    assert_eq!(
        offer(&device, scope, &member.certificate(3)).await,
        Err("keys.retired_ik".to_owned())
    );
}

#[tokio::test]
async fn a_certificate_under_another_ik_below_the_pin_and_a_gap_are_refused_or_held() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(2)).await.unwrap();
    let stranger = Member {
        account: member.account,
        ik: Ed25519Seed::generate().unwrap(),
    };

    let mut txn = device.txn().await;
    let below = device
        .service
        .verify_certificate(txn.as_mut(), scope, &stranger.certificate(1))
        .await
        .unwrap_err();
    let gap = device
        .service
        .certificate_at(txn.as_mut(), scope, member.account, av(4))
        .await
        .unwrap();
    drop(txn);

    assert_eq!(below.code(), "keys.signature");
    assert!(gap.is_none());
    assert_eq!(
        offer(&device, scope, &member.certificate(4)).await,
        Err("keys.step".to_owned())
    );
}

#[tokio::test]
async fn the_vectors_ik_changes_move_a_pin_as_their_rows_say() {
    let device = device().await;
    let scope = team();
    for case in fixture()["certificates"].as_array().unwrap() {
        if case["op"] != "verify_account_certificate" {
            continue;
        }
        let input = &case["input"];
        let record = &input["record"];
        let id = record["id"].as_str().unwrap();
        let object = KeyObject::parse("key.account", id, record["fields"].to_string().as_bytes()).unwrap();
        let KeyRecordId::Account { account, av: at } = object.id else {
            panic!()
        };
        let KeyBody::Account(body) = object.body else { panic!() };
        let certificate = body.certificate(account, at);
        let previous = input["previous_ik_hex"].as_str().map_or(certificate.ik, |text| {
            Ed25519Public(hex::decode(text).unwrap().try_into().unwrap())
        });
        let mut txn = device.txn().await;
        match at.previous() {
            Some(below) => txn
                .put(Row::KeyPin(KeyPinRow {
                    account,
                    ik: previous,
                    av: below,
                    how: PinHow::Compared,
                    alert: false,
                    replaced: Vec::new(),
                }))
                .await
                .unwrap(),
            None => txn.delete(&RowKey::KeyPin(account)).await.unwrap(),
        }
        txn.commit().await.unwrap();

        let change = offer(&device, scope, &certificate).await;

        let expected = match (case["error"].as_str(), certificate.ik == previous) {
            (Some("keys.unendorsed"), _) => Ok(PinChange::Alert),
            (Some(code), _) => Err(code.to_owned()),
            (None, true) => Ok(PinChange::Followed {
                from: at.previous().unwrap(),
            }),
            (None, false) => Ok(PinChange::Replaced { previous }),
        };
        assert_eq!(change, expected, "{}", case["name"]);
    }
}

#[tokio::test]
async fn fingerprints_are_six_words_and_a_qr_code_a_scan_of_which_counts_as_a_comparison() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let digest = fingerprint(&origin(), member.account, &member.ik.public().unwrap()).unwrap();

    let words = device.service.fingerprint(member.account).await.unwrap();

    assert_eq!(words.words, fingerprint_words(&digest));
    assert_eq!(words.qr, qr_text(&digest));
    assert!(words.qr.starts_with("TPF1:"));
    let own = device.service.own_fingerprint().await.unwrap();
    assert_ne!(own, words);
    assert!(!device.service.compare_qr(member.account, own.qr).await.unwrap());
    assert_eq!(device.pin(member.account).await.unwrap().how, PinHow::FirstUse);
    assert!(device.service.compare_qr(member.account, words.qr).await.unwrap());
    assert_eq!(device.pin(member.account).await.unwrap().how, PinHow::Compared);
    assert_eq!(
        device
            .service
            .compare_qr(member.account, "TPF1:not-base32".to_owned())
            .await
            .unwrap_err()
            .code(),
        "keys.encoding"
    );
    assert_eq!(
        device.service.fingerprint(new_account()).await.unwrap_err().code(),
        "sync.unknown"
    );
}

#[tokio::test]
async fn the_own_account_moves_only_through_the_personal_scope_never_a_team_s_copy() {
    let server = FakeServer::new();
    let account = new_account();
    let b = Device::new(&server, account, "dev_b").await;
    let c = Device::new(&server, account, "dev_c").await;
    let text = b.genesis().await;
    c.approved_by(&b).await;
    let c_device = c.service.device_keys().await.unwrap().current.unwrap().key_device;
    b.pull().await;
    let draft = b.service.begin_replace(text).await.unwrap();
    b.service
        .finish_replace(
            draft.recovery.draft,
            crate::harness::typed_back(&draft.recovery),
            vec![c_device],
        )
        .await
        .unwrap();
    let KeyBody::Account(body) =
        crate::harness::stored(&server, account, "key.account", &format!("{}/2", account.to_wire())).body
    else {
        panic!()
    };
    let rotated = body.certificate(account, av(2));
    let scope = team();

    // A team pulled before the personal scope shows the account's own new certificate first.
    let change = offer(&c, scope, &rotated).await;

    assert_eq!(change, Ok(PinChange::Unchanged));
    assert_eq!(c.pin(account).await.unwrap().av, Version::FIRST);
    c.pull().await;
    assert_eq!(
        c.key_state().await,
        tablepro_sync::api::key_flows::KeyState::Approved {
            av: av(2),
            key_device: c_device
        }
    );
}

#[tokio::test]
async fn an_alert_after_an_endorsed_replace_keeps_the_replace_it_followed() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let second = Ed25519Seed::generate().unwrap();
    device.put(vec![member_row(scope, &member.replace(2, &second))]).await;
    let reset = Member {
        account: member.account,
        ik: Ed25519Seed::generate().unwrap(),
    };

    let change = offer(&device, scope, &reset.certificate(3)).await;

    assert_eq!(change, Ok(PinChange::Alert));
    let pin = device.pin(member.account).await.unwrap();
    assert_eq!(
        (pin.ik, pin.av, pin.how, pin.alert, pin.replaced),
        (
            second.public().unwrap(),
            av(2),
            PinHow::Replaced,
            true,
            vec![Replaced {
                ik: member.ik.public().unwrap(),
                av: av(2)
            }]
        )
    );
}

#[tokio::test]
async fn an_ik_seen_replaced_verifies_only_certificates_older_than_the_pin() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let next = Ed25519Seed::generate().unwrap();
    offer(&device, scope, &member.replace(2, &next)).await.unwrap();
    let mut txn = device.txn().await;

    let older = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(1))
        .await
        .unwrap();
    let newer = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(3))
        .await
        .unwrap_err();

    assert_eq!(older, IkStanding::Replaced);
    assert_eq!(newer.code(), "keys.retired_ik");
}

#[tokio::test]
async fn a_certificate_under_a_replaced_ik_counts_only_below_the_av_of_its_replace() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let next = Member {
        account: member.account,
        ik: Ed25519Seed::generate().unwrap(),
    };
    offer(&device, scope, &member.replace(2, &next.ik)).await.unwrap();
    offer(&device, scope, &next.certificate(3)).await.unwrap();
    offer(&device, scope, &next.certificate(4)).await.unwrap();
    let mut txn = device.txn().await;

    let before = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(1))
        .await
        .unwrap();
    let after = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(3))
        .await
        .unwrap_err();

    assert_eq!(before, IkStanding::Replaced);
    assert_eq!(after.code(), "keys.retired_ik");
}

// 0066, Replace points: an approver's trust names the replace at `av` 3, and the server withholds that certificate,
// serving one the old IK signed at 3 under a recovery key it kept, then the new IK at 4.
#[tokio::test]
async fn a_replace_point_holds_whatever_certificates_the_server_serves_around_it() {
    let device = device().await;
    let scope = team();
    let old = Member::new();
    let next = Member {
        account: old.account,
        ik: Ed25519Seed::generate().unwrap(),
    };
    device
        .put(vec![
            Row::KeyPin(KeyPinRow {
                account: old.account,
                ik: next.ik.public().unwrap(),
                av: av(4),
                how: PinHow::Replaced,
                alert: false,
                replaced: vec![Replaced {
                    ik: old.ik.public().unwrap(),
                    av: av(3),
                }],
            }),
            member_row(scope, &old.certificate(3)),
            member_row(scope, &next.certificate(4)),
        ])
        .await;
    let mut txn = device.txn().await;

    let forged = device
        .service
        .verify_certificate(txn.as_mut(), scope, &old.certificate(3))
        .await;
    let history = device
        .service
        .verify_certificate(txn.as_mut(), scope, &old.certificate(2))
        .await;

    assert_eq!(forged.unwrap_err().code(), "keys.retired_ik");
    assert_eq!(history.unwrap(), IkStanding::Replaced);
}

// An accepted alert has no replace certificate: the old IK's point is the `av` after the one this device pinned under
// it, so a certificate the old IK signed later never verifies, however far the accepted one stands (orchestrator
// ruling on 0066, Replace points).
#[tokio::test]
async fn an_accepted_alert_retires_the_old_ik_just_past_what_the_device_pinned() {
    let device = device().await;
    let scope = team();
    let member = Member::new();
    offer(&device, scope, &member.certificate(1)).await.unwrap();
    let reset = Member {
        account: member.account,
        ik: Ed25519Seed::generate().unwrap(),
    };
    device.put(vec![member_row(scope, &reset.certificate(2))]).await;
    assert_eq!(offer(&device, scope, &reset.certificate(3)).await, Ok(PinChange::Alert));

    device
        .service
        .accept_key_change(member.account, reset.ik.public().unwrap(), Acceptance::Compared)
        .await
        .unwrap();
    let pin = device.pin(member.account).await.unwrap();
    let mut txn = device.txn().await;
    let later = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(2))
        .await;
    let pinned = device
        .service
        .verify_certificate(txn.as_mut(), scope, &member.certificate(1))
        .await;

    assert_eq!((pin.ik, pin.av), (reset.ik.public().unwrap(), av(3)));
    assert_eq!(
        pin.replaced,
        vec![Replaced {
            ik: member.ik.public().unwrap(),
            av: av(2)
        }]
    );
    assert_eq!(later.unwrap_err().code(), "keys.retired_ik");
    assert_eq!(pinned.unwrap(), IkStanding::Replaced);
}
