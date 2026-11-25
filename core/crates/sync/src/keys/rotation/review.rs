// Removing a device (0056, Account flows, D7): the review of the members this account confirmed while the lost device
// held its keys, and the choices that stay in `key_pending` until every team rotation is written (0054).

use std::collections::BTreeMap;

use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, TeamId, Version, WrapPurpose};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::Recipient;
use uuid::Uuid;

use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::ReviewedMember;
use crate::api::state::{Row, RowRange, StateTxn, Table};
use crate::keys::KeyService;

const FORMAT: u8 = 1;

// The team steps an account rotation still owes: the members marked for removal per team, and the teams done.
// An empty state, as Replace writes it, marks no one and has done nothing.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TeamSteps {
    pub remove: Vec<(TeamId, AccountId)>,
    pub done: Vec<TeamId>,
}

impl TeamSteps {
    pub fn encode(&self) -> Vec<u8> {
        if self.remove.is_empty() && self.done.is_empty() {
            return Vec::new();
        }
        let mut out = vec![FORMAT];
        out.extend_from_slice(&u32::try_from(self.remove.len()).unwrap_or(u32::MAX).to_be_bytes());
        for (team, account) in &self.remove {
            out.extend_from_slice(team.0.as_bytes());
            out.extend_from_slice(account.0.as_bytes());
        }
        out.extend_from_slice(&u32::try_from(self.done.len()).unwrap_or(u32::MAX).to_be_bytes());
        for team in &self.done {
            out.extend_from_slice(team.0.as_bytes());
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, SyncError> {
        let malformed = SyncError::Malformed {
            what: "account rotation state",
        };
        if bytes.is_empty() {
            return Ok(Self::default());
        }
        let mut rest = bytes.strip_prefix(&[FORMAT]).ok_or(malformed.clone())?;
        let mut count = || -> Option<usize> {
            let (head, tail) = rest.split_first_chunk::<4>()?;
            rest = tail;
            usize::try_from(u32::from_be_bytes(*head)).ok()
        };
        let removals = count().ok_or(malformed.clone())?;
        let mut steps = Self::default();
        let uuid = |rest: &mut &[u8]| -> Option<Uuid> {
            let (head, tail) = rest.split_first_chunk::<16>()?;
            *rest = tail;
            Some(Uuid::from_bytes(*head))
        };
        for _ in 0..removals {
            let team = uuid(&mut rest).ok_or(malformed.clone())?;
            let account = uuid(&mut rest).ok_or(malformed.clone())?;
            steps.remove.push((TeamId(team), AccountId(account)));
        }
        let (head, tail) = rest.split_first_chunk::<4>().ok_or(malformed.clone())?;
        rest = tail;
        let done = usize::try_from(u32::from_be_bytes(*head)).map_err(|_| malformed.clone())?;
        for _ in 0..done {
            steps.done.push(TeamId(uuid(&mut rest).ok_or(malformed.clone())?));
        }
        if !rest.is_empty() {
            return Err(malformed);
        }
        Ok(steps)
    }

    pub fn removals_for(&self, team: TeamId) -> Vec<AccountId> {
        self.remove
            .iter()
            .filter(|(marked, _)| *marked == team)
            .map(|(_, account)| *account)
            .collect()
    }
}

impl KeyService {
    // The `av`s at which a lost key device held a certificate of this account.
    async fn lost_avs(&self, txn: &mut dyn StateTxn, lost: &[KeyDeviceId]) -> Result<Vec<Version>, SyncError> {
        let account = self.account();
        let mut avs: Vec<Version> = self
            .held_objects(txn, ScopeName::Personal, KeyKind::Device)
            .await?
            .into_iter()
            .filter_map(|held| match held.object.id {
                KeyRecordId::Device {
                    account: owner,
                    key_device,
                    av,
                } if owner == account && lost.contains(&key_device) => Some(av),
                _ => None,
            })
            .collect();
        avs.sort_unstable();
        avs.dedup();
        Ok(avs)
    }

    // In each team, the members this account confirmed with a wrap it signed under an `av` a lost device held a
    // certificate for: a scope-key wrap names the account, not the device, so the person's own confirmations count.
    pub(crate) async fn removal_review(
        &self,
        txn: &mut dyn StateTxn,
        lost: &[KeyDeviceId],
    ) -> Result<Vec<ReviewedMember>, SyncError> {
        let account = self.account();
        let avs = self.lost_avs(txn, lost).await?;
        let mut members: BTreeMap<(TeamId, AccountId), Version> = BTreeMap::new();
        for team in self.team_scopes(txn).await? {
            for held in self.held_objects(txn, ScopeName::Team(team), KeyKind::Wrap).await? {
                let Some(wrap) = held.object.wrap() else { continue };
                let Recipient::Account(recipient) = wrap.target.recipient else {
                    continue;
                };
                let counts = wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
                    && wrap.wrapper.account == account
                    && recipient != account
                    && avs.contains(&wrap.wrapper.av);
                if counts {
                    let entry = members.entry((team, recipient)).or_insert(wrap.wrapper.av);
                    *entry = (*entry).min(wrap.wrapper.av);
                }
            }
        }
        Ok(members
            .into_iter()
            .map(|((team, account), confirmed_under_av)| ReviewedMember {
                team,
                account,
                confirmed_under_av,
            })
            .collect())
    }

    pub(crate) async fn team_scopes(&self, txn: &mut dyn StateTxn) -> Result<Vec<TeamId>, SyncError> {
        Ok(txn
            .scan(&RowRange::Table(Table::Scopes))
            .await?
            .into_iter()
            .filter_map(|row| match row {
                Row::Scope(scope) => match scope.scope {
                    ScopeName::Team(team) => Some(team),
                    ScopeName::Personal | ScopeName::History => None,
                },
                _ => None,
            })
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_empty_state_marks_no_one_and_round_trips() {
        let steps = TeamSteps {
            remove: vec![(TeamId(Uuid::from_u128(1)), AccountId(Uuid::from_u128(2)))],
            done: vec![TeamId(Uuid::from_u128(3))],
        };

        assert_eq!(TeamSteps::decode(&[]).unwrap(), TeamSteps::default());
        assert!(TeamSteps::default().encode().is_empty());
        assert_eq!(TeamSteps::decode(&steps.encode()).unwrap(), steps);
        assert_eq!(
            steps.removals_for(TeamId(Uuid::from_u128(1))),
            vec![AccountId(Uuid::from_u128(2))]
        );
    }

    #[test]
    fn a_truncated_or_padded_state_is_refused() {
        let encoded = TeamSteps {
            remove: vec![(TeamId(Uuid::from_u128(1)), AccountId(Uuid::from_u128(2)))],
            done: Vec::new(),
        }
        .encode();
        let mut padded = encoded.clone();
        padded.push(0);

        assert!(TeamSteps::decode(&encoded[..encoded.len() - 1]).is_err());
        assert!(TeamSteps::decode(&padded).is_err());
        assert!(TeamSteps::decode(&[2]).is_err());
    }
}
