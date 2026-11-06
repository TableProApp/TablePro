use chrono::{DateTime, Utc};

use crate::account_error::AccountError;
use crate::entitlement::Entitlement;
use crate::profile::Device;

#[derive(Debug, Clone, Default)]
pub enum AccountStatus {
    #[default]
    SignedOut,
    SignedIn(Box<SignedIn>),
    // An imported offline file on a machine that is not signed in.
    Offline(Box<Entitlement>),
}

#[derive(Debug, Clone)]
pub struct SignedIn {
    // Kept while a refresh fails: an offline machine uses it until it expires.
    pub entitlement: Option<Entitlement>,
    pub problem: Option<EntitlementProblem>,
    // False when no keyring took the refresh token: the next launch is signed out.
    pub remembered: bool,
}

#[derive(Debug, Clone)]
pub enum EntitlementProblem {
    Expired,
    RefreshFailed(AccountError),
    DeviceLimitReached(Vec<Device>),
}

// From the entitlement's feature codes only: the app knows no plan or tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FeatureAccess {
    Available,
    SignedOut,
    NotIncluded,
    Expired,
    RefreshFailed,
    DeviceLimitReached,
}

impl AccountStatus {
    pub fn feature_access(&self, feature: &str, now: DateTime<Utc>) -> FeatureAccess {
        let signed_in = match self {
            Self::SignedOut => return FeatureAccess::SignedOut,
            Self::Offline(entitlement) if !entitlement.is_current(now) => return FeatureAccess::Expired,
            Self::Offline(entitlement) => {
                return match entitlement.includes(feature) {
                    true => FeatureAccess::Available,
                    false => FeatureAccess::NotIncluded,
                };
            }
            Self::SignedIn(signed_in) => signed_in,
        };
        if let Some(entitlement) = signed_in.entitlement.as_ref().filter(|it| it.is_current(now)) {
            return match entitlement.includes(feature) {
                true => FeatureAccess::Available,
                false => FeatureAccess::NotIncluded,
            };
        }
        match (&signed_in.problem, &signed_in.entitlement) {
            (Some(EntitlementProblem::DeviceLimitReached(_)), _) => FeatureAccess::DeviceLimitReached,
            (Some(EntitlementProblem::RefreshFailed(_)), _) => FeatureAccess::RefreshFailed,
            (Some(EntitlementProblem::Expired), _) | (None, Some(_)) => FeatureAccess::Expired,
            (None, None) => FeatureAccess::NotIncluded,
        }
    }

    pub fn entitlement(&self) -> Option<&Entitlement> {
        match self {
            Self::SignedIn(signed_in) => signed_in.entitlement.as_ref(),
            Self::Offline(entitlement) => Some(entitlement),
            Self::SignedOut => None,
        }
    }

    // The devices that hold the license, while the last refresh met the device limit.
    pub fn device_limit(&self) -> Option<&[Device]> {
        match self {
            Self::SignedIn(signed_in) => match &signed_in.problem {
                Some(EntitlementProblem::DeviceLimitReached(devices)) => Some(devices),
                _ => None,
            },
            Self::SignedOut | Self::Offline(_) => None,
        }
    }

    pub fn past_device_limit(&self) -> bool {
        self.device_limit().is_some()
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;

    use super::*;
    use crate::entitlement::test_tokens::{MACHINE, claims, keys, sign};

    const FEATURE: &str = "env_var_references";

    fn entitlement(issued: DateTime<Utc>, features: &[&str]) -> Entitlement {
        let token = sign(&claims(issued, TimeDelta::days(14), features));
        Entitlement::verify(&token, &keys(), MACHINE, issued).expect("a valid entitlement")
    }

    fn offline() -> AccountError {
        AccountError::Unreachable("connection refused".to_owned())
    }

    fn signed_in(entitlement: Option<Entitlement>, problem: Option<EntitlementProblem>) -> AccountStatus {
        AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement,
            problem,
            remembered: true,
        }))
    }

    #[test]
    fn signed_out_unlocks_nothing() {
        assert_eq!(
            AccountStatus::SignedOut.feature_access(FEATURE, Utc::now()),
            FeatureAccess::SignedOut
        );
    }

    #[test]
    fn a_current_entitlement_unlocks_exactly_its_codes() {
        let now = Utc::now();
        let status = signed_in(Some(entitlement(now, &[FEATURE])), None);

        assert_eq!(status.feature_access(FEATURE, now), FeatureAccess::Available);
        assert_eq!(status.feature_access("team_library", now), FeatureAccess::NotIncluded);
    }

    #[test]
    fn a_free_account_gets_an_entitlement_without_features() {
        let now = Utc::now();
        let status = signed_in(Some(entitlement(now, &[])), None);

        assert_eq!(status.feature_access(FEATURE, now), FeatureAccess::NotIncluded);
    }

    #[test]
    fn a_failed_refresh_keeps_a_current_entitlement_working() {
        let now = Utc::now();
        let failed = Some(EntitlementProblem::RefreshFailed(offline()));
        let limited = Some(EntitlementProblem::DeviceLimitReached(Vec::new()));

        let offline = signed_in(Some(entitlement(now, &[FEATURE])), failed);
        let over_limit = signed_in(Some(entitlement(now, &[FEATURE])), limited);

        assert_eq!(offline.feature_access(FEATURE, now), FeatureAccess::Available);
        assert_eq!(over_limit.feature_access(FEATURE, now), FeatureAccess::Available);
    }

    #[test]
    fn an_entitlement_stops_at_its_exp_while_the_app_runs() {
        let issued = Utc::now() - TimeDelta::days(20);
        let held = entitlement(issued, &[FEATURE]);
        let later = held.expires_at();
        let failed = Some(EntitlementProblem::RefreshFailed(offline()));

        let expired = signed_in(Some(held.clone()), None);
        let unrefreshed = signed_in(Some(held), failed);

        assert_eq!(expired.feature_access(FEATURE, later), FeatureAccess::Expired);
        assert_eq!(unrefreshed.feature_access(FEATURE, later), FeatureAccess::RefreshFailed);
    }

    #[test]
    fn an_offline_file_unlocks_its_codes_until_it_expires() {
        let issued = Utc::now();
        let held = entitlement(issued, &[FEATURE]);
        let later = held.expires_at();
        let status = AccountStatus::Offline(Box::new(held));

        assert_eq!(status.feature_access(FEATURE, issued), FeatureAccess::Available);
        assert_eq!(
            status.feature_access("team_library", issued),
            FeatureAccess::NotIncluded
        );
        assert_eq!(status.feature_access(FEATURE, later), FeatureAccess::Expired);
    }

    #[test]
    fn without_an_entitlement_the_problem_says_why() {
        let now = Utc::now();
        let cases = [
            (None, FeatureAccess::NotIncluded),
            (Some(EntitlementProblem::Expired), FeatureAccess::Expired),
            (
                Some(EntitlementProblem::RefreshFailed(offline())),
                FeatureAccess::RefreshFailed,
            ),
            (
                Some(EntitlementProblem::DeviceLimitReached(Vec::new())),
                FeatureAccess::DeviceLimitReached,
            ),
        ];

        for (problem, access) in cases {
            assert_eq!(signed_in(None, problem).feature_access(FEATURE, now), access);
        }
    }
}
