// Rotation, Removing a device and Recovery (0056, Account flows): nothing rotates before R is typed, a rotation keeps
// only own-device pins, and a recovery from zero devices carries the old keys into its rings.

use secrecy::SecretString;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Start};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{AccountFlows, DeviceFlows, KeyState, LockCause, ResetKind};
use tablepro_sync::api::transport::TransportError;
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, approve, new_account, owned_team, personal_key, propose_reset, stored, stored_in_team};

// A rotation from `device` that keeps no other device, as a removal of every other device would.
pub async fn rotate_keeping_only_self(device: &Device, recovery: &SecretString) {
    let review = device
        .service
        .begin_removal(recovery.clone(), Vec::new())
        .await
        .unwrap();
    device
        .service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap();
}

async fn key_device(device: &Device) -> KeyDeviceId {
    device.service.device_keys().await.unwrap().current.unwrap().key_device
}

fn other_recovery_key() -> SecretString {
    RecoveryKey::generate().unwrap().to_text().unwrap()
}

#[tokio::test]
async fn removing_a_device_keeps_the_compared_ones_and_leaves_the_lost_one_out() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let c = Device::new(&server, account, "dev_c").await;
    approve(&c, &a).await;
    let (b_device, c_device) = (key_device(&b).await, key_device(&c).await);
    server.set_step_up(&a.row, true);
    a.service.remove_device_row(c.row.clone()).await.unwrap();

    let review = a.service.begin_removal(r.clone(), vec![c_device]).await.unwrap();
    let defaults: Vec<(KeyDeviceId, bool)> = review
        .devices
        .iter()
        .map(|device| (device.device.key_device, device.keep_by_default))
        .collect();
    a.service
        .finish_removal(review.review, vec![b_device], Vec::new())
        .await
        .unwrap();
    a.server_approves().await;
    b.pull().await;

    assert!(defaults.contains(&(b_device, true)));
    assert!(defaults.contains(&(c_device, false)));
    assert_eq!(a.av().await, 2);
    assert_eq!(b.av().await, 2);
    let left_out = KeyRecordId::Device {
        account,
        key_device: c_device,
        av: tablepro_keys::encoding::Version::new(2).unwrap(),
    };
    assert!(stored(&server, account, "key.device", &left_out.to_wire()).is_none());
    assert_eq!(
        c.service.device_keys().await.unwrap().current.unwrap().key_device,
        c_device
    );
}

#[tokio::test]
async fn a_device_left_out_of_a_rotation_locks_and_keeps_its_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let before = key_device(&b).await;

    rotate_keeping_only_self(&a, &r).await;
    b.pull().await;

    assert_eq!(
        b.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
    assert_eq!(key_device(&b).await, before);
}

#[tokio::test]
async fn a_rotation_that_keeps_a_device_this_one_never_compared_is_keys_not_compared() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let c = Device::new(&server, account, "dev_c").await;
    approve(&c, &a).await;
    let c_device = key_device(&c).await;

    let review = b.service.begin_removal(r, Vec::new()).await.unwrap();
    let error = b
        .service
        .finish_removal(review.review, vec![c_device], Vec::new())
        .await
        .unwrap_err();

    assert_eq!(error.code(), "keys.not_compared");
    assert_eq!(b.av().await, 1);
}

#[tokio::test]
async fn another_account_s_recovery_key_is_keys_signature_and_bad_text_is_keys_recovery_key() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;

    let wrong = a
        .service
        .begin_removal(other_recovery_key(), Vec::new())
        .await
        .unwrap_err();
    let garbled = a
        .service
        .begin_removal(SecretString::from("0000-1111".to_owned()), Vec::new())
        .await
        .unwrap_err();

    assert_eq!(wrong.code(), "keys.signature");
    assert_eq!(garbled.code(), "keys.recovery_key");
}

#[tokio::test]
async fn removing_a_row_needs_a_fresh_step_up() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;

    let error = a.service.remove_device_row(b.row.clone()).await.unwrap_err();

    assert_eq!(error.code(), "sync.step_up_required");
}

#[tokio::test]
async fn a_lost_device_cannot_be_kept() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let b_device = key_device(&b).await;

    let review = a.service.begin_removal(r, vec![b_device]).await.unwrap();
    let error = a
        .service
        .finish_removal(review.review, vec![b_device], Vec::new())
        .await
        .unwrap_err();

    assert_eq!(error.code(), "sync.not_allowed");
}

#[tokio::test]
async fn recovery_from_zero_devices_carries_the_old_keys_into_the_new_rings() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let a_v1 = personal_key(&a, 1).await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;

    d.service.recover(r).await.unwrap();
    d.server_approves().await;
    d.pull().await;
    a.pull().await;

    assert_eq!(d.av().await, 2);
    for purpose in [KeyPurpose::Personal, KeyPurpose::History] {
        let key = KeyRef {
            owner: account.0,
            purpose,
            version: tablepro_keys::encoding::Version::new(2).unwrap(),
        };
        let version = stored(&server, account, "key.version", &KeyRecordId::Version(key).to_wire()).unwrap();
        assert_eq!(version.version_record().unwrap().start, Start::Next);
        assert!(stored(&server, account, "key.ring", &KeyRecordId::Ring(key).to_wire()).is_some());
    }
    assert!(d.device_pins().await.is_empty());
    assert_eq!(personal_key(&d, 1).await, a_v1, "v1 opens down the new ring");
    assert_eq!(
        a.key_state().await,
        KeyState::Locked {
            cause: LockCause::LeftOutOfRotation
        }
    );
}

#[tokio::test]
async fn recovery_with_another_recovery_key_is_keys_signature_and_changes_nothing() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;

    let error = d.service.recover(other_recovery_key()).await.unwrap_err();

    assert_eq!(error.code(), "keys.signature");
    assert!(d.service.device_keys().await.unwrap().pending.is_none());
    assert_eq!(a.av().await, 1);
}

#[tokio::test]
async fn an_approved_device_does_not_recover() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;

    let error = a.service.recover(r).await.unwrap_err();

    assert_eq!(error.code(), "sync.not_allowed");
}

#[tokio::test]
async fn a_rotation_ends_a_pending_reset_that_proposed_the_same_av() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let proposed = propose_reset(&b, ResetKind::KeepScopeKeys).await;
    a.pull().await;

    rotate_keeping_only_self(&a, &r).await;
    b.pull().await;
    server.advance_clock(7 * 24 * 3600 * 1_000_000);
    let activation = tablepro_sync::api::key_flows::ResetFlows::activate_reset(&b.service, proposed.reset).await;

    let superseded = Some(tablepro_sync::api::key_flows::ResetState::Superseded);
    assert_eq!(a.pending_reset_state().await, superseded);
    assert_eq!(b.pending_reset_state().await, superseded);
    assert_eq!(
        activation.unwrap_err(),
        SyncError::Rejected {
            code: tablepro_sync::api::transport::RejectedCode::BadStatement
        }
    );
    assert!(b.service.reset_keys(proposed.reset).await.unwrap().is_none());
}

#[tokio::test]
async fn a_rotation_the_server_did_not_answer_goes_up_again_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });

    let review = a.service.begin_removal(r, Vec::new()).await.unwrap();
    let error = a
        .service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();
    a.server_approves().await;

    assert!(matches!(error, SyncError::Transport(TransportError::Network { .. })));
    assert_eq!(a.av().await, 2);
}

// A recovery copies the new certificate into every team of the account, whether or not this device holds the team's
// key yet (0056, Rotation step 3; Teams, Certificates in the team).
#[tokio::test]
async fn a_recovery_copies_the_new_certificate_into_each_team() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.join_team(team, &[(account, tablepro_sync::api::scopes::Role::Owner)])
        .await;

    d.service.recover(r).await.unwrap();
    d.server_approves().await;
    d.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    let member = KeyRecordId::Member {
        account,
        av: tablepro_keys::encoding::Version::new(2).unwrap(),
    };
    assert!(stored_in_team(&server, team, "key.member", &member.to_wire()));
}

#[tokio::test]
async fn a_removal_rotates_each_team_this_account_holds() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;

    rotate_keeping_only_self(&a, &r).await;

    let version = KeyRecordId::Version(KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: tablepro_keys::encoding::Version::new(2).unwrap(),
    });
    assert!(stored_in_team(&server, team, "key.version", &version.to_wire()));
}

#[tokio::test]
async fn a_recovery_whose_answer_was_lost_goes_up_again_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire.lose_next_answer();

    let lost = d.service.recover(r).await.unwrap_err();
    d.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();
    d.server_approves().await;

    assert!(matches!(lost, SyncError::Transport(TransportError::Network { .. })));
    assert_eq!(d.av().await, 2);
}

// A's own rotation never went up and B's won the `av`: A follows B's and writes none of its own team steps.
#[tokio::test]
async fn a_rotation_another_device_won_runs_no_team_step_of_this_one() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let (a_device, b_device) = (key_device(&a).await, key_device(&b).await);
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let review = a.service.begin_removal(r.clone(), Vec::new()).await.unwrap();
    a.service
        .finish_removal(review.review, vec![b_device], Vec::new())
        .await
        .unwrap_err();

    let review = b.service.begin_removal(r, Vec::new()).await.unwrap();
    b.service
        .finish_removal(review.review, vec![a_device], Vec::new())
        .await
        .unwrap();
    b.server_approves().await;
    a.pull().await;
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    assert_eq!(a.av().await, 2);
    let version = KeyRecordId::Version(KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: tablepro_keys::encoding::Version::new(2).unwrap(),
    });
    assert!(!stored_in_team(&server, team, "key.version", &version.to_wire()));
}

// A removal whose answer was lost applied on the server. Asked again, the device sends the same objects first, finds
// them applied, and starts no second rotation that would stand in for it.
#[tokio::test]
async fn a_removal_after_one_whose_answer_was_lost_sends_that_one_again_first() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    a.wire.lose_next_answer();
    let review = a.service.begin_removal(r.clone(), Vec::new()).await.unwrap();
    a.service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    let first = a.wire.last_push_by_id();

    let review = a.service.begin_removal(r, Vec::new()).await.unwrap();
    let again = a
        .service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    let second = a.wire.last_push_by_id();
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    assert_eq!(again.code(), "sync.not_allowed");
    assert_eq!(first, second);
    assert_eq!(a.av().await, 2);
}

#[tokio::test]
async fn a_recovery_asked_again_after_a_lost_answer_sends_the_first_one_again() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire.lose_next_answer();
    d.service.recover(r.clone()).await.unwrap_err();
    let first = d.wire.last_push_by_id();

    d.service.recover(r).await.unwrap();
    let second = d.wire.last_push_by_id();
    d.server_approves().await;

    assert_eq!(first, second);
    assert_eq!(d.av().await, 2);
}

// Replace names no certificate of its own in its pending flow. A certificate of the server's at that `av`, which locks
// the device, is never adopted as this device's rotation.
#[tokio::test]
async fn a_server_certificate_at_a_pending_rotation_s_av_is_never_adopted() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let ik = a.pin(account).await.unwrap().ik;
    crate::harness::put_rows(
        &a,
        vec![tablepro_sync::api::state::Row::KeyPending(
            tablepro_sync::api::state::KeyPendingRow {
                flow: tablepro_sync::api::state::PendingFlow::AccountRotation {
                    av: tablepro_keys::encoding::Version::new(2).unwrap(),
                },
                state: Vec::new(),
            },
        )],
    )
    .await;
    let foreign = crate::harness::foreign_certificate(account, 2);
    a.service
        .apply_account_objects(crate::harness::arrival(vec![crate::harness::served(&foreign)]))
        .await
        .unwrap();

    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    let pin = a.pin(account).await.unwrap();
    assert_eq!((pin.ik, pin.av.get()), (ik, 1));
    assert!(!pin.replaced.contains(&ik));
}

// A team rotation whose answer was lost goes up again and meets `create_only` on its own version: the step is met.
#[tokio::test]
async fn a_team_step_whose_answer_was_lost_is_met_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    // The account rotation, the certificate copied into the team, then the team rotation whose answer is lost.
    a.wire.lose_answer_after(2);

    rotate_keeping_only_self(&a, &r).await;
    let pending = a
        .get(tablepro_sync::api::state::RowKey::KeyPending(
            tablepro_sync::api::state::PendingFlow::AccountRotation {
                av: tablepro_keys::encoding::Version::new(2).unwrap(),
            },
        ))
        .await;
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    assert!(pending.is_some());
    assert!(
        a.get(tablepro_sync::api::state::RowKey::KeyPending(
            tablepro_sync::api::state::PendingFlow::AccountRotation {
                av: tablepro_keys::encoding::Version::new(2).unwrap(),
            },
        ))
        .await
        .is_none()
    );
    let version = |number: u32| {
        KeyRecordId::Version(KeyRef {
            owner: team.0,
            purpose: KeyPurpose::Team,
            version: tablepro_keys::encoding::Version::new(number).unwrap(),
        })
        .to_wire()
    };
    assert!(stored_in_team(&server, team, "key.version", &version(2)));
    assert!(!stored_in_team(&server, team, "key.version", &version(3)));
}

// The removal applied, its answer was lost and a pull followed it: on resume the removed device is no longer pinned,
// so no later rotation can keep it.
#[tokio::test]
async fn a_removal_followed_by_pull_after_a_lost_answer_still_drops_the_removed_device_s_pin() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let b_device = key_device(&b).await;
    a.wire.lose_next_answer();
    let review = a.service.begin_removal(r, vec![b_device]).await.unwrap();
    a.service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    a.pull().await;

    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    assert!(!a.device_pins().await.iter().any(|pin| pin.key_device == b_device));
    assert_eq!(a.av().await, 2);
}

// A file with no anchor trusts nothing it holds: a device recovered with R starts with no pins of other accounts.
#[tokio::test]
async fn an_unanchored_device_recovered_with_r_starts_with_no_other_pins() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let other = new_account();
    crate::harness::put_rows(
        &b,
        vec![tablepro_sync::api::state::Row::KeyPin(
            tablepro_sync::api::state::KeyPinRow {
                account: other,
                ik: tablepro_keys::keys::Ed25519Public([7; 32]),
                av: tablepro_keys::encoding::Version::FIRST,
                how: tablepro_keys::trust::PinHow::Compared,
                alert: false,
                replaced: Vec::new(),
            },
        )],
    )
    .await;
    let b = b
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Unanchored,
        ))
        .await;

    b.service.recover(r).await.unwrap();
    b.server_approves().await;

    assert!(b.pin(other).await.is_none());
    assert_eq!(b.av().await, 2);
}

#[tokio::test]
async fn a_recovery_of_a_stopped_device_resumes_its_personal_scope() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let key = tablepro_sync::api::state::RowKey::KeyVersion(
        tablepro_sync::api::ids::ScopeName::Personal,
        KeyPurpose::Personal,
    );
    let Some(tablepro_sync::api::state::Row::KeyVersion(mut row)) = b.get(key).await else {
        unreachable!("no personal key row")
    };
    row.stop(tablepro_sync::api::state::StoppedCause::CatchUp);
    crate::harness::put_rows(&b, vec![tablepro_sync::api::state::Row::KeyVersion(row)]).await;

    b.service.recover(r).await.unwrap();

    assert!(
        b.hooks
            .calls()
            .contains(&tablepro_sync_testing::key_flows::HookCall::Resume(
                tablepro_sync::api::ids::ScopeName::Personal
            ))
    );
}

// A refused recovery leaves no copy of the account keys R opened.
#[tokio::test]
async fn a_refused_recovery_keeps_no_account_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire
        .refuse_next_push(tablepro_sync::api::transport::RejectedCode::BadStatement);

    d.service.recover(r).await.unwrap_err();

    let opened = tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: tablepro_keys::encoding::Version::FIRST,
    };
    assert!(!d.store.inner.holds(&opened));
}
