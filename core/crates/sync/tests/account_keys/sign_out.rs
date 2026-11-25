use tablepro_keys::encoding::{ResetId, Version, random_uuid};
use tablepro_keys::keys::{AccountKeys, DeviceKeys};
use tablepro_sync::api::device_store::DeviceItem;
use tablepro_sync::api::ids::ScopeName;
use tablepro_sync::api::key_flows::{AccountFlows, KeyState, SignOutOutcome};
use tablepro_sync::api::state::{KeyPendingRow, PendingFlow, Row, RowKey, RowRange, Table};
use tablepro_sync::api::transport::TransportError;
use tablepro_sync::keys::ResetKeys;
use tablepro_sync_testing::FakeServer;

use crate::harness::{Device, new_account, origin};

async fn key_rows(device: &Device) -> usize {
    let mut txn = device.txn().await;
    let mut count = 0;
    for table in Table::KEY {
        count += txn.scan(&RowRange::Table(table)).await.unwrap().len();
    }
    count
}

#[tokio::test]
async fn sign_out_revokes_under_this_device_s_key_then_erases_every_key_and_rotates_nothing() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    let dsk = device
        .service
        .device_keys()
        .await
        .unwrap()
        .current
        .unwrap()
        .dsk
        .public()
        .unwrap();
    let horizon = server.horizon(tablepro_sync_testing::service::ScopeOwner::Personal(account));
    assert!(server.is_approved(&device.row));

    let outcome = device.service.sign_out().await.unwrap();

    assert_eq!(outcome, SignOutOutcome::Revoked);
    assert_eq!(*device.transport.revokes.lock().unwrap(), vec![dsk]);
    assert!(!server.is_approved(&device.row));
    assert_eq!(
        horizon,
        server.horizon(tablepro_sync_testing::service::ScopeOwner::Personal(account))
    );
    assert_eq!(key_rows(&device).await, 0);
    assert!(device.store.is_empty());
    let Some(Row::Scope(row)) = device.get(RowKey::Scope(ScopeName::Personal)).await else {
        panic!("the scope row stays");
    };
    assert!(row.cursor.is_none() && row.key_version.is_none() && !row.caught_up);
    // Signing in again on the row is a new device: new keys, a new key device id, and an approval.
    device.pull().await;
    assert_eq!(device.key_state().await, KeyState::NeedsApproval { request: None });
    let again = device.service.device_keys().await.unwrap().current.unwrap();
    assert_ne!(again.dsk.public().unwrap(), dsk);
}

#[tokio::test]
async fn sign_out_offline_erases_anyway_and_the_row_keeps_its_certificate() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    server.fail_next(TransportError::Network {
        detail: "offline".to_owned(),
    });

    let outcome = device.service.sign_out().await.unwrap();

    assert_eq!(outcome, SignOutOutcome::ErasedOffline);
    assert!(server.is_approved(&device.row));
    assert_eq!(key_rows(&device).await, 0);
    assert!(device.store.is_empty());
}

#[tokio::test]
async fn sign_out_on_a_removed_row_erases_and_counts_as_revoked() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    server.remove_row(&device.row);

    let outcome = device.service.sign_out().await.unwrap();

    assert_eq!(outcome, SignOutOutcome::Revoked);
    assert!(device.store.is_empty());
}

#[tokio::test]
async fn sign_out_also_proves_with_the_dsk_of_a_reset_it_proposed_so_the_reset_ends() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    let reset = ResetId(random_uuid().unwrap());
    let proposal = ResetKeys {
        account: AccountKeys::generate().unwrap(),
        device: DeviceKeys::generate().unwrap(),
    };
    let reset_dsk = proposal.device.dsk.public().unwrap();
    device.service.store_reset_keys(reset, &proposal).await.unwrap();
    device
        .put(vec![Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::ResetProposal { reset },
            state: Vec::new(),
        })])
        .await;
    let own_dsk = device
        .service
        .device_keys()
        .await
        .unwrap()
        .current
        .unwrap()
        .dsk
        .public()
        .unwrap();

    device.service.sign_out().await.unwrap();

    assert_eq!(*device.transport.revokes.lock().unwrap(), vec![own_dsk, reset_dsk]);
    assert!(!device.store.holds(&DeviceItem::ResetKeys {
        origin: origin(),
        account,
        reset,
    }));
    assert!(device.store.is_empty());
}

#[tokio::test]
async fn a_reset_proposed_under_this_device_s_own_dsk_is_revoked_once() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    let reset = ResetId(random_uuid().unwrap());
    let own = device.service.device_keys().await.unwrap().current.unwrap();
    device
        .service
        .store_reset_keys(
            reset,
            &ResetKeys {
                account: AccountKeys::generate().unwrap(),
                device: own.clone(),
            },
        )
        .await
        .unwrap();
    device
        .put(vec![Row::KeyPending(KeyPendingRow {
            flow: PendingFlow::ResetProposal { reset },
            state: Vec::new(),
        })])
        .await;

    device.service.sign_out().await.unwrap();

    assert_eq!(
        *device.transport.revokes.lock().unwrap(),
        vec![own.dsk.public().unwrap()]
    );
}

#[tokio::test]
async fn sign_out_erases_the_account_keys_of_every_version_it_held() {
    let server = FakeServer::new();
    let account = new_account();
    let device = Device::new(&server, account, "dev_b").await;
    device.genesis().await;
    let older = AccountKeys::generate().unwrap();
    device
        .service
        .store_account_keys(Version::new(2).unwrap(), &older)
        .await
        .unwrap();
    device
        .put(vec![Row::KeyPin(tablepro_sync::api::state::KeyPinRow {
            av: Version::new(2).unwrap(),
            ..device.pin(account).await.unwrap()
        })])
        .await;

    device.service.sign_out().await.unwrap();

    assert!(device.store.is_empty());
}
