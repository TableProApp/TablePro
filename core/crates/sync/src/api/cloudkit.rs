use std::fmt;

use async_trait::async_trait;

// 0054, The CloudKit transport. Swift implements it over CloudKit's operations; the FFI's foreign trait of the same
// name bridges to this one. The core never calls it under a lock, and dropping a call's future cancels the Swift task.
// Swift decides nothing: it maps each `CKError` to an outcome or a failure and returns. Every call names the iCloud
// user record name the pass's state file is bound to.
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

// The signed-in iCloud account: its user record name.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CloudKitAccount {
    pub user_record_name: String,
}

#[derive(Clone, PartialEq)]
pub struct CloudKitRecord {
    pub record_type: String,
    pub name: String,
    // What `CKRecord.encodeSystemFields(with:)` writes; Swift rebuilds the record from it and saves with
    // `.ifServerRecordUnchanged`. A create sends none.
    pub system_fields: Option<Vec<u8>>,
    // `CKRecord.creationDate` in milliseconds, on a record CloudKit returned; None on a save. Kept with the base, it
    // tells a record made again after a zone was removed from the one the base came from.
    pub created_ms: Option<i64>,
    pub fields: Vec<CloudKitField>,
}

impl fmt::Debug for CloudKitRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CloudKitRecord")
            .field("record_type", &self.record_type)
            .field("name", &self.name)
            .field("system_fields", &self.system_fields.as_ref().map(Vec::len))
            .field(
                "fields",
                &self.fields.iter().map(|field| &field.name).collect::<Vec<_>>(),
            )
            .finish()
    }
}

// A save names each field it sets; `None` clears one.
#[derive(Debug, Clone, PartialEq)]
pub struct CloudKitField {
    pub name: String,
    pub value: Option<CloudKitValue>,
}

// CloudKit's own types; `tablepro_records::cloudkit` maps them to wire fields and back.
#[derive(Debug, Clone, PartialEq)]
pub enum CloudKitValue {
    Text(String),
    Int64(i64),
    Double(f64),
    // Milliseconds since the Unix epoch, the precision a CloudKit date keeps.
    Timestamp(i64),
    Bytes(Vec<u8>),
    TextList(Vec<String>),
}

#[derive(Debug, Clone, PartialEq)]
pub struct CloudKitChanges {
    pub changed: Vec<CloudKitRecord>,
    pub deleted: Vec<CloudKitDeletion>,
    // Records the zone reported changed whose fetch failed; the engine fetches them by name or holds them.
    pub unfetched: Vec<String>,
    pub token: Vec<u8>,
    pub more: bool,
}

// `recordWithIDWasDeletedBlock`'s record name and type.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct CloudKitDeletion {
    pub name: String,
    pub record_type: String,
}

// One name of `fetch_records`, as `perRecordResultBlock` answers it.
#[derive(Debug, Clone, PartialEq)]
pub enum CloudKitFetched {
    Found {
        record: CloudKitRecord,
    },
    // `unknownItem`: the zone holds no record by that name.
    Missing {
        name: String,
    },
    Failed {
        name: String,
        code: i64,
        retry_after_ms: Option<u64>,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub enum CloudKitOutcome {
    Saved {
        name: String,
        system_fields: Vec<u8>,
    },
    Deleted {
        name: String,
    },
    // `serverRecordChanged`, with the server's copy when the error carried one.
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

impl CloudKitOutcome {
    pub fn name(&self) -> &str {
        match self {
            Self::Saved { name, .. }
            | Self::Deleted { name }
            | Self::ServerChanged { name, .. }
            | Self::UnknownItem { name }
            | Self::Failed { name, .. } => name,
        }
    }
}

// A whole call's failure. `AccountChanged` discards the call's results, ends the pass and drops its state file's
// session (0054, Every call is bound to one account).
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
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

impl CloudKitFailure {
    pub const fn code(&self) -> &'static str {
        match self {
            Self::NoAccount => "sync.icloud.no_account",
            Self::Restricted => "sync.icloud.restricted",
            Self::AccountTemporarilyUnavailable => "sync.icloud.account_temporarily_unavailable",
            Self::AccountChanged => "sync.icloud.account_changed",
            Self::TokenExpired => "sync.icloud.token_expired",
            Self::ZoneNotFound => "sync.icloud.zone_not_found",
            Self::ZoneDeletedByUser => "sync.icloud.zone_deleted_by_user",
            Self::LimitExceeded => "sync.icloud.limit_exceeded",
            Self::QuotaExceeded => "sync.icloud.quota_exceeded",
            Self::Network => "sync.icloud.network",
            Self::Throttled { .. } => "sync.icloud.throttled",
            Self::Other { .. } => "sync.icloud.other",
        }
    }
}
