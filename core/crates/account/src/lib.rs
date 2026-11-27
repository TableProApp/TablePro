//! The TablePro account: sign-in, device, entitlement and the feature gate. Free of GTK.

mod account;
mod account_error;
mod account_file;
mod account_settings;
mod account_status;
mod browser;
mod entitlement;
mod entitlement_keys;
#[cfg(any(test, feature = "fakes"))]
pub mod fakes;
mod license;
mod license_keys;
mod loopback;
mod machine_id;
mod oauth;
mod offline_file;
mod policy;
mod policy_gate;
mod profile;
mod server;
mod share;
mod share_link;
mod token_vault;

pub use account::{AccessToken, Account, AccountHosts, REFRESH_INTERVAL, RETRY_INTERVAL, SignOutCause};
pub use account_error::AccountError;
pub use account_settings::{
    AccountSettings, AppClient, CallbackPage, DeviceDescription, Endpoints, Redirect, SignInKey,
};
pub use account_status::{AccountStatus, EntitlementProblem, FeatureAccess, SignedIn};
pub use browser::{BrowserLauncher, WebAuthenticationError, WebAuthenticator};
pub use entitlement::{
    AccountClaim, Entitlement, EntitlementClaims, EntitlementError, LicenseClaim, NOT_BEFORE_LEEWAY, TOKEN_TYPE,
    TeamClaim,
};
pub use entitlement_keys::{EntitlementKeys, KeyError};
pub use license::{KEPT_PAST_GRACE, LICENSE_ISSUER, License, LicenseClaims, LicenseError, LicenseState};
pub use license_keys::LicenseKeys;
pub use machine_id::MachineId;
pub use offline_file::{OfflineFileError, read_offline_file_blocking};
pub use policy::{ManagedPolicy, PolicyValues, SyncChoices, SyncProvider};
pub use policy_gate::{PolicyGate, PolicyRead};
pub use profile::{Device, Membership, Profile, TeamMember};
pub use server::{FixedServer, ServerError, ServerInfo, ServerPolicy, ServerSettings};
pub use share::{
    CreatedShare, MAX_SHARE_COLUMNS, MAX_SHARE_SQL_BYTES, Share, ShareExpiry, ShareKind, ShareLimits, SharePage,
    ShareRequest, ShareTeam, SharedLink, sent_share_password,
};
pub use share_link::{is_share_token, share_token_from_link};
pub use tablepro_cloud_api::StepUpChallenge;
pub use token_vault::{RefreshTokenVault, RefreshTokenVaults, SingleVault};
pub use url::Url;
