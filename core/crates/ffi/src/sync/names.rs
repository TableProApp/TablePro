// The names the key sheets show beside an id: a team's from the profile, a member's from the team's member list.

use std::collections::HashMap;

use tablepro_account::Account;
use tablepro_keys::encoding::{AccountId, TeamId};
use tablepro_sync::api::ScopeName;
use uuid::Uuid;

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
                        let Some(id) = typeid_uuid("acct_", &member.account_id) else {
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

const TYPEID_ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";

// A TypeID's suffix is the UUID in 26 lower-case Crockford base32 symbols, the first carrying the two zero bits above
// 128; the server names accounts `acct_` and that suffix.
fn typeid_uuid(prefix: &str, text: &str) -> Option<Uuid> {
    let suffix = text.strip_prefix(prefix)?;
    if suffix.len() != 26 || !suffix.starts_with(|c: char| ('0'..='7').contains(&c)) {
        return None;
    }
    let mut value: u128 = 0;
    for byte in suffix.bytes() {
        let symbol = TYPEID_ALPHABET.iter().position(|candidate| *candidate == byte)?;
        value = (value << 5) | u128::try_from(symbol).ok()?;
    }
    Some(Uuid::from_u128(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_account_typeid_reads_as_the_uuid_a_team_scope_name_encodes_the_same_way() {
        let uuid = Uuid::from_u128(0x0193_a1b2_c3d4_7e5f_8a9b_0c1d_2e3f_4a5b);
        let team = ScopeName::Team(TeamId(uuid)).wire();
        let account = format!("acct_{}", team.trim_start_matches("team_"));

        assert_eq!(typeid_uuid("acct_", &account), Some(uuid));
        assert_eq!(typeid_uuid("acct_", &team), None);
        assert_eq!(typeid_uuid("acct_", "acct_81k8d6wk00f8xsr79e7x052rkk"), None);
        assert_eq!(typeid_uuid("acct_", "acct_01k8d6wk00f8xsr79e7x052rk"), None);
    }
}
