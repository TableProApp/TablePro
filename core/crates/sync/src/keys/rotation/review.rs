// Removing a device (0056, Account flows, D7): the review of the members this account confirmed while the lost device
// held its keys, and the choices that stay in `key_pending` until every team rotation is written (0054).

use std::collections::BTreeMap;

use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, TeamId, Version, WrapPurpose};
use tablepro_keys::keys::{Ed25519Public, Signature};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::wrap::{Recipient, Wrap};
use uuid::Uuid;

use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::ReviewedMember;
use crate::api::state::{Row, RowRange, StateTxn, Table};
use crate::keys::KeyService;

// Format 1 carried no certificate; format 2 no IK, refused or retried teams and no opened `av`.
const FORMAT: u8 = 3;

// The team steps an account rotation still owes: the members marked for removal per team, the teams done, the
// signature of this flow's own certificate at that `av`, and the IK the account was under when it began. The
// signature tells this flow's rotation from another's; the IK tells another device's that won, under it or endorsed
// by it, from a certificate nothing verifies. Teams the server refused are recorded and tried again on later passes;
// a team that met `create_only` waits for a pull past the version this device held then. A recovery names the `av`
// whose account keys R opened on a device that did not hold them, which go if the recovery never applies.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct TeamSteps {
    pub remove: Vec<(TeamId, AccountId)>,
    pub done: Vec<TeamId>,
    pub certificate: Option<Signature>,
    pub ik: Option<Ed25519Public>,
    pub stuck: Vec<TeamId>,
    pub retry: Vec<(TeamId, Version)>,
    pub opened: Option<Version>,
}

fn push_count(out: &mut Vec<u8>, count: usize) {
    out.extend_from_slice(&u32::try_from(count).unwrap_or(u32::MAX).to_be_bytes());
}

fn push_optional(out: &mut Vec<u8>, bytes: Option<&[u8]>) {
    match bytes {
        Some(bytes) => {
            out.push(1);
            out.extend_from_slice(bytes);
        }
        None => out.push(0),
    }
}

impl TeamSteps {
    pub fn encode(&self) -> Vec<u8> {
        if *self == Self::default() {
            return Vec::new();
        }
        let mut out = vec![FORMAT];
        push_count(&mut out, self.remove.len());
        for (team, account) in &self.remove {
            out.extend_from_slice(team.0.as_bytes());
            out.extend_from_slice(account.0.as_bytes());
        }
        push_count(&mut out, self.done.len());
        for team in &self.done {
            out.extend_from_slice(team.0.as_bytes());
        }
        push_optional(
            &mut out,
            self.certificate.as_ref().map(|signature| signature.0.as_slice()),
        );
        push_optional(&mut out, self.ik.as_ref().map(|ik| ik.0.as_slice()));
        push_count(&mut out, self.stuck.len());
        for team in &self.stuck {
            out.extend_from_slice(team.0.as_bytes());
        }
        push_count(&mut out, self.retry.len());
        for (team, version) in &self.retry {
            out.extend_from_slice(team.0.as_bytes());
            out.extend_from_slice(&version.get().to_be_bytes());
        }
        push_optional(
            &mut out,
            self.opened
                .map(|av| av.get().to_be_bytes())
                .as_ref()
                .map(<[u8; 4]>::as_slice),
        );
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, SyncError> {
        if bytes.is_empty() {
            return Ok(Self::default());
        }
        decode(bytes).ok_or(SyncError::Malformed {
            what: "account rotation state",
        })
    }

    pub fn removals_for(&self, team: TeamId) -> Vec<AccountId> {
        self.remove
            .iter()
            .filter(|(marked, _)| *marked == team)
            .map(|(_, account)| *account)
            .collect()
    }
}

fn decode(bytes: &[u8]) -> Option<TeamSteps> {
    let (format, mut rest) = bytes.split_first()?;
    if !matches!(*format, 1..=FORMAT) {
        return None;
    }
    let format = *format;
    let mut take = |len: usize| -> Option<&[u8]> {
        if rest.len() < len {
            return None;
        }
        let (head, tail) = rest.split_at(len);
        rest = tail;
        Some(head)
    };
    let mut steps = TeamSteps::default();
    let count = |bytes: &[u8]| usize::try_from(u32::from_be_bytes(bytes.try_into().ok()?)).ok();
    let uuid = |bytes: &[u8]| Uuid::from_slice(bytes).ok();
    for _ in 0..count(take(4)?)? {
        let team = uuid(take(16)?)?;
        let account = uuid(take(16)?)?;
        steps.remove.push((TeamId(team), AccountId(account)));
    }
    for _ in 0..count(take(4)?)? {
        steps.done.push(TeamId(uuid(take(16)?)?));
    }
    if format >= 2 {
        steps.certificate = match take(1)? {
            [0] => None,
            [1] => Some(Signature(take(64)?.try_into().ok()?)),
            _ => return None,
        };
    }
    if format >= 3 {
        steps.ik = match take(1)? {
            [0] => None,
            [1] => Some(Ed25519Public(take(32)?.try_into().ok()?)),
            _ => return None,
        };
        for _ in 0..count(take(4)?)? {
            steps.stuck.push(TeamId(uuid(take(16)?)?));
        }
        for _ in 0..count(take(4)?)? {
            let team = TeamId(uuid(take(16)?)?);
            let version = Version::new(u32::from_be_bytes(take(4)?.try_into().ok()?)).ok()?;
            steps.retry.push((team, version));
        }
        steps.opened = match take(1)? {
            [0] => None,
            [1] => Some(Version::new(u32::from_be_bytes(take(4)?.try_into().ok()?)).ok()?),
            _ => return None,
        };
    }
    if !rest.is_empty() {
        return None;
    }
    Some(steps)
}

// The members this account wrapped a team key to under one of `avs`. Telling a confirmation from a rotation's wrap to a
// holder it kept needs that holder's earlier wrap verified under a key the lost device never held; until the team
// rules give that, every such wrap is listed, so no confirmation the lost device could have made is missed. The person
// keeps the rest, which is the default.
#[cfg(test)]
pub(crate) fn confirmations(account: AccountId, avs: &[Version], wraps: &[Wrap]) -> BTreeMap<AccountId, Version> {
    let mut members: BTreeMap<AccountId, Version> = BTreeMap::new();
    for wrap in wraps {
        let Recipient::Account(recipient) = wrap.target.recipient else {
            continue;
        };
        if signed_at(account, avs, wrap) {
            let entry = members.entry(recipient).or_insert(wrap.wrapper.av);
            *entry = (*entry).min(wrap.wrapper.av);
        }
    }
    members
}

// A team wrap this account made under one of `avs` to another account.
fn signed_at(account: AccountId, avs: &[Version], wrap: &Wrap) -> bool {
    wrap.target.purpose == WrapPurpose::Key(KeyPurpose::Team)
        && wrap.wrapper.account == account
        && wrap.target.recipient != Recipient::Account(account)
        && avs.contains(&wrap.wrapper.av)
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
            let scope = ScopeName::Team(team);
            let wraps: Vec<Wrap> = self
                .held_objects(txn, scope, KeyKind::Wrap)
                .await?
                .iter()
                .filter_map(|held| held.object.wrap())
                .collect();
            // A wrap to an account that held the version before came in a rotation and goes with it; only a
            // confirmation is reviewed (0056, Removing a device). Where the holders cannot be decided it is listed.
            let mut holders_before = BTreeMap::new();
            for wrap in &wraps {
                let (Recipient::Account(recipient), true) = (wrap.target.recipient, signed_at(account, &avs, wrap))
                else {
                    continue;
                };
                let held_before = match wrap.target.version.previous() {
                    None => Some(false),
                    Some(previous) => {
                        let holders = match holders_before.entry(previous) {
                            std::collections::btree_map::Entry::Occupied(known) => known.into_mut(),
                            std::collections::btree_map::Entry::Vacant(slot) => {
                                slot.insert(self.team_holders_at(txn, team, previous).await?)
                            }
                        };
                        holders.as_ref().map(|holders| holders.contains(&recipient))
                    }
                };
                if held_before != Some(true) {
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
    use tablepro_keys::encoding::KeyDeviceId;
    use tablepro_keys::scope_key::KeyRef;
    use tablepro_keys::wrap::{Wrapper, scope_key_target};

    use super::*;

    fn v(value: u32) -> Version {
        Version::new(value).unwrap()
    }

    fn account(id: u128) -> AccountId {
        AccountId(Uuid::from_u128(id))
    }

    const TEAM: Uuid = Uuid::from_u128(0x7e);

    fn key(version: u32) -> KeyRef {
        KeyRef {
            owner: TEAM,
            purpose: KeyPurpose::Team,
            version: v(version),
        }
    }

    fn wrap(version: u32, to: AccountId, by: AccountId, av: u32) -> Wrap {
        Wrap {
            target: scope_key_target(key(version), to, v(1)),
            enc: [0; 32],
            ct: Vec::new(),
            wrapper: Wrapper {
                account: by,
                av: v(av),
                key_device: KeyDeviceId(Uuid::nil()),
            },
            sig: Signature([0; 64]),
        }
    }

    #[test]
    fn an_empty_state_marks_no_one_and_every_state_round_trips() {
        let steps = TeamSteps {
            remove: vec![(TeamId(Uuid::from_u128(1)), account(2))],
            done: vec![TeamId(Uuid::from_u128(3))],
            certificate: Some(Signature([9; 64])),
            ik: Some(Ed25519Public([4; 32])),
            stuck: vec![TeamId(Uuid::from_u128(5))],
            retry: vec![(TeamId(Uuid::from_u128(6)), v(7))],
            opened: Some(v(2)),
        };
        let marker_only = TeamSteps {
            certificate: Some(Signature([8; 64])),
            ..TeamSteps::default()
        };

        assert_eq!(TeamSteps::decode(&[]).unwrap(), TeamSteps::default());
        assert!(TeamSteps::default().encode().is_empty());
        assert_eq!(TeamSteps::decode(&steps.encode()).unwrap(), steps);
        assert_eq!(TeamSteps::decode(&marker_only.encode()).unwrap(), marker_only);
        assert_eq!(steps.removals_for(TeamId(Uuid::from_u128(1))), vec![account(2)]);
    }

    #[test]
    fn a_truncated_or_padded_state_is_refused() {
        let encoded = TeamSteps {
            remove: vec![(TeamId(Uuid::from_u128(1)), account(2))],
            certificate: Some(Signature([7; 64])),
            ..TeamSteps::default()
        }
        .encode();
        let mut padded = encoded.clone();
        padded.push(0);

        assert!(TeamSteps::decode(&encoded[..encoded.len() - 1]).is_err());
        assert!(TeamSteps::decode(&padded).is_err());
        assert!(TeamSteps::decode(&[3]).is_err());
        assert!(TeamSteps::decode(&[4]).is_err());
    }

    // A rotated to version 2 while its lost device held `av` 1, and in the same `av` confirmed E back after a removal
    // had left E out. Every member A wrapped to under that `av` is listed, the re-confirmed one included.
    #[test]
    fn every_member_wrapped_to_under_a_lost_av_is_listed() {
        let (a, o, m, e) = (account(0xa), account(0x0), account(0xd), account(0xe));
        let wraps = [
            wrap(1, o, o, 1),
            wrap(1, e, o, 1),
            wrap(2, o, a, 1),
            wrap(2, m, a, 1),
            wrap(2, a, a, 1),
            wrap(2, e, a, 1),
        ];

        let listed = confirmations(a, &[v(1)], &wraps);

        assert_eq!(
            listed.into_iter().collect::<Vec<_>>(),
            vec![(o, v(1)), (m, v(1)), (e, v(1))]
        );
    }

    #[test]
    fn a_wrap_under_an_av_no_lost_device_held_is_no_confirmation() {
        let (a, e) = (account(0xa), account(0xe));
        let wraps = [wrap(1, a, a, 2), wrap(1, e, a, 2)];

        assert!(confirmations(a, &[v(1)], &wraps).is_empty());
        assert_eq!(confirmations(a, &[v(2)], &wraps).len(), 1);
    }

    #[test]
    fn a_format_1_state_reads_with_no_certificate() {
        let mut row = vec![1];
        row.extend_from_slice(&1_u32.to_be_bytes());
        row.extend_from_slice(Uuid::from_u128(1).as_bytes());
        row.extend_from_slice(Uuid::from_u128(2).as_bytes());
        row.extend_from_slice(&0_u32.to_be_bytes());

        let steps = TeamSteps::decode(&row).unwrap();

        assert_eq!(steps.remove, vec![(TeamId(Uuid::from_u128(1)), account(2))]);
        assert_eq!(steps.certificate, None);
    }
}
