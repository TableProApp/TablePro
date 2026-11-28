use chrono::{DateTime, Utc};
use secrecy::SecretString;
use tablepro_account::{
    AccessToken, AccountStatus, AppClient, Device, EntitlementProblem, FeatureAccess, License, LicenseClaim,
    LicenseState, Membership, Profile, SignOutCause, StepUpChallenge, TeamClaim,
};

// Codes stay strings, as the account crate keeps them: a plan, status or role this build does not know still shows.
// Times are seconds from the Unix epoch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AccountStatusInfo {
    pub state: AccountStateTag,
    // From the entitlement, kept while a refresh fails.
    pub account_id: Option<String>,
    pub email: Option<String>,
    pub name: Option<String>,
    pub features: Vec<String>,
    pub licenses: Vec<LicenseInfo>,
    pub entitlement_expires_at_secs: Option<i64>,
    // The entitlement came from an offline file. A signed-in machine can import one too, so the state does not say.
    pub offline_file: bool,
    // The sign-in's id in this process; another sign-in or launch, even of the same account, has another. None signed out.
    pub session_id: Option<String>,
    pub problem: Option<EntitlementProblemTag>,
    // False when no secret store took the sign-in: the next launch starts signed out.
    pub remembered: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AccountStateTag {
    SignedOut,
    SignedIn,
    // An imported offline file on a machine that is not signed in.
    Offline,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum EntitlementProblemTag {
    Expired,
    // The code of the error the last refresh met.
    RefreshFailed { code: String },
    DeviceLimitReached { devices: Vec<DeviceInfo> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FeatureAccessTag {
    Available,
    SignedOut,
    NotIncluded,
    Expired,
    RefreshFailed,
    DeviceLimitReached,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LicenseInfo {
    pub id: String,
    pub plan: String,
    pub cycle: String,
    pub source: String,
    pub status: String,
    pub renews_at_secs: Option<i64>,
    pub ends_at_secs: Option<i64>,
    pub team: Option<TeamInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TeamInfo {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MembershipInfo {
    pub team: TeamInfo,
    pub role: String,
    pub has_seat: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ProfileInfo {
    pub id: String,
    pub email: String,
    pub name: Option<String>,
    pub licenses: Vec<LicenseInfo>,
    pub teams: Vec<MembershipInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DeviceInfo {
    pub id: String,
    pub platform: String,
    pub name: String,
    pub app_version: String,
    pub os_version: String,
    pub last_seen_at_secs: i64,
    pub licensed_at_secs: Option<i64>,
    // Until then, removing it is refused with offline_file_active.
    pub offline_until_secs: Option<i64>,
    pub is_this_machine: bool,
}

// Which app the account is for: its OAuth client, its device platform and how the sign-in comes back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppClientTag {
    Linux,
    Windows,
    Macos,
    Ios,
}

// The server the account signs in to. `api_origin` is what a person or an organization names it by.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerInfo {
    pub api_origin: String,
    // None until a company server's discovery has run.
    pub account_origin: Option<String>,
    pub host: String,
    pub is_production: bool,
    // The organization named it, and the person has not picked another.
    pub is_managed: bool,
    // False hides tablepro.app and the field for another server.
    pub others_allowed: bool,
}

// The license a company server holds, as this app verified it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ServerLicenseInfo {
    pub id: String,
    // `trial` or `paid`.
    pub license_type: String,
    pub seats: u32,
    pub features: Vec<String>,
    // None for a perpetual license.
    pub expires_at_secs: Option<i64>,
    pub grace_ends_at_secs: Option<i64>,
    pub state: LicenseStateTag,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LicenseStateTag {
    Active,
    // Past its end, inside the grace: everything still works.
    Grace,
    // Past the grace: pulls of the sync features, and key-object writes.
    Lapsed,
}

// A bearer for the app's own /v2 client, and the base it goes to.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AccessTokenInfo {
    pub token: SecretString,
    pub api_url: String,
    // The sign-in the token is of, so the app sends nothing it kept for another under it.
    pub session_id: Option<String>,
}

// RFC 9470's challenge, as `account.step_up_required` carries it in `ErrorInfo.step_up` and `sync.step_up_required` in
// its `SyncFailureInfo::StepUp`: what `AccountService::step_up` asks the server's sign-in page for.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StepUpChallengeInfo {
    // In the server's order of preference.
    pub acr_values: Vec<String>,
    pub max_age_secs: Option<u64>,
}

impl From<StepUpChallenge> for StepUpChallengeInfo {
    fn from(challenge: StepUpChallenge) -> Self {
        Self {
            acr_values: challenge.acr_values,
            max_age_secs: challenge.max_age_secs,
        }
    }
}

impl From<StepUpChallengeInfo> for StepUpChallenge {
    fn from(challenge: StepUpChallengeInfo) -> Self {
        Self {
            acr_values: challenge.acr_values,
            max_age_secs: challenge.max_age_secs,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SignOutCauseTag {
    Requested,
    // The server refused the sign-in: its tokens were revoked, or one was replayed.
    Refused,
    DeviceRevoked,
    ServerChanged,
}

impl From<AppClientTag> for AppClient {
    fn from(client: AppClientTag) -> Self {
        match client {
            AppClientTag::Linux => Self::LINUX,
            AppClientTag::Windows => Self::WINDOWS,
            AppClientTag::Macos => Self::MACOS,
            AppClientTag::Ios => Self::IOS,
        }
    }
}

impl From<tablepro_account::ServerInfo> for ServerInfo {
    fn from(server: tablepro_account::ServerInfo) -> Self {
        Self {
            api_origin: server.api_origin,
            account_origin: server.account_origin,
            host: server.host,
            is_production: server.is_production,
            is_managed: server.is_managed,
            others_allowed: server.others_allowed,
        }
    }
}

impl ServerLicenseInfo {
    pub(crate) fn of(license: &License, now: DateTime<Utc>) -> Self {
        let claims = license.claims();
        Self {
            id: claims.sub.clone(),
            license_type: claims.license_type.clone(),
            seats: claims.seats,
            features: claims.features.clone(),
            expires_at_secs: license.expires_at().map(seconds),
            grace_ends_at_secs: license.grace_ends_at().map(seconds),
            state: match license.state(now) {
                LicenseState::Active => LicenseStateTag::Active,
                LicenseState::Grace { .. } => LicenseStateTag::Grace,
                LicenseState::Lapsed => LicenseStateTag::Lapsed,
            },
        }
    }
}

impl From<AccessToken> for AccessTokenInfo {
    fn from(access: AccessToken) -> Self {
        Self {
            token: access.token,
            api_url: access.api,
            session_id: access.session_id,
        }
    }
}

impl From<SignOutCause> for SignOutCauseTag {
    fn from(cause: SignOutCause) -> Self {
        match cause {
            SignOutCause::Requested => Self::Requested,
            SignOutCause::Refused => Self::Refused,
            SignOutCause::DeviceRevoked => Self::DeviceRevoked,
            SignOutCause::ServerChanged => Self::ServerChanged,
        }
    }
}

impl AccountStatusInfo {
    pub(crate) fn of(status: &AccountStatus, machine_id: &str) -> Self {
        let (state, signed_in) = match status {
            AccountStatus::SignedOut => (AccountStateTag::SignedOut, None),
            AccountStatus::SignedIn(signed_in) => (AccountStateTag::SignedIn, Some(signed_in)),
            AccountStatus::Offline(_) => (AccountStateTag::Offline, None),
        };
        let claims = status.entitlement().map(tablepro_account::Entitlement::claims);
        Self {
            state,
            account_id: claims.map(|claims| claims.sub.clone()),
            email: claims.map(|claims| claims.account.email.clone()),
            name: claims
                .map(|claims| claims.account.name.clone())
                .filter(|name| !name.trim().is_empty()),
            features: status.features(Utc::now()),
            licenses: claims
                .map(|claims| claims.licenses.iter().map(LicenseInfo::from).collect())
                .unwrap_or_default(),
            entitlement_expires_at_secs: status.entitlement().map(|it| it.expires_at().timestamp()),
            offline_file: claims.is_some_and(|claims| claims.offline),
            session_id: signed_in.and_then(|signed_in| signed_in.session_id.clone()),
            problem: signed_in
                .and_then(|signed_in| signed_in.problem.as_ref())
                .map(|problem| EntitlementProblemTag::of(problem, machine_id)),
            remembered: signed_in.is_some_and(|signed_in| signed_in.remembered),
        }
    }
}

impl EntitlementProblemTag {
    fn of(problem: &EntitlementProblem, machine_id: &str) -> Self {
        match problem {
            EntitlementProblem::Expired => Self::Expired,
            EntitlementProblem::RefreshFailed(error) => Self::RefreshFailed {
                code: error.code().to_owned(),
            },
            EntitlementProblem::DeviceLimitReached(devices) => Self::DeviceLimitReached {
                devices: devices
                    .iter()
                    .map(|device| DeviceInfo::of(device, machine_id))
                    .collect(),
            },
        }
    }
}

impl From<FeatureAccess> for FeatureAccessTag {
    fn from(access: FeatureAccess) -> Self {
        match access {
            FeatureAccess::Available => Self::Available,
            FeatureAccess::SignedOut => Self::SignedOut,
            FeatureAccess::NotIncluded => Self::NotIncluded,
            FeatureAccess::Expired => Self::Expired,
            FeatureAccess::RefreshFailed => Self::RefreshFailed,
            FeatureAccess::DeviceLimitReached => Self::DeviceLimitReached,
        }
    }
}

impl From<&LicenseClaim> for LicenseInfo {
    fn from(license: &LicenseClaim) -> Self {
        Self {
            id: license.id.clone(),
            plan: license.plan.clone(),
            cycle: license.cycle.clone(),
            source: license.source.clone(),
            status: license.status.clone(),
            renews_at_secs: license.renews_at.map(seconds),
            ends_at_secs: license.ends_at.map(seconds),
            team: license.team.as_ref().map(TeamInfo::from),
        }
    }
}

impl From<&TeamClaim> for TeamInfo {
    fn from(team: &TeamClaim) -> Self {
        Self {
            id: team.id.clone(),
            name: team.name.clone(),
        }
    }
}

impl From<Profile> for ProfileInfo {
    fn from(profile: Profile) -> Self {
        Self {
            id: profile.id,
            email: profile.email,
            name: profile.name,
            licenses: profile.licenses.iter().map(LicenseInfo::from).collect(),
            teams: profile.teams.iter().map(MembershipInfo::from).collect(),
        }
    }
}

impl From<&Membership> for MembershipInfo {
    fn from(membership: &Membership) -> Self {
        Self {
            team: TeamInfo::from(&membership.team),
            role: membership.role.clone(),
            has_seat: membership.has_seat,
        }
    }
}

impl DeviceInfo {
    pub(crate) fn of(device: &Device, machine_id: &str) -> Self {
        Self {
            id: device.id.clone(),
            platform: device.platform.clone(),
            name: device.name.clone(),
            app_version: device.app_version.clone(),
            os_version: device.os_version.clone(),
            last_seen_at_secs: seconds(device.last_seen_at),
            licensed_at_secs: device.licensed_at.map(seconds),
            offline_until_secs: device.offline_until.map(seconds),
            is_this_machine: device.machine_id == machine_id,
        }
    }
}

fn seconds(at: DateTime<Utc>) -> i64 {
    at.timestamp()
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;
    use tablepro_account::{AccountError, SignedIn, fakes};

    use super::*;

    fn device(machine_id: &str) -> Device {
        Device {
            id: "dev_01".to_owned(),
            machine_id: machine_id.to_owned(),
            platform: "windows".to_owned(),
            name: "Lab".to_owned(),
            app_version: "1.0.0".to_owned(),
            os_version: "Windows 11".to_owned(),
            last_seen_at: DateTime::from_timestamp(1_800_000_000, 0).unwrap(),
            licensed_at: None,
            offline_until: None,
            key_device: None,
        }
    }

    #[test]
    fn signed_out_says_nothing_about_an_account() {
        let info = AccountStatusInfo::of(&AccountStatus::SignedOut, fakes::MACHINE);

        assert_eq!(info.state, AccountStateTag::SignedOut);
        assert_eq!((info.email, info.problem), (None, None));
        assert!(info.features.is_empty());
        assert!(!info.remembered);
        assert_eq!(info.session_id, None);
    }

    #[test]
    fn a_signed_in_status_names_the_account_and_its_features() {
        let issued = Utc::now();
        let claims = fakes::claims(issued, TimeDelta::days(14), &["shared_links"]);
        let entitlement = fakes::entitlement(&claims).unwrap();
        let status = AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement: Some(entitlement),
            problem: Some(EntitlementProblem::RefreshFailed(AccountError::Unreachable(
                "offline".to_owned(),
            ))),
            remembered: true,
            session_id: Some("0123456789abcdef0123456789abcdef".to_owned()),
        }));

        let info = AccountStatusInfo::of(&status, fakes::MACHINE);

        assert_eq!(info.state, AccountStateTag::SignedIn);
        assert_eq!(info.account_id.as_deref(), Some(claims.sub.as_str()));
        assert_eq!(info.email.as_deref(), Some(claims.account.email.as_str()));
        assert_eq!(info.features, ["shared_links"]);
        assert_eq!(info.entitlement_expires_at_secs, Some(claims.exp));
        assert!(!info.offline_file);
        assert_eq!(info.session_id.as_deref(), Some("0123456789abcdef0123456789abcdef"));
        assert_eq!(
            info.problem,
            Some(EntitlementProblemTag::RefreshFailed {
                code: "account.unreachable".to_owned()
            })
        );
        assert!(info.remembered);
    }

    #[test]
    fn an_offline_file_a_signed_in_machine_imported_says_so() {
        let mut claims = fakes::claims(Utc::now(), TimeDelta::days(30), &["shared_links"]);
        claims.offline = true;
        let status = AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement: Some(fakes::entitlement(&claims).unwrap()),
            problem: None,
            remembered: true,
            session_id: Some("0123456789abcdef0123456789abcdef".to_owned()),
        }));

        let info = AccountStatusInfo::of(&status, fakes::MACHINE);

        assert_eq!(info.state, AccountStateTag::SignedIn);
        assert!(info.offline_file);
    }

    #[test]
    fn the_device_limit_lists_the_devices_and_marks_this_one() {
        let status = AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement: None,
            problem: Some(EntitlementProblem::DeviceLimitReached(vec![
                device(fakes::MACHINE),
                device("another machine"),
            ])),
            remembered: false,
            session_id: Some("0123456789abcdef0123456789abcdef".to_owned()),
        }));

        let info = AccountStatusInfo::of(&status, fakes::MACHINE);

        let Some(EntitlementProblemTag::DeviceLimitReached { devices }) = info.problem else {
            panic!("not the device limit: {:?}", info.problem);
        };
        assert_eq!(
            devices.iter().map(|device| device.is_this_machine).collect::<Vec<_>>(),
            [true, false]
        );
        assert_eq!(devices[0].last_seen_at_secs, 1_800_000_000);
        assert_eq!(info.account_id, None);
    }
}
