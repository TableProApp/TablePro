// Rotation, Removing a device and Recovery (0056, Account flows): nothing rotates before R is typed, a rotation keeps
// only own-device pins, and a recovery from zero devices carries the old keys into its rings.

use secrecy::SecretString;
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{KeyRef, Start};
use tablepro_sync::api::error::SyncError;
use tablepro_sync::api::key_flows::{DeviceFlows, KeyState, LockCause, ResetKind};
use tablepro_sync::api::transport::TransportError;
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, approve, new_account, propose_reset, stored};

// A rotation from `device` that keeps no other device, as a removal of every other device would.
pub async fn rotate_keeping_only_self(device: &Device, recovery: &SecretString) {
    let review = device.service.begin_removal(recovery.clone(), Vec::new()).await.unwrap();
    device.service.finish_removal(review.review, Vec::new(), Vec::new()).await.unwrap();
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
    a.service.finish_removal(review.review, vec![b_device], Vec::new()).await.unwrap();
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
    assert_eq!(c.service.device_keys().await.unwrap().current.unwrap().key_device, c_device);
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
    let error = b.service.finish_removal(review.review, vec![c_device], Vec::new()).await.unwrap_err();

    assert_eq!(error.code(), "keys.not_compared");
    assert_eq!(b.av().await, 1);
}

#[tokio::test]
async fn another_account_s_recovery_key_is_keys_signature_and_bad_text_is_keys_recovery_key() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    a.genesis().await;

    let wrong = a.service.begin_removal(other_recovery_key(), Vec::new()).await.unwrap_err();
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
    let error = a.service.finish_removal(review.review, vec![b_device], Vec::new()).await.unwrap_err();

    assert_eq!(error.code(), "sync.not_allowed");
}

#[tokio::test]
async fn recovery_from_zero_devices_carries_the_old_keys_into_the_new_rings() {
    let server = FakeServer::new();
    let account = new_account();
    let a = Device::new(&server, account, "dev_a").await;
    let r = a.genesis().await;
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
    propose_reset(&b, ResetKind::KeepScopeKeys).await;
    a.pull().await;

    rotate_keeping_only_self(&a, &r).await;

    assert_eq!(
        a.pending_reset_state().await,
        Some(tablepro_sync::api::key_flows::ResetState::Superseded)
    );
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
    let error = a.service.finish_removal(review.review, Vec::new(), Vec::new()).await.unwrap_err();
    a.service
        .resume_rotation(tablepro_keys::encoding::Version::new(2).unwrap())
        .await
        .unwrap();
    a.server_approves().await;

    assert!(matches!(error, SyncError::Transport(TransportError::Network { .. })));
    assert_eq!(a.av().await, 2);
}
