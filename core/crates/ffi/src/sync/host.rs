// The app's sides of sync that only the app can do: its settings, kept its own way (0054, Adapters), and its device
// store, for the keys and the state file's anchor (0054, Integrity and freshness). Each call may block, so the core
// makes it on a blocking thread, never under a lock.

use crate::host::HostSecretError;

#[uniffi::export(callback_interface)]
pub trait HostSettings: Send + Sync {
    // Every category of the platform's registry that holds a value, each as one JSON document.
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

// One item, named by what it holds. Ids are upper-case UUID text, files are hex.
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
        file: String,
    },
    AnchorRoot {
        file: String,
    },
    AnchorCheckpoint {
        file: String,
        checkpoint: String,
        part: u32,
    },
}

impl DeviceItemTag {
    pub(crate) fn of(item: &tablepro_sync::api::DeviceItem) -> Self {
        use tablepro_sync::api::DeviceItem;
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
            DeviceItem::StateMacKey { file } => Self::StateMacKey { file: hex(&file.0) },
            DeviceItem::AnchorRoot { file } => Self::AnchorRoot { file: hex(&file.0) },
            DeviceItem::AnchorCheckpoint { file, checkpoint, part } => Self::AnchorCheckpoint {
                file: hex(&file.0),
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

#[cfg(test)]
mod tests {
    use tablepro_keys::encoding::{AccountId, Origin, Version};
    use tablepro_sync::api::DeviceItem;
    use tablepro_sync::api::ids::FileId;
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
            file: FileId([0xab; 16]),
        };

        let tag = DeviceItemTag::of(&anchor);

        assert_eq!(device_item_class(DeviceItemTag::of(&keys)), DeviceItemClassTag::Keys);
        assert_eq!(tag.class(), DeviceItemClassTag::Anchor);
        assert_eq!(tag, DeviceItemTag::AnchorRoot { file: "ab".repeat(16) });
    }
}
