use chrono::{DateTime, Utc};

use crate::cloud_api::v2::types;
use crate::entitlement::{LicenseClaim, TeamClaim};

// Codes stay strings: a plan, cycle, status or role the app does not know still shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Profile {
    pub id: String,
    pub email: String,
    pub name: Option<String>,
    pub licenses: Vec<LicenseClaim>,
    pub teams: Vec<Membership>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Membership {
    pub team: TeamClaim,
    pub role: String,
    pub has_seat: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Device {
    pub id: String,
    pub machine_id: String,
    pub platform: String,
    pub name: String,
    pub app_version: String,
    pub os_version: String,
    pub last_seen_at: DateTime<Utc>,
    pub licensed_at: Option<DateTime<Utc>>,
    pub offline_until: Option<DateTime<Utc>>,
}

impl Device {
    // Removing it before then is refused with offline_file_active.
    pub fn offline_file_active(&self, now: DateTime<Utc>) -> bool {
        self.offline_until.is_some_and(|until| until > now)
    }
}

impl From<types::Me> for Profile {
    fn from(me: types::Me) -> Self {
        Self {
            id: me.account.id,
            email: me.account.email,
            name: me.account.name.filter(|name| !name.trim().is_empty()),
            licenses: me.licenses.into_iter().map(license).collect(),
            teams: me
                .teams
                .into_iter()
                .map(|membership| Membership {
                    team: team(membership.team),
                    role: membership.role,
                    has_seat: membership.has_seat,
                })
                .collect(),
        }
    }
}

impl From<types::Device> for Device {
    fn from(device: types::Device) -> Self {
        Self {
            id: device.id,
            machine_id: device.machine_id,
            platform: device.platform,
            name: device.name,
            app_version: device.app_version,
            os_version: device.os_version,
            last_seen_at: device.last_seen_at,
            licensed_at: device.licensed_at,
            offline_until: device.offline_until,
        }
    }
}

impl From<types::LicensedDevice> for Device {
    fn from(device: types::LicensedDevice) -> Self {
        Self {
            id: device.id,
            machine_id: device.machine_id,
            platform: device.platform,
            name: device.name,
            app_version: device.app_version,
            os_version: device.os_version,
            last_seen_at: device.last_seen_at,
            licensed_at: Some(device.licensed_at),
            offline_until: device.offline_until,
        }
    }
}

fn license(license: types::License) -> LicenseClaim {
    LicenseClaim {
        id: license.id,
        plan: license.plan,
        cycle: license.cycle,
        source: license.source,
        status: license.status,
        renews_at: license.renews_at,
        ends_at: license.ends_at,
        team: license.team.map(team),
    }
}

fn team(team: types::TeamRef) -> TeamClaim {
    TeamClaim {
        id: team.id,
        name: team.name,
    }
}

#[cfg(test)]
mod tests {
    use chrono::TimeDelta;

    use super::*;

    fn me(json: &str) -> Profile {
        serde_json::from_str::<types::Me>(json).expect("a /v2/me answer").into()
    }

    #[test]
    fn me_reads_as_the_wire_codes() {
        let profile = me(r#"{
            "account": { "id": "acct_01", "email": "ada@m17.example", "name": "Ada" },
            "licenses": [{
                "id": "lic_01", "plan": "team", "cycle": "yearly", "source": "subscription",
                "status": "past_due", "team": { "id": "team_01", "name": "Acme" }
            }, {
                "id": "lic_02", "plan": "starter", "cycle": "monthly", "source": "subscription",
                "status": "active", "renews_at": "2026-11-14T10:00:00Z"
            }],
            "teams": [{ "team": { "id": "team_01", "name": "Acme" }, "role": "admin", "has_seat": true }]
        }"#);

        assert_eq!(profile.name.as_deref(), Some("Ada"));
        let license = &profile.licenses[0];
        assert_eq!(
            (license.plan.as_str(), license.cycle.as_str(), license.status.as_str()),
            ("team", "yearly", "past_due")
        );
        assert_eq!(license.team.as_ref().map(|team| team.name.as_str()), Some("Acme"));
        assert_eq!(license.renews_at, None);
        assert_eq!(
            profile.licenses[1].renews_at.map(|at| at.to_rfc3339()).as_deref(),
            Some("2026-11-14T10:00:00+00:00")
        );
        assert_eq!(profile.teams[0].role, "admin");
        assert!(profile.teams[0].has_seat);
    }

    #[test]
    fn a_code_this_build_does_not_know_reads_as_sent() {
        let profile = me(r#"{
            "account": { "id": "acct_01", "email": "ada@m17.example" },
            "licenses": [{
                "id": "lic_01", "plan": "enterprise", "cycle": "quarterly", "source": "reseller", "status": "paused"
            }],
            "teams": [{ "team": { "id": "team_01", "name": "Acme" }, "role": "billing", "has_seat": false }]
        }"#);

        let license = &profile.licenses[0];
        assert_eq!(
            [
                &license.plan,
                &license.cycle,
                &license.source,
                &license.status,
                &profile.teams[0].role
            ],
            ["enterprise", "quarterly", "reseller", "paused", "billing"]
        );
    }

    #[test]
    fn a_blank_name_reads_as_none() {
        let profile = me(r#"{
            "account": { "id": "acct_01", "email": "ada@m17.example", "name": "  " },
            "licenses": [], "teams": []
        }"#);

        assert_eq!(profile.name, None);
    }

    #[test]
    fn an_offline_file_holds_the_device_until_it_expires() {
        let now = Utc::now();
        let device = Device {
            id: "dev_01".to_owned(),
            machine_id: "0".repeat(64),
            platform: "linux".to_owned(),
            name: "Lab".to_owned(),
            app_version: "0.1.0".to_owned(),
            os_version: "Ubuntu 26.04".to_owned(),
            last_seen_at: now,
            licensed_at: Some(now),
            offline_until: Some(now + TimeDelta::days(30)),
        };

        assert!(device.offline_file_active(now));
        assert!(!device.offline_file_active(now + TimeDelta::days(31)));
        assert!(
            !Device {
                offline_until: None,
                ..device
            }
            .offline_file_active(now)
        );
    }
}
