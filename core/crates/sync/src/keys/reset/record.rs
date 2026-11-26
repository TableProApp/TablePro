// This device's own reset as `key_pending` holds it (0054): the proposal's `av`, IK and key device, its state, the
// server's `taken_at` and `held_until`, which a pull serves beside the record and never in its fields (0051, Key
// object bodies), the digest of the proposal it wrote and the epoch the server last took it in. Other devices' resets
// live only in `key_objects` as served (0064).

use tablepro_keys::encoding::{KeyDeviceId, ResetId, TeamId, Version};
use tablepro_keys::keys::Ed25519Public;
use uuid::Uuid;

use crate::api::error::SyncError;
use crate::api::ids::{DeviceRowId, EpochId};
use crate::api::key_flows::{PendingReset, ResetKind, ResetState};
use crate::api::state::{KeyPendingRow, PendingFlow};

// Format 1 also kept other devices' resets and carried no proposal digest or epoch.
const FORMAT: u8 = 2;
// 7 days from when the server took the proposal, then 7 more for its activation (0051, Resets).
pub(crate) const HOLD_US: i64 = 7 * 24 * 3600 * 1_000_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ResetRecord {
    pub reset: ResetId,
    // The proposal applied on the server.
    pub sent: bool,
    pub kind: ResetKind,
    pub av: Version,
    pub ik: Ed25519Public,
    pub key_device: KeyDeviceId,
    pub state: ResetState,
    pub taken_at_us: i64,
    pub held_until_us: i64,
    pub proposed_by: Option<DeviceRowId>,
    // After activation, the teams this account's new certificate was copied into.
    pub published: Vec<TeamId>,
    // SHA-256 of the proposal's fields as this device wrote them: only that proposal is ever sent or activated.
    pub proposal: [u8; 32],
    // The personal scope's epoch when the server took the proposal; a restore since may have lost it (0064).
    pub epoch: Option<EpochId>,
}

impl ResetRecord {
    pub fn pending(&self) -> bool {
        self.state == ResetState::Pending
    }

    // Seven days past `held_until` with no activation, the reset ends (0056, Reset).
    pub fn overdue(&self, now_us: i64) -> bool {
        self.pending() && now_us >= self.held_until_us.saturating_add(HOLD_US)
    }

    pub fn view(&self) -> PendingReset {
        PendingReset {
            reset: self.reset,
            kind: self.kind,
            state: self.state,
            mine: true,
            proposed_by: self.proposed_by.clone(),
            taken_at_us: self.taken_at_us,
            held_until_us: self.held_until_us,
        }
    }

    pub fn to_row(&self) -> KeyPendingRow {
        let mut state = vec![FORMAT, u8::from(self.sent)];
        state.push(match self.kind {
            ResetKind::KeepScopeKeys => 2,
            ResetKind::StartEmpty => 3,
        });
        state.extend_from_slice(&self.av.get().to_be_bytes());
        state.extend_from_slice(&self.ik.0);
        state.extend_from_slice(self.key_device.0.as_bytes());
        state.push(match self.state {
            ResetState::Pending => 0,
            ResetState::Cancelled => 1,
            ResetState::Superseded => 2,
            ResetState::Active => 3,
        });
        state.extend_from_slice(&self.taken_at_us.to_be_bytes());
        state.extend_from_slice(&self.held_until_us.to_be_bytes());
        match &self.proposed_by {
            Some(device) => {
                state.push(1);
                state.extend_from_slice(&u32::try_from(device.0.len()).unwrap_or(u32::MAX).to_be_bytes());
                state.extend_from_slice(device.0.as_bytes());
            }
            None => state.push(0),
        }
        state.extend_from_slice(&u32::try_from(self.published.len()).unwrap_or(u32::MAX).to_be_bytes());
        for team in &self.published {
            state.extend_from_slice(team.0.as_bytes());
        }
        state.extend_from_slice(&self.proposal);
        match &self.epoch {
            Some(epoch) => {
                state.push(1);
                state.extend_from_slice(epoch.0.as_bytes());
            }
            None => state.push(0),
        }
        KeyPendingRow {
            flow: PendingFlow::ResetProposal { reset: self.reset },
            state,
        }
    }

    pub fn from_row(row: &KeyPendingRow) -> Result<Self, SyncError> {
        let PendingFlow::ResetProposal { reset } = row.flow else {
            return Err(SyncError::Malformed { what: "reset state" });
        };
        decode(reset, &row.state).ok_or(SyncError::Malformed { what: "reset state" })
    }
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        if self.0.len() < len {
            return None;
        }
        let (head, rest) = self.0.split_at(len);
        self.0 = rest;
        Some(head)
    }

    fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        self.take(N).and_then(|bytes| <[u8; N]>::try_from(bytes).ok())
    }

    fn byte(&mut self) -> Option<u8> {
        self.array::<1>().map(|[byte]| byte)
    }
}

fn decode(reset: ResetId, bytes: &[u8]) -> Option<ResetRecord> {
    let mut reader = Reader(bytes);
    if reader.byte()? != FORMAT {
        return None;
    }
    let sent = match reader.byte()? {
        0 => false,
        1 => true,
        _ => return None,
    };
    let kind = match reader.byte()? {
        2 => ResetKind::KeepScopeKeys,
        3 => ResetKind::StartEmpty,
        _ => return None,
    };
    let av = Version::new(u32::from_be_bytes(reader.array()?)).ok()?;
    let ik = Ed25519Public(reader.array()?);
    let key_device = KeyDeviceId(Uuid::from_bytes(reader.array()?));
    let state = match reader.byte()? {
        0 => ResetState::Pending,
        1 => ResetState::Cancelled,
        2 => ResetState::Superseded,
        3 => ResetState::Active,
        _ => return None,
    };
    let taken_at_us = i64::from_be_bytes(reader.array()?);
    let held_until_us = i64::from_be_bytes(reader.array()?);
    let proposed_by = match reader.byte()? {
        0 => None,
        1 => {
            let len = usize::try_from(u32::from_be_bytes(reader.array()?)).ok()?;
            Some(DeviceRowId(String::from_utf8(reader.take(len)?.to_vec()).ok()?))
        }
        _ => return None,
    };
    let count = usize::try_from(u32::from_be_bytes(reader.array()?)).ok()?;
    let mut published = Vec::new();
    for _ in 0..count {
        published.push(TeamId(Uuid::from_bytes(reader.array()?)));
    }
    let proposal = reader.array()?;
    let epoch = match reader.byte()? {
        0 => None,
        1 => Some(EpochId(Uuid::from_bytes(reader.array()?))),
        _ => return None,
    };
    if !reader.0.is_empty() {
        return None;
    }
    Some(ResetRecord {
        reset,
        sent,
        kind,
        av,
        ik,
        key_device,
        state,
        taken_at_us,
        held_until_us,
        proposed_by,
        published,
        proposal,
        epoch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record() -> ResetRecord {
        ResetRecord {
            reset: ResetId(Uuid::from_u128(1)),
            sent: false,
            kind: ResetKind::StartEmpty,
            av: Version::new(3).unwrap(),
            ik: Ed25519Public([7; 32]),
            key_device: KeyDeviceId(Uuid::from_u128(2)),
            state: ResetState::Pending,
            taken_at_us: 10,
            held_until_us: 10 + HOLD_US,
            proposed_by: Some(DeviceRowId("dev_1".to_owned())),
            published: vec![TeamId(Uuid::from_u128(3))],
            proposal: [5; 32],
            epoch: Some(EpochId(Uuid::from_u128(4))),
        }
    }

    #[test]
    fn a_record_round_trips_and_a_tampered_one_is_refused() {
        let row = record().to_row();
        let mut padded = row.clone();
        padded.state.push(0);
        let mut bad_kind = row.clone();
        bad_kind.state[2] = 1;

        assert_eq!(ResetRecord::from_row(&row).unwrap(), record());
        assert!(ResetRecord::from_row(&padded).is_err());
        assert!(ResetRecord::from_row(&bad_kind).is_err());
    }

    #[test]
    fn a_pending_reset_is_overdue_seven_days_past_held_until() {
        let record = record();

        assert!(!record.overdue(record.held_until_us + HOLD_US - 1));
        assert!(record.overdue(record.held_until_us + HOLD_US));
    }
}
