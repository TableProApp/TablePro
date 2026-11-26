use async_trait::async_trait;
use tablepro_keys::encoding::{AccountId, Origin, ResetId, Version};
use zeroize::Zeroizing;

use super::ids::{DeviceRowId, StateName};

// The device's own secret store (0056, Device stores; 0054, Integrity and freshness): Keychain items that do not sync,
// Credential Manager with local machine persistence, a Secret Service item. Never synced or exported. Each call may
// block, so the core makes it off the runtime's workers. A device without one holds no keys and syncs team plaintext
// records only.
#[async_trait]
pub trait HostDeviceStore: Send + Sync {
    async fn load(&self, item: DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError>;

    async fn store(&self, item: DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError>;

    // Deleting an item that is not there succeeds.
    async fn delete(&self, item: DeviceItem) -> Result<(), DeviceStoreError>;
}

// One item. The value's format is the flow's that writes it; the store keeps bytes.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum DeviceItem {
    // The device keys of one (origin, account, device row): DSK, DEK and the key device id, and while an approval is
    // in flight the new ones beside the old (0056, Keys). They outlive sessions and resume on the same row.
    DeviceKeys {
        origin: Origin,
        account: AccountId,
        device_row: DeviceRowId,
    },
    // ASK and AEK at one `av`, kept while a scope key is still wrapped to that AEK.
    AccountKeys {
        origin: Origin,
        account: AccountId,
        av: Version,
    },
    // A reset this device proposed: its new account and device keys, until it activates or ends (0054, `key_pending`).
    ResetKeys {
        origin: Origin,
        account: AccountId,
        reset: ResetId,
    },
    // 32 random bytes per state file, in the anchor's class.
    StateMacKey {
        state: StateName,
    },
    // The anchor's root: the file id, the current entry and at most one pending entry. Named by the state file's
    // name, not its file id, so an anchor with no file is still found (0054, On open).
    AnchorRoot {
        state: StateName,
    },
    // One numbered part of a checkpoint the root names by its digest; Windows splits one over items of 2,560 bytes.
    AnchorCheckpoint {
        state: StateName,
        checkpoint: [u8; 32],
        part: u32,
    },
}

impl DeviceItem {
    pub const fn class(&self) -> DeviceItemClass {
        match self {
            Self::DeviceKeys { .. } | Self::AccountKeys { .. } | Self::ResetKeys { .. } => DeviceItemClass::Keys,
            Self::StateMacKey { .. } | Self::AnchorRoot { .. } | Self::AnchorCheckpoint { .. } => {
                DeviceItemClass::Anchor
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DeviceItemClass {
    // This device only, never in a backup that restores elsewhere: Apple's `ThisDeviceOnly` classes.
    Keys,
    // Not restored by a backup even to the same device: Apple's `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`,
    // which reads only while the device is unlocked and goes when the passcode is turned off.
    Anchor,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum DeviceStoreError {
    // No store, as a Linux session without Secret Service.
    #[error("the device store is unavailable: {detail}")]
    Unavailable { detail: String },
    // The device is locked, so an anchor item cannot be read; a pass that starts locked waits.
    #[error("the device store is locked")]
    Locked,
    #[error("the device store failed: {detail}")]
    Failed { detail: String },
}

impl DeviceStoreError {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::Unavailable { .. } => "sync.device_store.unavailable",
            Self::Locked => "sync.device_store.locked",
            Self::Failed { .. } => "sync.device_store.failed",
        }
    }
}
