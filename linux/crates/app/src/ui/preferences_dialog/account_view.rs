use std::cmp::Reverse;

use chrono::{DateTime, TimeDelta, Utc};
use tablepro_account::{
    AccountError, AccountStatus, Device, Entitlement, EntitlementProblem, LicenseClaim, Profile, SignedIn,
};

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::error_text::account_error_message;

// clients.md, Settings > Account: an entitlement this close to its end without a refresh gets a notice.
const EXPIRING_SOON: TimeDelta = TimeDelta::days(3);
const OWNER: &str = "owner";

// product.md's codes, and whether TablePro for Linux has the feature yet.
const FEATURES: [(&str, bool); 10] = [
    ("icloud_sync", false),
    ("encrypted_export", false),
    ("env_var_references", false),
    ("linked_folders", false),
    ("query_insights", false),
    ("result_charts", false),
    ("compare_sync", false),
    ("data_rewind", false),
    ("team_catalog", false),
    ("team_library", false),
];

#[derive(Default)]
pub(crate) enum Fetch<T> {
    #[default]
    Idle,
    Loading,
    Loaded(T),
    Failed(AccountError),
}

pub(crate) struct Facts<'a> {
    pub status: &'a AccountStatus,
    pub profile: &'a Fetch<Profile>,
    pub devices: &'a Fetch<Vec<Device>>,
    pub machine_id: Option<&'a str>,
    pub now: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Mode {
    SignedOut,
    SignedIn,
    Offline,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Identity {
    pub name: String,
    pub email: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Notice {
    pub title: String,
    pub body: String,
    pub action: Option<NoticeAction>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum NoticeAction {
    ChooseDevice,
    Refresh,
    Open { label: String, path: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkRow {
    pub title: String,
    pub subtitle: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Listing<T> {
    Loading,
    Failed(String),
    Rows(Vec<T>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Plan {
    Free,
    Licenses(Vec<PlanRow>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PlanRow {
    pub title: String,
    pub subtitle: String,
    // The portal path of Billing…, for a license someone pays for and may manage.
    pub billing: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FeatureRow {
    pub title: String,
    pub included: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DeviceRow {
    pub id: String,
    pub name: String,
    pub subtitle: String,
    pub removal: Removal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Removal {
    ThisDevice,
    Allowed,
    KeptUntil(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Verification {
    pub title: String,
    pub subtitle: String,
}

pub(crate) fn mode(status: &AccountStatus) -> Mode {
    match status {
        AccountStatus::SignedOut => Mode::SignedOut,
        AccountStatus::SignedIn(_) => Mode::SignedIn,
        AccountStatus::Offline(_) => Mode::Offline,
    }
}

pub(crate) fn identity(facts: &Facts<'_>) -> Option<Identity> {
    let (email, name) = match (facts.profile, facts.status.entitlement()) {
        (Fetch::Loaded(profile), _) => (profile.email.clone(), profile.name.clone()),
        (_, Some(entitlement)) => {
            let account = &entitlement.claims().account;
            (account.email.clone(), Some(account.name.clone()))
        }
        _ => return None,
    };
    Some(match name.filter(|name| !name.trim().is_empty()) {
        Some(name) => Identity {
            name,
            email: Some(email),
        },
        None => Identity {
            name: email,
            email: None,
        },
    })
}

pub(crate) fn notices(facts: &Facts<'_>) -> Vec<Notice> {
    let AccountStatus::SignedIn(signed_in) = facts.status else {
        return offline_notices(facts);
    };
    let mut notices = Vec::new();
    let current = signed_in.entitlement.as_ref().filter(|it| it.is_current(facts.now));
    match (&signed_in.problem, current) {
        (Some(EntitlementProblem::DeviceLimitReached(devices)), _) => notices.push(device_limit(devices.len())),
        (Some(EntitlementProblem::RefreshFailed(error)), None) => notices.push(Notice {
            title: gettext("Could Not Verify Your Plan"),
            body: account_error_message(error),
            action: Some(NoticeAction::Refresh),
        }),
        (Some(EntitlementProblem::Expired), None) => notices.push(paused(signed_in)),
        (None, None) if signed_in.entitlement.is_some() => notices.push(paused(signed_in)),
        _ => {}
    }
    for license in licenses(facts) {
        if let Some(notice) = license_notice(license, billing(license, facts.profile), facts.now) {
            notices.push(notice);
        }
    }
    if let Some(entitlement) = current
        && let Some(notice) = expiring_soon(entitlement, facts.now)
    {
        notices.push(notice);
    }
    if !signed_in.remembered {
        notices.push(Notice {
            title: gettext("Sign-In Not Saved"),
            body: gettext("No keyring took the sign-in, so TablePro asks for it again the next time it starts."),
            action: None,
        });
    }
    notices
}

pub(crate) fn plan(facts: &Facts<'_>) -> Result<Plan, Listing<PlanRow>> {
    let known = matches!(facts.profile, Fetch::Loaded(_)) || facts.status.entitlement().is_some();
    if !known {
        return Err(match facts.profile {
            Fetch::Failed(error) => Listing::Failed(account_error_message(error)),
            Fetch::Idle | Fetch::Loading | Fetch::Loaded(_) => Listing::Loading,
        });
    }
    let rows: Vec<PlanRow> = licenses(facts)
        .into_iter()
        .map(|license| license_row(license, billing(license, facts.profile)))
        .collect();
    Ok(match rows.is_empty() {
        true => Plan::Free,
        false => Plan::Licenses(rows),
    })
}

pub(crate) fn features(facts: &Facts<'_>) -> Vec<FeatureRow> {
    features_in(&FEATURES, facts)
}

// The page lists only the features this computer can use (ADR 0042).
fn features_in(table: &[(&str, bool)], facts: &Facts<'_>) -> Vec<FeatureRow> {
    let current = facts.status.entitlement().filter(|it| it.is_current(facts.now));
    table
        .iter()
        .filter(|(_, on_linux)| *on_linux)
        .map(|(code, _)| FeatureRow {
            title: feature_name(code),
            included: current.is_some_and(|entitlement| entitlement.includes(code)),
        })
        .collect()
}

pub(crate) fn devices(facts: &Facts<'_>) -> Listing<DeviceRow> {
    let devices = match facts.devices {
        Fetch::Idle | Fetch::Loading => return Listing::Loading,
        Fetch::Failed(error) => return Listing::Failed(account_error_message(error)),
        Fetch::Loaded(devices) => devices,
    };
    let mut sorted: Vec<&Device> = devices.iter().collect();
    sorted.sort_by_key(|device| {
        (
            Some(device.machine_id.as_str()) != facts.machine_id,
            Reverse(device.last_seen_at),
        )
    });
    let rows = sorted
        .into_iter()
        .map(|device| {
            let this_device = Some(device.machine_id.as_str()) == facts.machine_id;
            let mut parts = Vec::new();
            if this_device {
                parts.push(gettext("This computer"));
            }
            parts.push(system(device));
            if !this_device {
                parts.push(last_active(device.last_seen_at, facts.now));
            }
            DeviceRow {
                id: device.id.clone(),
                name: device.name.clone(),
                subtitle: parts.join(" · "),
                removal: match this_device {
                    true => Removal::ThisDevice,
                    false => removal(device, facts.now),
                },
            }
        })
        .collect();
    Listing::Rows(rows)
}

// The devices device_limit_reached names, each with its offline_until.
pub(crate) fn limit_devices(holding: &[Device], now: DateTime<Utc>) -> Vec<DeviceRow> {
    holding
        .iter()
        .map(|device| DeviceRow {
            id: device.id.clone(),
            name: device.name.clone(),
            subtitle: [system(device), last_active(device.last_seen_at, now)].join(" · "),
            removal: removal(device, now),
        })
        .collect()
}

pub(crate) fn teams(profile: &Fetch<Profile>) -> Listing<LinkRow> {
    let profile = match profile {
        Fetch::Idle | Fetch::Loading => return Listing::Loading,
        Fetch::Failed(error) => return Listing::Failed(account_error_message(error)),
        Fetch::Loaded(profile) => profile,
    };
    let rows = profile
        .teams
        .iter()
        .map(|membership| {
            let seat = match membership.has_seat {
                true => gettext("Holds a seat"),
                false => gettext("No seat"),
            };
            let subtitle = match role_name(&membership.role) {
                Some(role) => [role, seat].join(" · "),
                None => seat,
            };
            LinkRow {
                title: membership.team.name.clone(),
                subtitle,
                path: format!("/teams/{}", membership.team.id),
            }
        })
        .collect();
    Listing::Rows(rows)
}

pub(crate) fn verification(facts: &Facts<'_>) -> Option<Verification> {
    match facts.status {
        AccountStatus::SignedOut => None,
        AccountStatus::Offline(entitlement) => Some(Verification {
            title: gettext("Offline File"),
            subtitle: validity(entitlement, facts.now),
        }),
        AccountStatus::SignedIn(signed_in) => {
            let Some(entitlement) = &signed_in.entitlement else {
                return Some(Verification {
                    title: gettext("Not Verified Yet"),
                    subtitle: gettext("TablePro checks your plan with the account service once a day."),
                });
            };
            let issued = DateTime::from_timestamp(entitlement.claims().iat, 0).unwrap_or(facts.now);
            let mut subtitle = validity(entitlement, facts.now);
            if let Some(EntitlementProblem::RefreshFailed(error)) = &signed_in.problem {
                subtitle = gettext_f(
                    "{validity}. The last check failed: {reason}",
                    &[("validity", &subtitle), ("reason", &account_error_message(error))],
                );
            }
            Some(Verification {
                title: gettext_f("Verified {when}", &[("when", &ago(issued, facts.now))]),
                subtitle,
            })
        }
    }
}

pub(crate) fn plan_name(code: &str) -> String {
    match code {
        "starter" => gettext("Pro"),
        "team" => gettext("Team"),
        _ => gettext("License"),
    }
}

pub(crate) fn cycle_name(code: &str) -> Option<String> {
    match code {
        "monthly" => Some(gettext("Monthly")),
        "yearly" => Some(gettext("Yearly")),
        "lifetime" => Some(gettext("Lifetime")),
        _ => None,
    }
}

pub(crate) fn role_name(code: &str) -> Option<String> {
    match code {
        OWNER => Some(gettext("Owner")),
        "admin" => Some(gettext("Admin")),
        "member" => Some(gettext("Member")),
        _ => None,
    }
}

// A status this build does not know says nothing rather than something wrong.
pub(crate) fn license_state(license: &LicenseClaim) -> Option<String> {
    let ends = license
        .ends_at
        .map(|at| gettext_f("Ends on {date}", &[("date", &day(at))]));
    match license.status.as_str() {
        "past_due" => Some(gettext("Payment problem")),
        "canceling" => ends.or_else(|| Some(gettext("Ending"))),
        "active" if ends.is_some() => ends,
        "active" => match license.renews_at {
            Some(at) => Some(gettext_f("Renews on {date}", &[("date", &day(at))])),
            // The row's cycle says Lifetime already.
            None if billed(license) && license.cycle == "lifetime" => None,
            None => Some(gettext("Active")),
        },
        _ => None,
    }
}

// As the portal: nothing bills a license an admin granted or the migration brought over, so it has no cycle.
fn billed(license: &LicenseClaim) -> bool {
    matches!(license.source.as_str(), "subscription" | "order")
}

pub(crate) fn day(at: DateTime<Utc>) -> String {
    glib::DateTime::from_unix_local(at.timestamp())
        .and_then(|local| local.format("%x"))
        .map(String::from)
        .unwrap_or_else(|_| at.format("%Y-%m-%d").to_string())
}

pub(crate) fn ago(when: DateTime<Utc>, now: DateTime<Utc>) -> String {
    let seconds = (now - when).num_seconds().max(0);
    let count = |n: i64| (u32::try_from(n).unwrap_or(u32::MAX), n.to_string());
    if seconds < 60 {
        gettext("just now")
    } else if seconds < 3_600 {
        let (n, text) = count(seconds / 60);
        ngettext_f("{n} minute ago", "{n} minutes ago", n, &[("n", &text)])
    } else if seconds < 86_400 {
        let (n, text) = count(seconds / 3_600);
        ngettext_f("{n} hour ago", "{n} hours ago", n, &[("n", &text)])
    } else if seconds < 30 * 86_400 {
        let (n, text) = count(seconds / 86_400);
        ngettext_f("{n} day ago", "{n} days ago", n, &[("n", &text)])
    } else {
        day(when)
    }
}

fn offline_notices(facts: &Facts<'_>) -> Vec<Notice> {
    let AccountStatus::Offline(entitlement) = facts.status else {
        return Vec::new();
    };
    if entitlement.is_current(facts.now) {
        return Vec::new();
    }
    vec![Notice {
        title: gettext("Offline File Expired"),
        body: gettext_f(
            "It expired on {date}. Import a new one, or sign in.",
            &[("date", &day(entitlement.expires_at()))],
        ),
        action: None,
    }]
}

fn device_limit(others: usize) -> Notice {
    let count = u32::try_from(others).unwrap_or(u32::MAX);
    Notice {
        title: gettext("Device Limit Reached"),
        body: ngettext_f(
            "Your license is in use on {n} other device. Remove one to use it on this computer, or keep using TablePro here without it.",
            "Your license is in use on {n} other devices. Remove one to use it on this computer, or keep using TablePro here without it.",
            count,
            &[("n", &count.to_string())],
        ),
        action: Some(NoticeAction::ChooseDevice),
    }
}

fn paused(signed_in: &SignedIn) -> Notice {
    let body = match &signed_in.entitlement {
        Some(entitlement) => gettext_f(
            "The last verification of your plan ran out on {date}. Connect to the internet and refresh.",
            &[("date", &day(entitlement.expires_at()))],
        ),
        None => gettext("The last verification of your plan ran out. Connect to the internet and refresh."),
    };
    Notice {
        title: gettext("Could Not Verify Your Plan"),
        body,
        action: Some(NoticeAction::Refresh),
    }
}

fn license_notice(license: &LicenseClaim, billing: Billing, now: DateTime<Utc>) -> Option<Notice> {
    let plan = match &license.team {
        Some(team) => gettext_f(
            "{plan} for {team}",
            &[("plan", &plan_name(&license.plan)), ("team", &team.name)],
        ),
        None => plan_name(&license.plan),
    };
    match license.status.as_str() {
        "past_due" => {
            let body = match &billing {
                Billing::Opens(_) => gettext_f(
                    "Polar could not charge the card for {plan}. It stays active while Polar tries again. Update the payment method to keep it.",
                    &[("plan", &plan)],
                ),
                Billing::TeamOwnerOnly => gettext_f(
                    "Polar could not charge the card for {plan}. It stays active while Polar tries again. Only the team’s owner can update the payment method.",
                    &[("plan", &plan)],
                ),
                Billing::Unavailable => gettext_f(
                    "Polar could not charge the card for {plan}. It stays active while Polar tries again.",
                    &[("plan", &plan)],
                ),
            };
            Some(Notice {
                title: gettext("Payment Problem"),
                body,
                action: billing.path().map(|path| NoticeAction::Open {
                    label: gettext("Update Payment Method…"),
                    path,
                }),
            })
        }
        "canceling" => {
            let ends = day(license.ends_at.filter(|at| *at > now)?);
            let values = [("plan", plan.as_str()), ("date", ends.as_str())];
            let body = match &billing {
                Billing::Opens(_) => gettext_f("{plan} is set to end on {date}. Resume it to keep it.", &values),
                Billing::TeamOwnerOnly => gettext_f(
                    "{plan} is set to end on {date}. Only the team’s owner can resume it.",
                    &values,
                ),
                Billing::Unavailable => gettext_f("{plan} is set to end on {date}.", &values),
            };
            Some(Notice {
                title: gettext("Plan Ending"),
                body,
                action: billing.path().map(|path| NoticeAction::Open {
                    label: gettext("Billing…"),
                    path,
                }),
            })
        }
        _ => None,
    }
}

// A license that ends inside the window has its own notice; this one is for a refresh that never came.
fn expiring_soon(entitlement: &Entitlement, now: DateTime<Utc>) -> Option<Notice> {
    let expires = entitlement.expires_at();
    if expires - now > EXPIRING_SOON {
        return None;
    }
    let license_ends = entitlement
        .claims()
        .licenses
        .iter()
        .filter_map(|license| license.ends_at)
        .any(|ends| ends <= expires + TimeDelta::days(1));
    if license_ends {
        return None;
    }
    let issued = DateTime::from_timestamp(entitlement.claims().iat, 0).unwrap_or(now);
    Some(Notice {
        title: gettext("Plan Not Verified Lately"),
        body: gettext_f(
            "TablePro last verified your plan {when}. The verification runs out on {date} unless TablePro reaches the account service again.",
            &[("when", &ago(issued, now)), ("date", &day(expires))],
        ),
        action: Some(NoticeAction::Refresh),
    })
}

fn licenses<'a>(facts: &'a Facts<'_>) -> Vec<&'a LicenseClaim> {
    match (facts.profile, facts.status.entitlement()) {
        (Fetch::Loaded(profile), _) => profile.licenses.iter().collect(),
        (_, Some(entitlement)) => entitlement.claims().licenses.iter().collect(),
        _ => Vec::new(),
    }
}

fn license_row(license: &LicenseClaim, billing: Billing) -> PlanRow {
    let owner = license
        .team
        .as_ref()
        .map_or_else(|| gettext("Personal"), |team| team.name.clone());
    let cycle = cycle_name(&license.cycle).filter(|_| billed(license));
    let parts: Vec<String> = [cycle, Some(owner), license_state(license)]
        .into_iter()
        .flatten()
        .collect();
    PlanRow {
        title: plan_name(&license.plan),
        subtitle: parts.join(" · "),
        billing: billing.path(),
    }
}

// The portal lets only a team's owner into its billing, and only the profile names the role.
enum Billing {
    Opens(String),
    TeamOwnerOnly,
    // Not billed, or the role is not known yet.
    Unavailable,
}

impl Billing {
    fn path(self) -> Option<String> {
        match self {
            Self::Opens(path) => Some(path),
            Self::TeamOwnerOnly | Self::Unavailable => None,
        }
    }
}

fn billing(license: &LicenseClaim, profile: &Fetch<Profile>) -> Billing {
    if !billed(license) {
        return Billing::Unavailable;
    }
    let Some(team) = &license.team else {
        return Billing::Opens("/billing".to_owned());
    };
    let Fetch::Loaded(profile) = profile else {
        return Billing::Unavailable;
    };
    let owner = profile
        .teams
        .iter()
        .any(|membership| membership.team.id == team.id && membership.role == OWNER);
    match owner {
        true => Billing::Opens(format!("/teams/{}/billing", team.id)),
        false => Billing::TeamOwnerOnly,
    }
}

fn removal(device: &Device, now: DateTime<Utc>) -> Removal {
    match device.offline_until.filter(|_| device.offline_file_active(now)) {
        Some(until) => Removal::KeptUntil(gettext_f("Offline file until {date}", &[("date", &day(until))])),
        None => Removal::Allowed,
    }
}

fn system(device: &Device) -> String {
    match device.platform.as_str() {
        "macos" => gettext_f("macOS {version}", &[("version", &device.os_version)]),
        _ => device.os_version.clone(),
    }
}

fn last_active(seen: DateTime<Utc>, now: DateTime<Utc>) -> String {
    gettext_f("Last active {when}", &[("when", &ago(seen, now))])
}

fn validity(entitlement: &Entitlement, now: DateTime<Utc>) -> String {
    let date = day(entitlement.expires_at());
    match entitlement.is_current(now) {
        true => gettext_f("Valid until {date}", &[("date", &date)]),
        false => gettext_f("Expired on {date}", &[("date", &date)]),
    }
}

fn feature_name(code: &str) -> String {
    match code {
        "icloud_sync" => gettext("iCloud Sync"),
        "encrypted_export" => gettext("Encrypted Export"),
        "env_var_references" => gettext("Environment Variables"),
        "linked_folders" => gettext("Linked Folders"),
        "query_insights" => gettext("Query Insights"),
        "result_charts" => gettext("Result Charts"),
        "compare_sync" => gettext("Compare and Sync"),
        "data_rewind" => gettext("Data Rewind"),
        "team_catalog" => gettext("Team Catalog"),
        "team_library" => gettext("Team Library"),
        other => other.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_account::{EntitlementClaims, Membership, SignedIn, TeamClaim, fakes};

    use super::*;

    const MACHINE: &str = fakes::MACHINE;

    fn license(plan: &str, cycle: &str, status: &str, team: Option<&str>) -> LicenseClaim {
        LicenseClaim {
            id: "lic_01".to_owned(),
            plan: plan.to_owned(),
            cycle: cycle.to_owned(),
            source: "subscription".to_owned(),
            status: status.to_owned(),
            renews_at: None,
            ends_at: None,
            team: team.map(|name| TeamClaim {
                id: "team_01".to_owned(),
                name: name.to_owned(),
            }),
        }
    }

    fn entitlement(issued: DateTime<Utc>, lasts: TimeDelta, licenses: Vec<LicenseClaim>) -> Entitlement {
        let mut claims: EntitlementClaims = fakes::claims(issued, lasts, &["env_var_references", "data_rewind"]);
        claims.licenses = licenses;
        fakes::entitlement(&claims).expect("an entitlement")
    }

    fn signed_in(entitlement: Option<Entitlement>, problem: Option<EntitlementProblem>) -> AccountStatus {
        AccountStatus::SignedIn(Box::new(SignedIn {
            entitlement,
            problem,
            remembered: true,
        }))
    }

    fn device(id: &str, machine_id: &str, seen: DateTime<Utc>) -> Device {
        Device {
            id: id.to_owned(),
            machine_id: machine_id.to_owned(),
            platform: "linux".to_owned(),
            name: format!("Device {id}"),
            app_version: "0.1.0".to_owned(),
            os_version: "Ubuntu 26.04".to_owned(),
            last_seen_at: seen,
            licensed_at: Some(seen),
            offline_until: None,
        }
    }

    fn facts<'a>(
        status: &'a AccountStatus,
        profile: &'a Fetch<Profile>,
        devices: &'a Fetch<Vec<Device>>,
        now: DateTime<Utc>,
    ) -> Facts<'a> {
        Facts {
            status,
            profile,
            devices,
            machine_id: Some(MACHINE),
            now,
        }
    }

    #[test]
    fn the_starter_tier_reads_pro_as_on_macos_and_the_website() {
        assert_eq!(plan_name("starter"), "Pro");
        assert_eq!(plan_name("team"), "Team");
        assert_eq!(
            license_row(&license("starter", "yearly", "active", None), Billing::Unavailable).title,
            "Pro"
        );
    }

    #[test]
    fn plans_cycles_statuses_and_roles_this_build_does_not_know_read_neutrally() {
        let unknown = license("enterprise", "quarterly", "paused", None);
        let mut unknown_ending = unknown.clone();
        unknown_ending.ends_at = Some(Utc::now() + TimeDelta::days(10));

        assert_eq!(plan_name("enterprise"), "License");
        assert_eq!(cycle_name("quarterly"), None);
        assert_eq!(role_name("billing_manager"), None);
        assert_eq!(license_state(&unknown), None);
        let row = license_row(&unknown, billing(&unknown, &Fetch::Idle));
        assert_eq!(row.title, "License");
        assert_eq!(row.subtitle, "Personal");
        assert_eq!(license_state(&unknown_ending), None);
        assert_eq!(
            license_row(&unknown_ending, billing(&unknown_ending, &Fetch::Idle)).subtitle,
            "Personal"
        );
        assert_eq!(
            license_notice(&unknown, billing(&unknown, &Fetch::Idle), Utc::now()),
            None
        );
    }

    #[test]
    fn a_license_says_its_cycle_owner_and_state() {
        let now = Utc::now();
        let mut ending = license("starter", "yearly", "canceling", None);
        ending.ends_at = Some(now + TimeDelta::days(10));
        let mut lifetime = license("starter", "lifetime", "active", None);
        lifetime.source = "order".to_owned();
        let mut renewing = license("team", "monthly", "active", Some("Acme"));
        renewing.renews_at = Some(now + TimeDelta::days(20));
        let unrenewed = license("starter", "monthly", "active", None);
        let past_due = license("team", "yearly", "past_due", Some("Acme"));
        let row = |license: &LicenseClaim| license_row(license, billing(license, &Fetch::Idle));

        assert_eq!(row(&lifetime).subtitle, "Lifetime · Personal");
        assert_eq!(
            row(&renewing).subtitle,
            format!("Monthly · Acme · Renews on {}", day(now + TimeDelta::days(20)))
        );
        assert_eq!(row(&unrenewed).subtitle, "Monthly · Personal · Active");
        assert_eq!(row(&past_due).subtitle, "Yearly · Acme · Payment problem");
        assert_eq!(
            row(&ending).subtitle,
            format!("Yearly · Personal · Ends on {}", day(now + TimeDelta::days(10)))
        );
    }

    #[test]
    fn a_license_nobody_pays_for_shows_its_plan_and_state_without_a_cycle_or_billing() {
        let now = Utc::now();
        let owner = holding(Vec::new(), vec![membership("team_01", "owner")]);
        let paid = |source: &str, team: Option<&str>| {
            let mut paid = license("starter", "lifetime", "active", team);
            paid.source = source.to_owned();
            license_row(&paid, billing(&paid, &owner))
        };
        let granted = |source: &str, ends_at: Option<DateTime<Utc>>| {
            let mut granted = license("team", "lifetime", "active", Some("Acme"));
            granted.source = source.to_owned();
            granted.ends_at = ends_at;
            license_row(&granted, billing(&granted, &owner))
        };
        let ends = now + TimeDelta::days(30);

        assert_eq!(paid("subscription", None).billing.as_deref(), Some("/billing"));
        assert_eq!(paid("order", None).billing.as_deref(), Some("/billing"));
        assert_eq!(
            paid("order", Some("Acme")).billing.as_deref(),
            Some("/teams/team_01/billing")
        );
        for source in ["manual", "legacy", "reseller"] {
            let open = granted(source, None);
            let ending = granted(source, Some(ends));

            assert_eq!((open.title.as_str(), open.billing), ("Team", None), "{source}");
            assert_eq!(open.subtitle, "Acme · Active", "{source}");
            assert_eq!(ending.subtitle, format!("Acme · Ends on {}", day(ends)), "{source}");
            assert_eq!(ending.billing, None, "{source}");
        }
    }

    #[test]
    fn a_team_license_opens_billing_for_the_teams_owner_only() {
        let team_plan = license("team", "yearly", "active", Some("Acme"));
        let billing_for = |profile: &Fetch<Profile>| license_row(&team_plan, billing(&team_plan, profile)).billing;

        let owner = billing_for(&holding(Vec::new(), vec![membership("team_01", "owner")]));
        let admin = billing_for(&holding(Vec::new(), vec![membership("team_01", "admin")]));
        let unknown = billing_for(&Fetch::Loading);

        assert_eq!(owner.as_deref(), Some("/teams/team_01/billing"));
        assert_eq!(admin, None);
        assert_eq!(unknown, None);
    }

    fn membership(team: &str, role: &str) -> Membership {
        Membership {
            team: TeamClaim {
                id: team.to_owned(),
                name: "Acme".to_owned(),
            },
            role: role.to_owned(),
            has_seat: true,
        }
    }

    fn holding(licenses: Vec<LicenseClaim>, teams: Vec<Membership>) -> Fetch<Profile> {
        Fetch::Loaded(Profile {
            id: "acct_01".to_owned(),
            email: "ada@m17.example".to_owned(),
            name: None,
            licenses,
            teams,
        })
    }

    #[test]
    fn a_payment_problem_and_a_cancellation_get_notices_that_open_billing() {
        let now = Utc::now();
        let mut ending = license("starter", "monthly", "canceling", None);
        ending.ends_at = Some(now + TimeDelta::days(5));
        let licenses = vec![license("team", "yearly", "past_due", Some("Acme")), ending];
        let status = signed_in(Some(entitlement(now, TimeDelta::days(5), licenses.clone())), None);
        let profile = holding(licenses, vec![membership("team_01", "owner")]);
        let devices = Fetch::Idle;

        let notices = notices(&facts(&status, &profile, &devices, now));

        assert_eq!(notices.len(), 2, "{notices:#?}");
        assert_eq!(notices[0].title, "Payment Problem");
        assert_eq!(
            notices[0].action,
            Some(NoticeAction::Open {
                label: "Update Payment Method…".to_owned(),
                path: "/teams/team_01/billing".to_owned(),
            })
        );
        assert!(notices[0].body.contains("for Team for Acme."), "{}", notices[0].body);
        assert!(notices[0].body.ends_with("Update the payment method to keep it."));
        assert_eq!(notices[1].title, "Plan Ending");
        assert!(
            notices[1].body.starts_with("Pro is set to end on "),
            "{}",
            notices[1].body
        );
        assert_eq!(
            notices[1].action,
            Some(NoticeAction::Open {
                label: "Billing…".to_owned(),
                path: "/billing".to_owned(),
            })
        );
    }

    #[test]
    fn a_team_plan_only_its_owner_can_fix_opens_no_billing_for_an_admin_a_member_or_an_unknown_role() {
        let now = Utc::now();
        let past_due = license("team", "yearly", "past_due", Some("Acme"));
        let mut ending = license("team", "monthly", "canceling", Some("Acme"));
        ending.ends_at = Some(now + TimeDelta::days(5));
        let devices = Fetch::Idle;
        let notices_for = |licenses: Vec<LicenseClaim>, membership: Option<Membership>| {
            let profile = membership.map_or(Fetch::Idle, |membership| holding(licenses.clone(), vec![membership]));
            let status = signed_in(Some(entitlement(now, TimeDelta::days(14), licenses)), None);
            notices(&facts(&status, &profile, &devices, now))
        };

        let admin = notices_for(vec![past_due.clone()], Some(self::membership("team_01", "admin")));
        let member = notices_for(vec![ending.clone()], Some(self::membership("team_01", "member")));
        let owns_another = notices_for(vec![past_due.clone()], Some(self::membership("team_02", "owner")));
        let unknown = notices_for(vec![past_due, ending], None);

        assert_eq!(admin[0].action, None);
        assert!(
            admin[0]
                .body
                .ends_with("Only the team’s owner can update the payment method."),
            "{}",
            admin[0].body
        );
        assert_eq!(member[0].action, None);
        assert!(
            member[0].body.ends_with("Only the team’s owner can resume it."),
            "{}",
            member[0].body
        );
        assert_eq!(owns_another[0].action, None);
        assert_eq!(unknown.len(), 2, "{unknown:#?}");
        assert!(unknown.iter().all(|notice| notice.action.is_none()), "{unknown:#?}");
        assert!(
            unknown.iter().all(|notice| !notice.body.contains("owner")),
            "{unknown:#?}"
        );
    }

    #[test]
    fn an_entitlement_near_its_end_without_a_refresh_gets_a_notice_and_a_license_ending_does_not() {
        let now = Utc::now();
        let stale = signed_in(
            Some(entitlement(now - TimeDelta::days(12), TimeDelta::days(14), Vec::new())),
            None,
        );
        let mut ending = license("starter", "monthly", "canceling", None);
        ending.ends_at = Some(now + TimeDelta::days(2));
        let ending_soon = signed_in(Some(entitlement(now, TimeDelta::days(2), vec![ending])), None);
        let (profile, devices) = (Fetch::Idle, Fetch::Idle);

        let stale_notices = notices(&facts(&stale, &profile, &devices, now));
        let ending_notices = notices(&facts(&ending_soon, &profile, &devices, now));

        assert_eq!(stale_notices.len(), 1);
        assert_eq!(stale_notices[0].title, "Plan Not Verified Lately");
        assert_eq!(stale_notices[0].action, Some(NoticeAction::Refresh));
        assert!(
            ending_notices
                .iter()
                .all(|notice| notice.title != "Plan Not Verified Lately")
        );
    }

    #[test]
    fn the_device_limit_and_a_failed_refresh_say_so_and_a_kept_entitlement_keeps_quiet() {
        let now = Utc::now();
        let others = vec![
            device("dev_a", "a", now),
            device("dev_b", "b", now),
            device("dev_c", "c", now),
        ];
        let limited = signed_in(None, Some(EntitlementProblem::DeviceLimitReached(others)));
        let offline = AccountError::Unreachable("refused".to_owned());
        let failed = signed_in(None, Some(EntitlementProblem::RefreshFailed(offline.clone())));
        let kept = signed_in(
            Some(entitlement(now, TimeDelta::days(14), Vec::new())),
            Some(EntitlementProblem::RefreshFailed(offline)),
        );
        let (profile, devices) = (Fetch::Idle, Fetch::Idle);

        let limited = notices(&facts(&limited, &profile, &devices, now));
        let failed = notices(&facts(&failed, &profile, &devices, now));
        let kept_notices = notices(&facts(&kept, &profile, &devices, now));
        let kept_verification = verification(&facts(&kept, &profile, &devices, now)).expect("a verification");

        assert_eq!(limited[0].title, "Device Limit Reached");
        assert_eq!(
            limited[0].body,
            "Your license is in use on 3 other devices. Remove one to use it on this computer, or keep using TablePro here without it."
        );
        assert_eq!(limited[0].action, Some(NoticeAction::ChooseDevice));
        assert_eq!(failed[0].title, "Could Not Verify Your Plan");
        assert!(kept_notices.is_empty(), "{kept_notices:#?}");
        assert_eq!(kept_verification.title, "Verified just now");
        assert!(kept_verification.subtitle.contains("The last check failed"));
    }

    #[test]
    fn this_device_comes_first_and_a_device_with_an_offline_file_cannot_be_removed() {
        let now = Utc::now();
        let mut held = device("dev_held", "held", now - TimeDelta::days(3));
        held.offline_until = Some(now + TimeDelta::days(200));
        let listed = vec![
            device("dev_old", "old", now - TimeDelta::days(9)),
            held,
            device("dev_here", MACHINE, now),
        ];
        let status = signed_in(None, None);
        let (profile, devices) = (Fetch::Idle, Fetch::Loaded(listed));

        let Listing::Rows(rows) = self::devices(&facts(&status, &profile, &devices, now)) else {
            panic!("rows");
        };

        let ids: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
        assert_eq!(ids, ["dev_here", "dev_held", "dev_old"]);
        assert_eq!(rows[0].removal, Removal::ThisDevice);
        assert!(rows[0].subtitle.starts_with("This computer · "));
        assert!(matches!(&rows[1].removal, Removal::KeptUntil(text) if text.starts_with("Offline file until ")));
        assert_eq!(rows[2].removal, Removal::Allowed);
        assert!(
            rows[2].subtitle.ends_with("Last active 9 days ago"),
            "{}",
            rows[2].subtitle
        );
    }

    #[test]
    fn the_limit_dialog_keeps_a_holder_whose_offline_file_is_valid() {
        let now = Utc::now();
        let mut holders = vec![
            device("dev_a", "a", now),
            device("dev_b", "b", now),
            device("dev_c", "c", now),
        ];
        holders[1].offline_until = Some(now + TimeDelta::days(30));
        holders[2].offline_until = Some(now - TimeDelta::days(1));

        let rows = limit_devices(&holders, now);

        assert_eq!(rows[0].removal, Removal::Allowed);
        assert_eq!(
            rows[1].removal,
            Removal::KeptUntil(format!("Offline file until {}", day(now + TimeDelta::days(30))))
        );
        assert_eq!(rows[2].removal, Removal::Allowed);
    }

    #[test]
    fn teams_name_the_role_and_the_seat() {
        let profile = Fetch::Loaded(Profile {
            id: "acct_01".to_owned(),
            email: "ada@m17.example".to_owned(),
            name: None,
            licenses: Vec::new(),
            teams: vec![
                Membership {
                    team: TeamClaim {
                        id: "team_01".to_owned(),
                        name: "Acme".to_owned(),
                    },
                    role: "member".to_owned(),
                    has_seat: true,
                },
                Membership {
                    team: TeamClaim {
                        id: "team_02".to_owned(),
                        name: "Globex".to_owned(),
                    },
                    role: "auditor".to_owned(),
                    has_seat: false,
                },
            ],
        });

        let Listing::Rows(rows) = teams(&profile) else {
            panic!("rows");
        };

        assert_eq!(rows[0].subtitle, "Member · Holds a seat");
        assert_eq!(rows[1].subtitle, "No seat");
        assert_eq!(rows[1].path, "/teams/team_02");
    }

    #[test]
    fn a_free_account_is_free_once_known_and_loading_before() {
        let now = Utc::now();
        let status = signed_in(None, None);
        let loading = Fetch::Loading;
        let free = Fetch::Loaded(Profile {
            id: "acct_01".to_owned(),
            email: "ada@m17.example".to_owned(),
            name: Some("Ada".to_owned()),
            licenses: Vec::new(),
            teams: Vec::new(),
        });
        let devices = Fetch::Idle;

        assert_eq!(plan(&facts(&status, &loading, &devices, now)), Err(Listing::Loading));
        assert_eq!(plan(&facts(&status, &free, &devices, now)), Ok(Plan::Free));
        assert_eq!(
            identity(&facts(&status, &free, &devices, now)),
            Some(Identity {
                name: "Ada".to_owned(),
                email: Some("ada@m17.example".to_owned()),
            })
        );
    }

    #[test]
    fn only_the_features_linux_has_are_listed_and_only_a_current_entitlement_includes_them() {
        let now = Utc::now();
        let current = signed_in(Some(entitlement(now, TimeDelta::days(14), Vec::new())), None);
        let lapsed = signed_in(
            Some(entitlement(now - TimeDelta::days(20), TimeDelta::days(14), Vec::new())),
            None,
        );
        let (profile, devices) = (Fetch::Idle, Fetch::Idle);
        let table = [
            ("env_var_references", true),
            ("result_charts", true),
            ("data_rewind", false),
        ];
        let row = |title: &str, included: bool| FeatureRow {
            title: title.to_owned(),
            included,
        };
        let listed = |table: &[(&str, bool)], status: &AccountStatus| {
            features_in(table, &facts(status, &profile, &devices, now))
        };

        assert_eq!(
            listed(&table, &current),
            [row("Environment Variables", true), row("Result Charts", false)]
        );
        assert_eq!(
            listed(&table, &lapsed),
            [row("Environment Variables", false), row("Result Charts", false)]
        );
        assert_eq!(
            listed(&table, &AccountStatus::SignedOut),
            [row("Environment Variables", false), row("Result Charts", false)]
        );
        assert!(listed(&[("data_rewind", false), ("result_charts", false)], &current).is_empty());
    }

    #[test]
    fn the_limit_and_verification_notices_speak_of_the_license_and_the_plan_for_free_and_pro_alike() {
        let now = Utc::now();
        let (profile, devices) = (Fetch::Idle, Fetch::Idle);
        let notices_for = |status: &AccountStatus| notices(&facts(status, &profile, &devices, now));
        let one_other = signed_in(
            None,
            Some(EntitlementProblem::DeviceLimitReached(vec![device("dev_a", "a", now)])),
        );
        let never_verified = signed_in(None, Some(EntitlementProblem::Expired));
        let mut shown = notices_for(&one_other);
        shown.extend(notices_for(&never_verified));

        assert_eq!(
            shown[0].body,
            "Your license is in use on 1 other device. Remove one to use it on this computer, or keep using TablePro here without it."
        );
        assert_eq!(shown[1].title, "Could Not Verify Your Plan");
        assert_eq!(
            shown[1].body,
            "The last verification of your plan ran out. Connect to the internet and refresh."
        );
        for licenses in [Vec::new(), vec![license("starter", "yearly", "active", None)]] {
            let lapsed = entitlement(now - TimeDelta::days(20), TimeDelta::days(14), licenses.clone());
            let stale = entitlement(now - TimeDelta::days(12), TimeDelta::days(14), licenses);
            let (ran_out, runs_out) = (day(lapsed.expires_at()), day(stale.expires_at()));
            let ran_out_notices = notices_for(&signed_in(Some(lapsed), None));
            let stale_notices = notices_for(&signed_in(Some(stale), None));

            assert_eq!(ran_out_notices.len(), 1, "{ran_out_notices:#?}");
            assert_eq!(ran_out_notices[0].title, "Could Not Verify Your Plan");
            assert_eq!(
                ran_out_notices[0].body,
                format!(
                    "The last verification of your plan ran out on {ran_out}. Connect to the internet and refresh."
                )
            );
            assert_eq!(stale_notices.len(), 1, "{stale_notices:#?}");
            assert_eq!(stale_notices[0].title, "Plan Not Verified Lately");
            assert_eq!(
                stale_notices[0].body,
                format!(
                    "TablePro last verified your plan 12 days ago. The verification runs out on {runs_out} unless TablePro reaches the account service again."
                )
            );
            shown.extend(ran_out_notices);
            shown.extend(stale_notices);
        }
        for notice in &shown {
            for text in [&notice.title, &notice.body] {
                assert!(
                    !text.contains("paid features") && !text.contains("free features"),
                    "{text}"
                );
            }
        }
    }
}
