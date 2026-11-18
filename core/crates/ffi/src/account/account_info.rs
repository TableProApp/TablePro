use chrono::{DateTime, Utc};
use tablepro_account::{
    AccountStatus, Device, EntitlementProblem, FeatureAccess, LicenseClaim, Membership, Profile, TeamClaim,
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
            features: claims.map(|claims| claims.features.clone()).unwrap_or_default(),
            licenses: claims
                .map(|claims| claims.licenses.iter().map(LicenseInfo::from).collect())
                .unwrap_or_default(),
            entitlement_expires_at_secs: status.entitlement().map(|it| it.expires_at().timestamp()),
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
        }
    }

    #[test]
    fn signed_out_says_nothing_about_an_account() {
        let info = AccountStatusInfo::of(&AccountStatus::SignedOut, fakes::MACHINE);

        assert_eq!(info.state, AccountStateTag::SignedOut);
        assert_eq!((info.email, info.problem), (None, None));
        assert!(info.features.is_empty());
        assert!(!info.remembered);
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
        }));

        let info = AccountStatusInfo::of(&status, fakes::MACHINE);

        assert_eq!(info.state, AccountStateTag::SignedIn);
        assert_eq!(info.account_id.as_deref(), Some(claims.sub.as_str()));
        assert_eq!(info.email.as_deref(), Some(claims.account.email.as_str()));
        assert_eq!(info.features, ["shared_links"]);
        assert_eq!(info.entitlement_expires_at_secs, Some(claims.exp));
        assert_eq!(
            info.problem,
            Some(EntitlementProblemTag::RefreshFailed {
                code: "account.unreachable".to_owned()
            })
        );
        assert!(info.remembered);
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
