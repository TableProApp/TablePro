// The names the key sheets show beside an id: a team's from the profile, a member's from the team's member list.

use std::collections::HashMap;

use tablepro_account::Account;
use tablepro_keys::encoding::{AccountId, TeamId};
use tablepro_sync::api::ScopeName;
use tablepro_sync::api::ids::parse_typeid;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Person {
    pub(crate) name: Option<String>,
    pub(crate) email: Option<String>,
}

#[derive(Debug, Default)]
pub(crate) struct Names {
    teams: HashMap<TeamId, String>,
    people: HashMap<(TeamId, AccountId), Person>,
}

impl Names {
    // A read that fails leaves its names out, as a member list the server keeps from anyone but the team's owners
    // and admins, or a profile read offline.
    pub(crate) async fn read(account: Option<&Account>, teams: &[TeamId]) -> Self {
        let mut names = Self::default();
        let Some(account) = account else {
            return names;
        };
        match account.profile().await {
            Ok(profile) => {
                for membership in profile.teams {
                    if let Ok(ScopeName::Team(team)) = ScopeName::parse(&membership.team.id) {
                        names.teams.insert(team, membership.team.name);
                    }
                }
            }
            Err(error) => tracing::debug!(%error, "the profile gave no team names"),
        }
        let mut asked = Vec::new();
        for team in teams {
            if asked.contains(team) {
                continue;
            }
            asked.push(*team);
            match account.team_members(&ScopeName::Team(*team).wire()).await {
                Ok(members) => {
                    for member in members {
                        let Some(id) = parse_typeid("acct_", &member.account_id) else {
                            continue;
                        };
                        let person = Person {
                            name: member.name,
                            email: Some(member.email),
                        };
                        names.people.insert((*team, AccountId(id)), person);
                    }
                }
                Err(error) => tracing::debug!(%error, "the team's member list gave no names"),
            }
        }
        names
    }

    pub(crate) fn team(&self, team: TeamId) -> Option<String> {
        self.teams.get(&team).cloned()
    }

    pub(crate) fn person(&self, team: TeamId, account: AccountId) -> Person {
        self.people.get(&(team, account)).cloned().unwrap_or_default()
    }

    #[cfg(test)]
    pub(crate) fn insert_team(&mut self, team: TeamId, name: &str) {
        self.teams.insert(team, name.to_owned());
    }

    #[cfg(test)]
    pub(crate) fn insert_person(&mut self, team: TeamId, account: AccountId, person: Person) {
        self.people.insert((team, account), person);
    }
}
