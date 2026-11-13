//! The TablePro account: sign-in, device, entitlement and the feature gate. Free of GTK.

mod account;
mod account_error;
mod account_file;
mod account_settings;
mod account_status;
mod browser;
mod cloud_api;
mod entitlement;
mod entitlement_keys;
#[cfg(any(test, feature = "fakes"))]
pub mod fakes;
mod loopback;
mod machine_id;
mod oauth;
mod offline_file;
mod profile;
mod share;
mod share_link;
mod token_vault;

pub use account::{Account, REFRESH_INTERVAL, RETRY_INTERVAL};
pub use account_error::AccountError;
pub use account_settings::{AccountSettings, AppClient, CallbackPage, DeviceDescription, Endpoints};
pub use account_status::{AccountStatus, EntitlementProblem, FeatureAccess, SignedIn};
pub use browser::BrowserLauncher;
pub use cloud_api::v2;
pub use entitlement::{
    AccountClaim, Entitlement, EntitlementClaims, EntitlementError, LicenseClaim, NOT_BEFORE_LEEWAY, TOKEN_TYPE,
    TeamClaim,
};
pub use entitlement_keys::{EntitlementKeys, KeyError};
pub use machine_id::MachineId;
pub use offline_file::{OfflineFileError, read_offline_file_blocking};
pub use profile::{Device, Membership, Profile};
pub use share::{
    CreatedShare, MAX_SHARE_COLUMNS, Share, ShareExpiry, ShareKind, ShareLimits, SharePage, ShareRequest, ShareTeam,
    SharedLink, SnapshotBody, SnapshotColumnBody,
};
pub use share_link::{is_share_token, share_token_from_link};
pub use token_vault::RefreshTokenVault;
pub use url::Url;
