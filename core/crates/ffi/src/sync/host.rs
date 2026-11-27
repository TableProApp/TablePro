// The app's sides of sync that only the app can do: its settings, kept its own way (0054, Adapters), and its device
// store, for the keys and the state file's anchor (0054, Integrity and freshness). The core never calls either under
// a lock. A device store call may block, so the core makes it on a blocking thread.

use std::sync::Arc;

use async_trait::async_trait;
use tablepro_records::Kind;
use tablepro_session::runtime::Tasks;
use tablepro_sync::api::{self as sync, AdapterError, DeviceStoreError, SettingsDocument};
use zeroize::Zeroizing;

use crate::host::HostSecretError;

// Async, so the app writes into the state its own thread owns without blocking a core thread on it.
#[uniffi::export(with_foreign)]
#[async_trait]
pub trait HostSettings: Send + Sync {
    // Every category that holds a value, each as one JSON document. A category the platform's registry does not name,
    // such as one a newer build wrote, comes back as it was applied, unchanged (core ADR 0066).
    async fn categories(&self) -> Result<Vec<SettingsCategoryArg>, HostSecretError>;

    // None removes the category, as a deleted theme. Returns once the write is on disk: the engine commits the base
    // after it, so a write still in memory would be lost to a quit.
    async fn apply(&self, category: String, document: Option<String>) -> Result<(), HostSecretError>;
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

    // Whether this host keeps a device store at all (`tablepro_sync::api::HostDeviceStore::present`). Mac, iOS and
    // Windows always do. A Linux session answers false only when no Secret Service provider exists; a locked keyring
    // is present and answers Locked. Asked once as sync opens.
    fn present(&self) -> bool;
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

// Where the core keeps an item itself, as Windows does in Credential Manager: one name per item under `prefix`, each
// part of it named apart, so no two items or parts share a credential.
#[cfg_attr(
    not(any(windows, test)),
    expect(dead_code, reason = "only Windows keeps its device items in the core")
)]
pub(crate) fn device_item_target(prefix: &str, item: &sync::DeviceItem) -> String {
    match DeviceItemTag::of(item) {
        DeviceItemTag::DeviceKeys {
            origin,
            account,
            device_row,
        } => format!("{prefix}/sync/device-keys/{origin}/{account}/{device_row}"),
        DeviceItemTag::AccountKeys { origin, account, av } => {
            format!("{prefix}/sync/account-keys/{origin}/{account}/av-{av}")
        }
        DeviceItemTag::ResetKeys { origin, account, reset } => {
            format!("{prefix}/sync/reset-keys/{origin}/{account}/{reset}")
        }
        DeviceItemTag::StateMacKey { state } => format!("{prefix}/sync/state-mac/{state}"),
        DeviceItemTag::AnchorRoot { state } => format!("{prefix}/sync/anchor-root/{state}"),
        DeviceItemTag::AnchorCheckpoint {
            state,
            checkpoint,
            part,
        } => format!("{prefix}/sync/anchor-checkpoint/{state}/{checkpoint}/part-{part}"),
    }
}

// What the platform's secret store said, as the engine reads a device store's failure.
#[cfg_attr(
    not(any(windows, test)),
    expect(dead_code, reason = "only Windows keeps its device items in the core")
)]
pub(crate) fn device_store_error(error: tablepro_core::credentials::SecretError) -> DeviceStoreError {
    use tablepro_core::credentials::SecretError;
    match error {
        SecretError::ServiceUnavailable { detail } => DeviceStoreError::Unavailable { detail },
        SecretError::Locked => DeviceStoreError::Locked,
        other => DeviceStoreError::Failed {
            detail: other.to_string(),
        },
    }
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
    pub(crate) present: bool,
}

impl HostDeviceStoreBridge {
    pub(crate) fn new(host: Arc<dyn HostDeviceStore>, tasks: Tasks) -> Self {
        let present = host.present();
        Self { host, tasks, present }
    }
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

    fn present(&self) -> bool {
        self.present
    }
}

// The host's settings under the engine's trait; documents cross as JSON text.
pub(crate) struct HostSettingsBridge {
    pub(crate) host: Arc<dyn HostSettings>,
    pub(crate) kind: Kind,
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
        self.host
            .categories()
            .await
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
        let document = document.map(|document| document.to_string());
        self.host.apply(category, document).await.map_err(host_error)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_keys::encoding::{AccountId, Origin, Version};
    use tablepro_sync::api::DeviceItem;
    use tablepro_sync::api::ids::StateName;
    use uuid::Uuid;

    use super::*;

    // A host store that never answers: away for now, or no store at all, as the host declares.
    struct Away {
        present: bool,
    }

    impl HostDeviceStore for Away {
        fn load(&self, _: DeviceItemTag) -> Result<Option<Vec<u8>>, HostSecretError> {
            Err(HostSecretError::Unavailable {
                detail: "no secret service".to_owned(),
            })
        }

        fn store(&self, _: DeviceItemTag, _: Vec<u8>) -> Result<(), HostSecretError> {
            Err(HostSecretError::Unavailable {
                detail: "no secret service".to_owned(),
            })
        }

        fn delete(&self, _: DeviceItemTag) -> Result<(), HostSecretError> {
            Err(HostSecretError::Unavailable {
                detail: "no secret service".to_owned(),
            })
        }

        fn present(&self) -> bool {
            self.present
        }
    }

    // A host whose store is away gets no new state file until the store answers; one that declares no store opens it
    // unsealed (orchestrator ruling on 0054).
    #[tokio::test]
    async fn a_new_state_file_waits_for_a_store_that_is_away_and_opens_on_a_host_with_none() {
        use tablepro_sync::api::StateFiles;
        use tablepro_sync::api::state::{StateIdentity, SyncTrust};

        let tasks = crate::runtime::tasks().unwrap();
        let identity = StateIdentity::ICloud {
            user_record_name: "_4e2a".to_owned(),
        };
        let open = |present: bool| {
            let dir = tempfile::tempdir().unwrap();
            let bridge = HostDeviceStoreBridge::new(Arc::new(Away { present }), tasks.clone());
            let files = tablepro_sync::state::SqliteStateFiles::at(dir.path().join("sync"), Arc::new(bridge));
            let identity = identity.clone();
            async move {
                let opened = files.open(identity).await.map(|state| state.opened().sync_tables);
                drop(dir);
                opened
            }
        };

        let away = open(true).await;
        let none = open(false).await;

        assert_eq!(away.unwrap_err().code(), "sync.state.anchor_unsettled");
        assert_eq!(none.unwrap(), SyncTrust::Trusted);
    }

    // An app whose write reaches its disk only after its own thread had a turn.
    #[derive(Default)]
    struct Settings {
        on_disk: std::sync::Mutex<Vec<(String, Option<String>)>>,
    }

    #[async_trait]
    impl HostSettings for Settings {
        async fn categories(&self) -> Result<Vec<SettingsCategoryArg>, HostSecretError> {
            Ok(vec![SettingsCategoryArg {
                category: "general".to_owned(),
                document: r#"{"language":"en"}"#.to_owned(),
            }])
        }

        async fn apply(&self, category: String, document: Option<String>) -> Result<(), HostSecretError> {
            tokio::task::yield_now().await;
            self.on_disk.lock().unwrap().push((category, document));
            Ok(())
        }
    }

    #[tokio::test]
    async fn a_settings_write_has_landed_when_the_bridge_returns() {
        let host = Arc::new(Settings::default());
        let bridge = HostSettingsBridge {
            host: host.clone(),
            kind: Kind::MacosSettings,
        };

        let dark: serde_json::Value = serde_json::from_str(r#"{"name":"dark"}"#).unwrap();
        let read = sync::HostSettings::categories(&bridge).await.unwrap();
        sync::HostSettings::apply(&bridge, "theme".to_owned(), Some(dark))
            .await
            .unwrap();
        sync::HostSettings::apply(&bridge, "editor".to_owned(), None)
            .await
            .unwrap();

        assert_eq!(read[0].document.to_string(), r#"{"language":"en"}"#);
        assert_eq!(
            *host.on_disk.lock().unwrap(),
            vec![
                ("theme".to_owned(), Some(r#"{"name":"dark"}"#.to_owned())),
                ("editor".to_owned(), None)
            ]
        );
    }

    #[test]
    fn each_device_item_has_a_target_of_its_own() {
        let origin = Origin::parse("https://api.tablepro.app").unwrap();
        let account = AccountId(Uuid::from_u128(1));
        let state = StateName("ab".repeat(32));
        let items = [
            DeviceItem::DeviceKeys {
                origin: origin.clone(),
                account,
                device_row: tablepro_sync::api::DeviceRowId("dev_01".to_owned()),
            },
            DeviceItem::AccountKeys {
                origin: origin.clone(),
                account,
                av: Version::new(1).unwrap(),
            },
            DeviceItem::AccountKeys {
                origin,
                account,
                av: Version::new(2).unwrap(),
            },
            DeviceItem::StateMacKey { state: state.clone() },
            DeviceItem::AnchorRoot { state: state.clone() },
            DeviceItem::AnchorCheckpoint {
                state: state.clone(),
                checkpoint: [7; 32],
                part: 0,
            },
            DeviceItem::AnchorCheckpoint {
                state,
                checkpoint: [7; 32],
                part: 1,
            },
        ];

        let targets: std::collections::HashSet<String> =
            items.iter().map(|item| device_item_target("TablePro", item)).collect();

        assert_eq!(targets.len(), items.len());
        assert!(targets.iter().all(|target| target.starts_with("TablePro/sync/")));
        assert!(
            targets.iter().all(|target| !target
                .rsplit('/')
                .next()
                .unwrap()
                .bytes()
                .all(|byte| byte.is_ascii_digit())),
            "a target ending in a number reads as a part of another: {targets:?}"
        );
    }

    #[test]
    fn a_locked_or_missing_secret_store_reads_as_the_engine_s_own_failure() {
        use tablepro_core::credentials::SecretError;

        let unavailable = device_store_error(SecretError::ServiceUnavailable {
            detail: "no keyring".to_owned(),
        });

        assert_eq!(device_store_error(SecretError::Locked), DeviceStoreError::Locked);
        assert!(matches!(unavailable, DeviceStoreError::Unavailable { .. }));
    }

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
