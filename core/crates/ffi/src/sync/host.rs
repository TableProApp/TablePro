// The app's sides of sync that only the app can do: its settings, kept its own way (0054, Adapters), and its device
// store, for the keys and the state file's anchor (0054, Integrity and freshness). Each call may block, so the core
// makes it on a blocking thread, never under a lock.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_records::Kind;
use tablepro_session::runtime::Tasks;
use tablepro_sync::api::{self as sync, AdapterError, DeviceStoreError, SettingsDocument};
use zeroize::Zeroizing;

use crate::host::HostSecretError;

#[uniffi::export(callback_interface)]
pub trait HostSettings: Send + Sync {
    // Every category that holds a value, each as one JSON document. A category the platform's registry does not name,
    // such as one a newer build wrote, comes back as it was applied, unchanged (core ADR 0066).
    fn categories(&self) -> Result<Vec<SettingsCategoryArg>, HostSecretError>;

    // None removes the category, as a deleted theme.
    fn apply(&self, category: String, document: Option<String>) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SettingsCategoryArg {
    pub category: String,
    pub document: String,
}

// Keychain items that never sync: `ThisDeviceOnly` for keys, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly` for
// the anchor (`DeviceItemClassTag`). Windows' Credential Manager and Linux's Secret Service are the core's own.
#[uniffi::export(callback_interface)]
pub trait HostDeviceStore: Send + Sync {
    fn load(&self, item: DeviceItemTag) -> Result<Option<Vec<u8>>, HostSecretError>;

    fn store(&self, item: DeviceItemTag, value: Vec<u8>) -> Result<(), HostSecretError>;

    // Deleting an item that is not there succeeds.
    fn delete(&self, item: DeviceItemTag) -> Result<(), HostSecretError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DeviceItemClassTag {
    Keys,
    Anchor,
}

// One item, named by what it holds. Ids are upper-case UUID text; a state file's name and a checkpoint are hex.
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum DeviceItemTag {
    DeviceKeys {
        origin: String,
        account: String,
        device_row: String,
    },
    AccountKeys {
        origin: String,
        account: String,
        av: u32,
    },
    ResetKeys {
        origin: String,
        account: String,
        reset: String,
    },
    StateMacKey {
        state: String,
    },
    AnchorRoot {
        state: String,
    },
    AnchorCheckpoint {
        state: String,
        checkpoint: String,
        part: u32,
    },
}

impl DeviceItemTag {
    pub(crate) fn of(item: &sync::DeviceItem) -> Self {
        use sync::DeviceItem;
        let hex = |bytes: &[u8]| bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        match item {
            DeviceItem::DeviceKeys {
                origin,
                account,
                device_row,
            } => Self::DeviceKeys {
                origin: origin.as_str().to_owned(),
                account: account.to_wire(),
                device_row: device_row.0.clone(),
            },
            DeviceItem::AccountKeys { origin, account, av } => Self::AccountKeys {
                origin: origin.as_str().to_owned(),
                account: account.to_wire(),
                av: av.get(),
            },
            DeviceItem::ResetKeys { origin, account, reset } => Self::ResetKeys {
                origin: origin.as_str().to_owned(),
                account: account.to_wire(),
                reset: reset.to_wire(),
            },
            DeviceItem::StateMacKey { state } => Self::StateMacKey { state: state.0.clone() },
            DeviceItem::AnchorRoot { state } => Self::AnchorRoot { state: state.0.clone() },
            DeviceItem::AnchorCheckpoint {
                state,
                checkpoint,
                part,
            } => Self::AnchorCheckpoint {
                state: state.0.clone(),
                checkpoint: hex(checkpoint),
                part: *part,
            },
        }
    }

    pub fn class(&self) -> DeviceItemClassTag {
        match self {
            Self::DeviceKeys { .. } | Self::AccountKeys { .. } | Self::ResetKeys { .. } => DeviceItemClassTag::Keys,
            Self::StateMacKey { .. } | Self::AnchorRoot { .. } | Self::AnchorCheckpoint { .. } => {
                DeviceItemClassTag::Anchor
            }
        }
    }
}

// Which class the host stores an item in.
#[uniffi::export]
pub fn device_item_class(item: DeviceItemTag) -> DeviceItemClassTag {
    item.class()
}

fn store_error(error: HostSecretError) -> DeviceStoreError {
    match error {
        HostSecretError::Unavailable { detail } => DeviceStoreError::Unavailable { detail },
        HostSecretError::Locked => DeviceStoreError::Locked,
        HostSecretError::Dismissed => DeviceStoreError::Failed {
            detail: "the unlock prompt was dismissed".to_owned(),
        },
        HostSecretError::Failed { detail } => DeviceStoreError::Failed { detail },
    }
}

fn failed(failure: impl std::fmt::Display) -> DeviceStoreError {
    DeviceStoreError::Failed {
        detail: failure.to_string(),
    }
}

// The host's device store under the engine's trait, each call on a blocking thread.
pub(crate) struct HostDeviceStoreBridge {
    pub(crate) host: Arc<dyn HostDeviceStore>,
    pub(crate) tasks: Tasks,
}

#[async_trait]
impl sync::HostDeviceStore for HostDeviceStoreBridge {
    async fn load(&self, item: sync::DeviceItem) -> Result<Option<Zeroizing<Vec<u8>>>, DeviceStoreError> {
        let (host, tag) = (Arc::clone(&self.host), DeviceItemTag::of(&item));
        let loaded = self
            .tasks
            .spawn_blocking_task(move || host.load(tag))
            .await
            .map_err(failed)?;
        loaded.map(|value| value.map(Zeroizing::new)).map_err(store_error)
    }

    async fn store(&self, item: sync::DeviceItem, value: Zeroizing<Vec<u8>>) -> Result<(), DeviceStoreError> {
        let (host, tag) = (Arc::clone(&self.host), DeviceItemTag::of(&item));
        let value = value.to_vec();
        let stored = self
            .tasks
            .spawn_blocking_task(move || host.store(tag, value))
            .await
            .map_err(failed)?;
        stored.map_err(store_error)
    }

    async fn delete(&self, item: sync::DeviceItem) -> Result<(), DeviceStoreError> {
        let (host, tag) = (Arc::clone(&self.host), DeviceItemTag::of(&item));
        let deleted = self
            .tasks
            .spawn_blocking_task(move || host.delete(tag))
            .await
            .map_err(failed)?;
        deleted.map_err(store_error)
    }
}

// The host's settings under the engine's trait; documents cross as JSON text.
pub(crate) struct HostSettingsBridge {
    pub(crate) host: Arc<dyn HostSettings>,
    pub(crate) kind: Kind,
    pub(crate) tasks: Tasks,
}

fn host_error(failure: impl std::fmt::Display) -> AdapterError {
    AdapterError::Host {
        detail: failure.to_string(),
    }
}

#[async_trait]
impl sync::HostSettings for HostSettingsBridge {
    fn kind(&self) -> Kind {
        self.kind
    }

    async fn categories(&self) -> Result<Vec<SettingsDocument>, AdapterError> {
        let host = Arc::clone(&self.host);
        let categories = self
            .tasks
            .spawn_blocking_task(move || host.categories())
            .await
            .map_err(host_error)?;
        categories
            .map_err(host_error)?
            .into_iter()
            .map(|category| {
                let document = serde_json::from_str(&category.document).map_err(host_error)?;
                Ok(SettingsDocument {
                    category: category.category,
                    document,
                })
            })
            .collect()
    }

    async fn apply(&self, category: String, document: Option<serde_json::Value>) -> Result<(), AdapterError> {
        let host = Arc::clone(&self.host);
        let document = document.map(|document| document.to_string());
        let applied = self
            .tasks
            .spawn_blocking_task(move || host.apply(category, document))
            .await
            .map_err(host_error)?;
        applied.map_err(host_error)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_keys::encoding::{AccountId, Origin, Version};
    use tablepro_sync::api::DeviceItem;
    use tablepro_sync::api::ids::StateName;
    use uuid::Uuid;

    use super::*;

    #[test]
    fn an_item_keeps_its_class_across_the_boundary() {
        let origin = Origin::parse("https://api.tablepro.app").unwrap();
        let keys = DeviceItem::AccountKeys {
            origin,
            account: AccountId(Uuid::nil()),
            av: Version::new(3).unwrap(),
        };
        let anchor = DeviceItem::AnchorRoot {
            state: StateName("ab".repeat(32)),
        };

        let tag = DeviceItemTag::of(&anchor);

        assert_eq!(device_item_class(DeviceItemTag::of(&keys)), DeviceItemClassTag::Keys);
        assert_eq!(tag.class(), DeviceItemClassTag::Anchor);
        assert_eq!(tag, DeviceItemTag::AnchorRoot { state: "ab".repeat(32) });
    }
}
