// Rotation, Removing a device and Recovery (0056, Account flows): nothing rotates before R is typed, a rotation keeps
// only own-device pins, and a recovery from zero devices carries the old keys into its rings.

use secrecy::SecretString;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::scope_key::{KeyRef, Start};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{AccountFlows, DeviceFlows, KeyState, LockCause, ResetKind, TeamFlows};
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

async fn refilling(device: &Device, team: tablepro_keys::encoding::TeamId, refill: bool) {
    let key = tablepro_sync::api::state::RowKey::Scope(tablepro_sync::api::ids::ScopeName::Team(team));
    let mut row = device
        .get(key)
        .await
        .and_then(|row| match row {
            tablepro_sync::api::state::Row::Scope(row) => Some(row),
            _ => None,
        })
        .unwrap();
    row.refill = refill;
    let mut txn = device.txn().await;
    txn.put(tablepro_sync::api::state::Row::Scope(row)).await.unwrap();
    txn.commit().await.unwrap();
}

// While a team refills against a new epoch, no roster decides for it: the removal's team step waits for a later pass
// instead of failing the removal, and rotates the team once the epoch is adopted.
#[tokio::test]
async fn a_team_step_waits_while_its_team_refills_against_a_new_epoch() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    let version = KeyRecordId::Version(KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: tablepro_keys::encoding::Version::new(2).unwrap(),
    });
    refilling(&a, team, true).await;

    rotate_keeping_only_self(&a, &r).await;
    let waited = !stored_in_team(&server, team, "key.version", &version.to_wire());
    refilling(&a, team, false).await;
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();

    assert!(waited);
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

// A team rotation whose answer was lost goes up again and meets `create_only` on its own version: once a pull brings
// that version, the step is met.
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
    // The step goes up again and meets `create_only`; after a pull of the team it finds its own version in force.
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();
    crate::harness::team_pass(&a, team).await;
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

fn rotation_row(av: u32) -> tablepro_sync::api::state::RowKey {
    tablepro_sync::api::state::RowKey::KeyPending(tablepro_sync::api::state::PendingFlow::AccountRotation {
        av: crate::harness::v(av),
    })
}

fn team_version(team: tablepro_keys::encoding::TeamId, number: u32) -> String {
    KeyRecordId::Version(KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version: crate::harness::v(number),
    })
    .to_wire()
}

// A device certificate the account's ASK did not sign is refused, never held as applied and never listed.
#[tokio::test]
async fn a_device_certificate_that_does_not_verify_is_never_applied_nor_listed() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;
    let stranger = KeyDeviceId(tablepro_keys::encoding::random_uuid().unwrap());
    let forged = crate::harness::forged_device_certificate(account, stranger, 1);

    let applied = a
        .service
        .apply_account_objects(crate::harness::arrival(vec![crate::harness::served(&forged)]))
        .await
        .unwrap();

    assert_eq!(applied.refused.len(), 1);
    assert_eq!(applied.refused[0].error.code(), "keys.signature");
    assert!(
        crate::harness::held(&a, tablepro_keys::record_id::KeyKind::Device, &forged.id.to_wire())
            .await
            .is_none()
    );
    let devices = a.service.account_devices().await.unwrap();
    assert!(!devices.iter().any(|device| device.key_device == stranger));
}

// A removal's answer was lost. A forged certificate for the removed device at the new `av`, held until the account
// certificate arrived, is refused once it does and keeps no pin of that device.
#[tokio::test]
async fn a_forged_device_certificate_at_a_removal_s_av_keeps_no_pin_of_the_removed_device() {
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
    let forged = crate::harness::forged_device_certificate(account, b_device, 2);
    a.service
        .apply_account_objects(crate::harness::arrival(vec![crate::harness::served(&forged)]))
        .await
        .unwrap();
    a.pull().await;

    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert_eq!(a.av().await, 2);
    assert!(!a.device_pins().await.iter().any(|pin| pin.key_device == b_device));
    let devices = a.service.account_devices().await.unwrap();
    assert!(!devices.iter().any(|device| device.key_device == b_device));
}

// A replace whose push never went up loses its `av` to B's rotation. A, whose file has no anchor so no pull settles
// it, drops it on resume instead of running B's rotation as its own, team steps included.
#[tokio::test]
async fn a_replace_that_lost_to_another_device_s_rotation_settles_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let a_device = key_device(&a).await;
    a.pull().await;
    let draft = a.service.begin_replace(r.clone()).await.unwrap();
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    a.service
        .finish_replace(
            draft.recovery.draft,
            crate::harness::typed_back(&draft.recovery),
            Vec::new(),
        )
        .await
        .unwrap_err();
    let review = b.service.begin_removal(r, Vec::new()).await.unwrap();
    b.service
        .finish_removal(review.review, vec![a_device], Vec::new())
        .await
        .unwrap();
    let a = a
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Unanchored,
        ))
        .await;
    a.pull().await;

    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(a.get(rotation_row(2)).await.is_none());
    assert!(!stored_in_team(&server, team, "key.version", &team_version(team, 2)));
    let ik = a.pin(account).await.unwrap().ik;
    let b_ik = b.pin(account).await.unwrap().ik;
    assert_eq!(ik, b_ik);
}

// A's team step meets `create_only`: C, an admin of the team, rotated it before A's account rotation. A pulls the
// team and, the rotation still due, rotates it again.
#[tokio::test]
async fn a_team_step_that_meets_create_only_rotates_again_after_a_pull_while_still_due() {
    use tablepro_sync::api::scopes::Role;
    let server = FakeServer::new();
    let (account, admin) = (new_account(), new_account());
    let team = tablepro_keys::encoding::TeamId(tablepro_keys::encoding::random_uuid().unwrap());
    server.add_team(team, &[(account, Role::Owner), (admin, Role::Admin)]);
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    crate::harness::team_pass(&a, team).await;
    a.service.create_team_keys(team).await.unwrap();
    let c = Device::new(&server, admin, "dev_c").await;
    c.genesis().await;
    crate::harness::team_pass(&c, team).await;
    crate::harness::team_pass(&a, team).await;
    a.service.confirm_member(team, admin).await.unwrap();
    crate::harness::team_pass(&c, team).await;
    c.service.rotate_team(team, Vec::new()).await.unwrap();
    assert!(stored_in_team(&server, team, "key.version", &team_version(team, 2)));

    rotate_keeping_only_self(&a, &r).await;
    // The server marks the team when the account rotation applies.
    server.set_rotation_due(team, true);
    let waiting = a.get(rotation_row(2)).await;
    crate::harness::team_pass(&a, team).await;
    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(waiting.is_some());
    assert!(stored_in_team(&server, team, "key.version", &team_version(team, 3)));
    assert!(a.get(rotation_row(2)).await.is_none());
}

// A team step the server refuses is recorded and the flow carries on: removing a lost device with R still
// works afterwards (D7).
#[tokio::test]
async fn a_refused_team_step_does_not_block_the_next_removal() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    owned_team(&a).await;
    // The account rotation and the certificate copied into the team apply; the team rotation is refused.
    a.wire
        .refuse_push_after(2, tablepro_sync::api::transport::RejectedCode::Role);

    let first = a.service.begin_removal(r.clone(), Vec::new()).await.unwrap();
    let finished = a.service.finish_removal(first.review, Vec::new(), Vec::new()).await;
    a.pull().await;
    let second = a.service.begin_removal(r, Vec::new()).await.unwrap();
    let again = a.service.finish_removal(second.review, Vec::new(), Vec::new()).await;

    finished.unwrap();
    again.unwrap();
    a.pull().await;
    assert_eq!(a.av().await, 3);
}

// A's removal never went up and a certificate whose signature fails stands at its `av`: it decides nothing, and A's
// own rotation goes up on resume.
#[tokio::test]
async fn a_certificate_whose_signature_fails_never_decides_another_device_won() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let review = a.service.begin_removal(r, Vec::new()).await.unwrap();
    a.service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    let mut forged = crate::harness::foreign_certificate(account, 2);
    if let tablepro_keys::body::KeyBody::Account(body) = &mut forged.body {
        body.sig.0[0] ^= 1;
    }
    a.service
        .apply_account_objects(crate::harness::arrival(vec![crate::harness::served(&forged)]))
        .await
        .unwrap();

    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();
    a.pull().await;

    assert_eq!(a.av().await, 2);
    assert!(a.service.account_keys(crate::harness::v(2)).await.unwrap().is_some());
}

// The recovery's answer was lost and a pull followed the certificate before the resume adopted it: the stopped
// personal key moves to the recovery's version and is no longer stopped.
#[tokio::test]
async fn a_recovery_adopted_after_a_pull_clears_the_stopped_personal_rows() {
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
    let Some(tablepro_sync::api::state::Row::KeyVersion(mut row)) = b.get(key.clone()).await else {
        unreachable!("no personal key row")
    };
    row.stop(tablepro_sync::api::state::StoppedCause::CatchUp);
    crate::harness::put_rows(&b, vec![tablepro_sync::api::state::Row::KeyVersion(row)]).await;
    b.wire.lose_next_answer();

    b.service.recover(r).await.unwrap_err();
    b.pull().await;
    b.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    let Some(tablepro_sync::api::state::Row::KeyVersion(row)) = b.get(key).await else {
        unreachable!("no personal key row")
    };
    assert_eq!(row.state, tablepro_sync::api::state::KeyVersionState::Ok);
    assert_eq!(row.version.get(), 2);
}

// D's recovery never went up and A's rotation won its `av`: on resume D drops its candidates and the device keys it
// drew for the recovery.
#[tokio::test]
async fn a_recovery_another_device_won_drops_its_candidates_and_device_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    d.service.recover(r.clone()).await.unwrap_err();
    assert!(d.service.device_keys().await.unwrap().pending.is_some());
    rotate_keeping_only_self(&a, &r).await;
    d.pull().await;

    d.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(d.service.device_keys().await.unwrap().pending.is_none());
    assert!(d.get(rotation_row(2)).await.is_none());
    let candidates = d
        .rows(tablepro_sync::api::state::Table::KeyObjects)
        .await
        .into_iter()
        .filter(|row| matches!(row, tablepro_sync::api::state::Row::KeyObject(object) if !object.applied))
        .count();
    assert_eq!(candidates, 0);
}

// A recovery cut off after it drew its device keys and before its candidates were kept: the flow named them first,
// so the resume that finds nothing of the rotation drops them with the keys R opened.
#[tokio::test]
async fn a_recovery_cut_off_before_its_candidates_drops_the_device_keys_it_drew_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    // The read of R and the row that names what the flow draws land; the candidates do not.
    d.fail_commit_after(2);

    d.service.recover(r).await.unwrap_err();
    let drawn = d.service.device_keys().await.unwrap().pending.is_some();
    let named = d.get(rotation_row(2)).await.is_some();
    d.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(drawn);
    assert!(named);
    assert!(d.service.device_keys().await.unwrap().pending.is_none());
    assert!(d.get(rotation_row(2)).await.is_none());
    let opened = tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: tablepro_keys::encoding::Version::FIRST,
    };
    assert!(!d.store.inner.holds(&opened));
}

fn account_keys(account: tablepro_keys::encoding::AccountId, av: u32) -> tablepro_sync::api::device_store::DeviceItem {
    tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: crate::harness::v(av),
    }
}

// The same window leaves the account keys the rotation built at its `av` in the device store: the resume that finds
// nothing of the rotation erases them too.
#[tokio::test]
async fn a_recovery_cut_off_before_its_candidates_erases_the_account_keys_it_stored_on_resume() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.fail_commit_after(2);

    d.service.recover(r).await.unwrap_err();
    let stored = d.store.inner.holds(&account_keys(account, 2));
    d.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(stored);
    assert!(!d.store.inner.holds(&account_keys(account, 2)));
}

// The resume settles the cut-off recovery under the serial lock, so the person's retry at the same `av`, which writes
// the flow's row again and stores new keys there, waits for it and keeps what it wrote.
#[tokio::test]
async fn a_resume_settling_a_cut_off_recovery_never_erases_a_retry_at_the_same_av() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.fail_commit_after(2);
    d.service.recover(r.clone()).await.unwrap_err();
    // The retry's push goes unanswered, so its row, candidates and keys stay for the next pass.
    d.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let pause = d.pause_next_account_keys_erase();
    let retry = async {
        pause.reached().await;
        let release = async {
            for _ in 0..8 {
                tokio::task::yield_now().await;
            }
            pause.go();
        };
        tokio::join!(d.service.recover(r.clone()), release).0
    };

    let (resumed, retried) = tokio::join!(d.service.resume_rotation(crate::harness::v(2)), retry);

    resumed.unwrap();
    assert!(matches!(retried, Err(SyncError::Transport(TransportError::Network { .. }))));
    assert!(d.store.inner.holds(&account_keys(account, 2)));
    assert!(d.get(rotation_row(2)).await.is_some());
}

// The server refuses a recovery, and the device store fails to drop the device keys it drew: the row that names them
// stays, so the flow settles them again, and no drawn keys are left that nothing names.
#[tokio::test]
async fn a_refused_recovery_never_leaves_drawn_device_keys_no_flow_names() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire
        .refuse_next_push(tablepro_sync::api::transport::RejectedCode::BadStatement);
    // The drawn keys land; dropping them does not.
    d.fail_device_keys_write_after(1);

    let refused = d.service.recover(r).await;
    let pending = d.service.device_keys().await.unwrap().pending.is_some();
    let named = d.get(rotation_row(2)).await.is_some();

    assert!(refused.is_err());
    assert!(pending);
    assert!(named, "drawn device keys outlived the row that names them");
}

// The same window on a device that held the account keys R opens, so the flow had nothing else to name before it drew.
#[tokio::test]
async fn a_recovery_of_a_device_that_held_its_keys_cut_off_before_its_candidates_drops_what_it_drew() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    let b = b
        .reopen(crate::harness::opened_with(
            tablepro_sync::api::state::KeyTrust::Unanchored,
        ))
        .await;
    let current = b
        .service
        .device_keys()
        .await
        .unwrap()
        .current
        .map(|keys| keys.key_device);
    // The read of R, the key tables a file with no anchor clears and the flow's row land; the candidates do not.
    b.fail_commit_after(3);

    b.service.recover(r).await.unwrap_err();
    let drawn = b.service.device_keys().await.unwrap().pending.is_some();
    b.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(drawn);
    let held = b.service.device_keys().await.unwrap();
    assert!(held.pending.is_none());
    assert_eq!(held.current.map(|keys| keys.key_device), current);
    assert!(b.get(rotation_row(2)).await.is_none());
}

// A recovery that never went up is refused when it goes up again: the account keys R opened go too.
#[tokio::test]
async fn a_recovery_refused_on_resume_keeps_no_account_keys() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let d = Device::new(&server, account, "dev_d").await;
    d.pull().await;
    d.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    d.service.recover(r).await.unwrap_err();
    d.wire
        .refuse_next_push(tablepro_sync::api::transport::RejectedCode::BadStatement);

    let refused = d.service.resume_rotation(crate::harness::v(2)).await.unwrap_err();

    assert_eq!(
        refused,
        SyncError::Rejected {
            code: tablepro_sync::api::transport::RejectedCode::BadStatement
        }
    );
    let opened = tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: tablepro_keys::encoding::Version::FIRST,
    };
    assert!(!d.store.inner.holds(&opened));
    assert!(d.service.device_keys().await.unwrap().pending.is_none());
}

// A device asking for approval holds device keys the request needs: a recovery waits until that request ends.
#[tokio::test]
async fn a_recovery_does_not_start_while_the_device_asks_for_approval() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let n = Device::new(&server, account, "dev_n").await;
    n.pull().await;
    tablepro_sync::api::key_flows::ApprovalFlows::request_approval(&n.service)
        .await
        .unwrap();
    let asking = n.service.device_keys().await.unwrap().pending.unwrap().key_device;

    let refused = n.service.recover(r).await.unwrap_err();

    assert!(matches!(refused, SyncError::NotAllowed { .. }));
    assert_eq!(
        n.service.device_keys().await.unwrap().pending.unwrap().key_device,
        asking
    );
}

// A certificate the server signed under an IK of its own stands at a pending removal's `av`. It locks the device and
// decides nothing: the removal's keys and the review's marks stay. A device certificate there that its keys did not
// sign is refused.
#[tokio::test]
async fn a_certificate_under_an_ik_the_server_made_up_erases_nothing() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    a.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    let review = a.service.begin_removal(r, Vec::new()).await.unwrap();
    a.service
        .finish_removal(review.review, Vec::new(), Vec::new())
        .await
        .unwrap_err();
    let (foreign, _) = crate::harness::foreign_certificate_with_keys(account, 2);
    let stranger = KeyDeviceId(tablepro_keys::encoding::random_uuid().unwrap());
    let forged = crate::harness::forged_device_certificate(account, stranger, 2);
    a.service
        .apply_account_objects(crate::harness::arrival(vec![
            crate::harness::served(&foreign),
            crate::harness::served(&forged),
        ]))
        .await
        .unwrap();

    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(a.service.account_keys(crate::harness::v(2)).await.unwrap().is_some());
    assert!(a.get(rotation_row(2)).await.is_some());
    assert!(
        crate::harness::held(&a, tablepro_keys::record_id::KeyKind::Device, &forged.id.to_wire())
            .await
            .is_none()
    );
}

// A team step the server refused is tried again on the next pass, and the flow ends once it goes through.
#[tokio::test]
async fn a_refused_team_step_is_tried_again_on_the_next_pass() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let team = owned_team(&a).await;
    a.wire
        .refuse_push_after(2, tablepro_sync::api::transport::RejectedCode::BadStatement);
    rotate_keeping_only_self(&a, &r).await;
    assert!(!stored_in_team(&server, team, "key.version", &team_version(team, 2)));

    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(stored_in_team(&server, team, "key.version", &team_version(team, 2)));
    assert!(a.get(rotation_row(2)).await.is_none());
}

// After `create_only` the version in force came before this account's rotation, still wrapped to its old key: the
// team is rotated again whatever the server's `rotation_due` says.
#[tokio::test]
async fn a_version_wrapped_to_the_old_account_key_is_rotated_again_though_the_server_says_not_due() {
    use tablepro_sync::api::scopes::Role;
    let server = FakeServer::new();
    let (account, admin) = (new_account(), new_account());
    let team = tablepro_keys::encoding::TeamId(tablepro_keys::encoding::random_uuid().unwrap());
    server.add_team(team, &[(account, Role::Owner), (admin, Role::Admin)]);
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    crate::harness::team_pass(&a, team).await;
    a.service.create_team_keys(team).await.unwrap();
    let c = Device::new(&server, admin, "dev_c").await;
    c.genesis().await;
    crate::harness::team_pass(&c, team).await;
    crate::harness::team_pass(&a, team).await;
    a.service.confirm_member(team, admin).await.unwrap();
    crate::harness::team_pass(&c, team).await;
    c.service.rotate_team(team, Vec::new()).await.unwrap();

    rotate_keeping_only_self(&a, &r).await;
    server.set_rotation_due(team, false);
    crate::harness::team_pass(&a, team).await;
    a.service.resume_rotation(crate::harness::v(2)).await.unwrap();

    assert!(stored_in_team(&server, team, "key.version", &team_version(team, 3)));
}

// B, left out of A's rotation, recovers with R and its push never goes up; A rotates again first. B's next pull
// settles its recovery: the account keys R opened and the device keys it drew go.
#[tokio::test]
async fn a_pinned_device_whose_recovery_lost_drops_what_r_opened_on_its_next_pull() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
    let b = Device::new(&server, account, "dev_b").await;
    approve(&b, &a).await;
    rotate_keeping_only_self(&a, &r).await;
    b.pull().await;
    assert_eq!(b.pin(account).await.unwrap().av.get(), 2);
    b.wire.fail_next_push(TransportError::Network {
        detail: "offline".to_owned(),
    });
    b.service.recover(r.clone()).await.unwrap_err();
    rotate_keeping_only_self(&a, &r).await;

    b.pull().await;
    b.service.resume_rotation(crate::harness::v(3)).await.ok();

    assert!(b.service.device_keys().await.unwrap().pending.is_none());
    let opened = tablepro_sync::api::device_store::DeviceItem::AccountKeys {
        origin: crate::harness::origin(),
        account,
        av: crate::harness::v(2),
    };
    assert!(!b.store.inner.holds(&opened));
    assert!(b.get(rotation_row(3)).await.is_none());
}
