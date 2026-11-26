use std::sync::Arc;

use async_trait::async_trait;
use tablepro_sync::api::cloudkit as sync;

// 0054, The CloudKit transport: Swift implements it in `TableProSyncTransport` over CloudKit's operations and decides
// nothing. The core never calls it under a lock, and dropping a call cancels the Swift task, which cancels its
// operation. Every call names the iCloud user record name the pass's state file is bound to.
#[uniffi::export(with_foreign)]
#[async_trait]
pub trait CloudKitTransport: Send + Sync {
    async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure>;

    async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure>;

    async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure>;

    async fn fetch_changes(&self, account: String, token: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure>;

    async fn fetch_records(&self, account: String, names: Vec<String>)
    -> Result<Vec<CloudKitFetched>, CloudKitFailure>;

    async fn modify(
        &self,
        account: String,
        saves: Vec<CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure>;
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudKitAccount {
    pub user_record_name: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CloudKitRecord {
    pub record_type: String,
    pub name: String,
    // `CKRecord.encodeSystemFields(with:)`; a create sends none.
    pub system_fields: Option<Vec<u8>>,
    // `CKRecord.creationDate` in milliseconds, on a record CloudKit returned; None on a save.
    pub created_ms: Option<i64>,
    pub fields: Vec<CloudKitField>,
}

// None clears the field.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CloudKitField {
    pub name: String,
    pub value: Option<CloudKitValue>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CloudKitValue {
    Text { value: String },
    Int64 { value: i64 },
    Double { value: f64 },
    // Milliseconds since the Unix epoch.
    Timestamp { value: i64 },
    Bytes { value: Vec<u8> },
    TextList { value: Vec<String> },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CloudKitChanges {
    pub changed: Vec<CloudKitRecord>,
    pub deleted: Vec<CloudKitDeletion>,
    pub unfetched: Vec<String>,
    pub token: Vec<u8>,
    pub more: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudKitDeletion {
    pub name: String,
    pub record_type: String,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CloudKitFetched {
    Found {
        record: CloudKitRecord,
    },
    Missing {
        name: String,
    },
    Failed {
        name: String,
        code: i64,
        retry_after_ms: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CloudKitOutcome {
    Saved {
        name: String,
        system_fields: Vec<u8>,
    },
    Deleted {
        name: String,
    },
    ServerChanged {
        name: String,
        server: Option<CloudKitRecord>,
    },
    UnknownItem {
        name: String,
    },
    Failed {
        name: String,
        code: i64,
        retry_after_ms: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum CloudKitFailure {
    #[error("no iCloud account")]
    NoAccount,
    #[error("iCloud is restricted")]
    Restricted,
    #[error("the iCloud account is temporarily unavailable")]
    AccountTemporarilyUnavailable,
    #[error("the iCloud account changed during the call")]
    AccountChanged,
    #[error("the change token expired")]
    TokenExpired,
    #[error("the zone does not exist")]
    ZoneNotFound,
    #[error("the person deleted the zone")]
    ZoneDeletedByUser,
    #[error("the batch is over CloudKit's limit")]
    LimitExceeded,
    #[error("the iCloud quota is exceeded")]
    QuotaExceeded,
    #[error("the network failed")]
    Network,
    #[error("CloudKit is throttling")]
    Throttled { retry_after_ms: Option<u64> },
    #[error("CloudKit failed with code {code}")]
    Other { code: i64 },
}

// A Swift implementation that threw something it should not have is a failure the engine backs off from.
impl From<uniffi::UnexpectedUniFFICallbackError> for CloudKitFailure {
    fn from(_: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Other { code: -1 }
    }
}

// The host's transport under the engine's trait.
pub(crate) struct CloudKitBridge(pub(crate) Arc<dyn CloudKitTransport>);

impl std::fmt::Debug for CloudKitBridge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("CloudKitBridge")
    }
}

#[async_trait]
impl sync::CloudKitTransport for CloudKitBridge {
    async fn account_status(&self) -> Result<sync::CloudKitAccount, sync::CloudKitFailure> {
        let account = self.0.account_status().await?;
        Ok(sync::CloudKitAccount {
            user_record_name: account.user_record_name,
        })
    }

    async fn ensure_zone(&self, account: String) -> Result<(), sync::CloudKitFailure> {
        Ok(self.0.ensure_zone(account).await?)
    }

    async fn delete_zone(&self, account: String) -> Result<(), sync::CloudKitFailure> {
        Ok(self.0.delete_zone(account).await?)
    }

    async fn fetch_changes(
        &self,
        account: String,
        token: Option<Vec<u8>>,
    ) -> Result<sync::CloudKitChanges, sync::CloudKitFailure> {
        let changes = self.0.fetch_changes(account, token).await?;
        Ok(sync::CloudKitChanges {
            changed: changes.changed.into_iter().map(Into::into).collect(),
            deleted: changes
                .deleted
                .into_iter()
                .map(|deletion| sync::CloudKitDeletion {
                    name: deletion.name,
                    record_type: deletion.record_type,
                })
                .collect(),
            unfetched: changes.unfetched,
            token: changes.token,
            more: changes.more,
        })
    }

    async fn fetch_records(
        &self,
        account: String,
        names: Vec<String>,
    ) -> Result<Vec<sync::CloudKitFetched>, sync::CloudKitFailure> {
        let fetched = self.0.fetch_records(account, names).await?;
        Ok(fetched
            .into_iter()
            .map(|fetched| match fetched {
                CloudKitFetched::Found { record } => sync::CloudKitFetched::Found { record: record.into() },
                CloudKitFetched::Missing { name } => sync::CloudKitFetched::Missing { name },
                CloudKitFetched::Failed {
                    name,
                    code,
                    retry_after_ms,
                } => sync::CloudKitFetched::Failed {
                    name,
                    code,
                    retry_after_ms,
                },
            })
            .collect())
    }

    async fn modify(
        &self,
        account: String,
        saves: Vec<sync::CloudKitRecord>,
        deletes: Vec<String>,
    ) -> Result<Vec<sync::CloudKitOutcome>, sync::CloudKitFailure> {
        let saves = saves.into_iter().map(Into::into).collect();
        let outcomes = self.0.modify(account, saves, deletes).await?;
        Ok(outcomes.into_iter().map(Into::into).collect())
    }
}

impl From<CloudKitFailure> for sync::CloudKitFailure {
    fn from(failure: CloudKitFailure) -> Self {
        match failure {
            CloudKitFailure::NoAccount => Self::NoAccount,
            CloudKitFailure::Restricted => Self::Restricted,
            CloudKitFailure::AccountTemporarilyUnavailable => Self::AccountTemporarilyUnavailable,
            CloudKitFailure::AccountChanged => Self::AccountChanged,
            CloudKitFailure::TokenExpired => Self::TokenExpired,
            CloudKitFailure::ZoneNotFound => Self::ZoneNotFound,
            CloudKitFailure::ZoneDeletedByUser => Self::ZoneDeletedByUser,
            CloudKitFailure::LimitExceeded => Self::LimitExceeded,
            CloudKitFailure::QuotaExceeded => Self::QuotaExceeded,
            CloudKitFailure::Network => Self::Network,
            CloudKitFailure::Throttled { retry_after_ms } => Self::Throttled { retry_after_ms },
            CloudKitFailure::Other { code } => Self::Other { code },
        }
    }
}

impl From<CloudKitValue> for sync::CloudKitValue {
    fn from(value: CloudKitValue) -> Self {
        match value {
            CloudKitValue::Text { value } => Self::Text(value),
            CloudKitValue::Int64 { value } => Self::Int64(value),
            CloudKitValue::Double { value } => Self::Double(value),
            CloudKitValue::Timestamp { value } => Self::Timestamp(value),
            CloudKitValue::Bytes { value } => Self::Bytes(value),
            CloudKitValue::TextList { value } => Self::TextList(value),
        }
    }
}

impl From<sync::CloudKitValue> for CloudKitValue {
    fn from(value: sync::CloudKitValue) -> Self {
        match value {
            sync::CloudKitValue::Text(value) => Self::Text { value },
            sync::CloudKitValue::Int64(value) => Self::Int64 { value },
            sync::CloudKitValue::Double(value) => Self::Double { value },
            sync::CloudKitValue::Timestamp(value) => Self::Timestamp { value },
            sync::CloudKitValue::Bytes(value) => Self::Bytes { value },
            sync::CloudKitValue::TextList(value) => Self::TextList { value },
        }
    }
}

impl From<CloudKitRecord> for sync::CloudKitRecord {
    fn from(record: CloudKitRecord) -> Self {
        Self {
            record_type: record.record_type,
            name: record.name,
            system_fields: record.system_fields,
            created_ms: record.created_ms,
            fields: record
                .fields
                .into_iter()
                .map(|field| sync::CloudKitField {
                    name: field.name,
                    value: field.value.map(Into::into),
                })
                .collect(),
        }
    }
}

impl From<sync::CloudKitRecord> for CloudKitRecord {
    fn from(record: sync::CloudKitRecord) -> Self {
        Self {
            record_type: record.record_type,
            name: record.name,
            system_fields: record.system_fields,
            created_ms: record.created_ms,
            fields: record
                .fields
                .into_iter()
                .map(|field| CloudKitField {
                    name: field.name,
                    value: field.value.map(Into::into),
                })
                .collect(),
        }
    }
}

impl From<CloudKitOutcome> for sync::CloudKitOutcome {
    fn from(outcome: CloudKitOutcome) -> Self {
        match outcome {
            CloudKitOutcome::Saved { name, system_fields } => Self::Saved { name, system_fields },
            CloudKitOutcome::Deleted { name } => Self::Deleted { name },
            CloudKitOutcome::ServerChanged { name, server } => Self::ServerChanged {
                name,
                server: server.map(Into::into),
            },
            CloudKitOutcome::UnknownItem { name } => Self::UnknownItem { name },
            CloudKitOutcome::Failed {
                name,
                code,
                retry_after_ms,
            } => Self::Failed {
                name,
                code,
                retry_after_ms,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_sync::api::cloudkit::CloudKitTransport as _;
    use tablepro_sync_testing::FakeCloudKit;

    use super::*;

    // The Swift side as the bindings see it, here over the core's fake, so the bridge is checked both ways.
    struct Host(FakeCloudKit);

    #[async_trait]
    impl CloudKitTransport for Host {
        async fn account_status(&self) -> Result<CloudKitAccount, CloudKitFailure> {
            let account = self.0.account_status().await.map_err(|_| CloudKitFailure::NoAccount)?;
            Ok(CloudKitAccount {
                user_record_name: account.user_record_name,
            })
        }

        async fn ensure_zone(&self, account: String) -> Result<(), CloudKitFailure> {
            self.0
                .ensure_zone(account)
                .await
                .map_err(|_| CloudKitFailure::ZoneNotFound)
        }

        async fn delete_zone(&self, account: String) -> Result<(), CloudKitFailure> {
            self.0
                .delete_zone(account)
                .await
                .map_err(|_| CloudKitFailure::ZoneNotFound)
        }

        async fn fetch_changes(&self, _: String, _: Option<Vec<u8>>) -> Result<CloudKitChanges, CloudKitFailure> {
            Err(CloudKitFailure::TokenExpired)
        }

        async fn fetch_records(&self, _: String, _: Vec<String>) -> Result<Vec<CloudKitFetched>, CloudKitFailure> {
            Err(CloudKitFailure::Throttled {
                retry_after_ms: Some(30),
            })
        }

        async fn modify(
            &self,
            account: String,
            saves: Vec<CloudKitRecord>,
            deletes: Vec<String>,
        ) -> Result<Vec<CloudKitOutcome>, CloudKitFailure> {
            let saves = saves.into_iter().map(Into::into).collect();
            let outcomes = self
                .0
                .modify(account, saves, deletes)
                .await
                .map_err(|_| CloudKitFailure::LimitExceeded)?;
            Ok(outcomes
                .into_iter()
                .map(|outcome| match outcome {
                    sync::CloudKitOutcome::Saved { name, system_fields } => {
                        CloudKitOutcome::Saved { name, system_fields }
                    }
                    other => CloudKitOutcome::UnknownItem {
                        name: other.name().to_owned(),
                    },
                })
                .collect())
        }
    }

    #[tokio::test]
    async fn the_bridge_carries_records_outcomes_and_failures_unchanged() {
        let bridge = CloudKitBridge(Arc::new(Host(FakeCloudKit::signed_in("_a"))));
        bridge.ensure_zone("_a".to_owned()).await.unwrap();
        let record = sync::CloudKitRecord {
            record_type: "Tag".to_owned(),
            name: "Tag_A".to_owned(),
            system_fields: None,
            created_ms: None,
            fields: vec![sync::CloudKitField {
                name: "name".to_owned(),
                value: Some(sync::CloudKitValue::TextList(vec!["a".to_owned()])),
            }],
        };

        let outcomes = bridge.modify("_a".to_owned(), vec![record], Vec::new()).await.unwrap();
        let expired = bridge.fetch_changes("_a".to_owned(), None).await;
        let throttled = bridge.fetch_records("_a".to_owned(), Vec::new()).await;

        assert!(matches!(&outcomes[0], sync::CloudKitOutcome::Saved { name, .. } if name == "Tag_A"));
        assert_eq!(bridge.account_status().await.unwrap().user_record_name, "_a");
        assert_eq!(expired.unwrap_err(), sync::CloudKitFailure::TokenExpired);
        assert_eq!(
            throttled.unwrap_err(),
            sync::CloudKitFailure::Throttled {
                retry_after_ms: Some(30)
            }
        );
    }
}
