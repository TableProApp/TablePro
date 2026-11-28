// One comparison session as this side holds it in `key_comparisons` (0054): the view it fixed, the steps it took and
// why it ended. Until the reveal each step goes through `tablepro_keys::sas::Comparison`, which the service keeps in
// memory because it holds r_N. The row takes a step's values only once the step is taken, so r_N reaches it with the
// reveal, and a session whose comparison a restart dropped before the reveal ends (0056, Approving a device, The
// session). From the reveal on every input is in the row, and the words come from the view it fixed.

use std::fmt;

use tablepro_keys::KeysError;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, RequestId};
use tablepro_keys::keys::{Ed25519Public, X25519Public};
use tablepro_keys::sas::{Comparison, Role, SasDevice, SessionState, Transcript};
use uuid::Uuid;

use crate::api::error::SyncError;
use crate::api::ids::DeviceRowId;
use crate::api::key_flows::{SessionEnd, SessionPhase};
use crate::api::state::KeyComparisonRow;

const FORMAT: u8 = 1;
const DEVICE_LEN: usize = 16 + 32 + 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Ended {
    Approved,
    // Another approver's `nonce` step came first.
    TakenElsewhere,
    Cancelled(SessionEnd),
    Expired,
}

// What this side pushed, so a resumed session sends each step once more at most.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Sent {
    // N's `key.request`, A's `nonce` step.
    pub opened: bool,
    pub reveal: bool,
    // A's approval change set applied; N merged it.
    pub approval: bool,
    pub cancel: bool,
    // The server purged the request: N, still waiting for its approval, takes one already held or ends.
    pub purged: bool,
    // N refused an approval the server applied: Sign Out's revoke of the key device the server bound is owed.
    pub revoke_owed: bool,
}

#[derive(Clone)]
pub(crate) struct SessionRecord {
    pub request: RequestId,
    pub role: Role,
    pub state: SessionState,
    pub expires_at_us: i64,
    // N: the IK of the newest certificate it read. A: its own account's.
    pub ik: Ed25519Public,
    pub n: SasDevice,
    pub commit: [u8; 32],
    // Once N took its reveal step, or A read it.
    pub r_n: Option<[u8; 32]>,
    pub a: Option<(SasDevice, [u8; 32])>,
    pub end: Option<Ended>,
    pub sent: Sent,
    pub requested_at_us: i64,
    // The row that wrote the request, as the server named it.
    pub device: Option<DeviceRowId>,
}

// Neither nonce is printed.
impl fmt::Debug for SessionRecord {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SessionRecord")
            .field("request", &self.request)
            .field("role", &self.role)
            .field("state", &self.state)
            .field("end", &self.end)
            .finish_non_exhaustive()
    }
}

impl SessionRecord {
    // N, once it fixed its view. The comparison draws r_N and holds it until the reveal.
    pub fn new_device(
        transcript: Transcript,
        n: SasDevice,
        now_us: i64,
        expires_at_us: i64,
    ) -> Result<(Self, Comparison), KeysError> {
        let (request, ik) = (transcript.request, transcript.ik);
        let comparison = Comparison::new_device(transcript, n)?;
        let record = Self {
            request,
            role: Role::NewDevice,
            state: comparison.state(),
            expires_at_us,
            ik,
            n,
            commit: comparison.commit(),
            r_n: None,
            a: None,
            end: None,
            sent: Sent::default(),
            requested_at_us: now_us,
            device: None,
        };
        Ok((record, comparison))
    }

    // A, for a request it read and has not chosen.
    pub fn seen_request(
        request: RequestId,
        ik: Ed25519Public,
        n: SasDevice,
        commit: [u8; 32],
        requested_at_us: i64,
        expires_at_us: i64,
        device: Option<DeviceRowId>,
    ) -> Self {
        Self {
            request,
            role: Role::Approver,
            state: SessionState::Open,
            expires_at_us,
            ik,
            n,
            commit,
            r_n: None,
            a: None,
            end: None,
            sent: Sent::default(),
            requested_at_us,
            device,
        }
    }

    pub fn live(&self) -> bool {
        self.end.is_none()
    }

    // A live session before the reveal takes its next step through the comparison this side holds in memory: N's from
    // its request on, A's from its `nonce` step on.
    pub fn needs_comparison(&self) -> bool {
        self.live() && self.r_n.is_none() && (self.role == Role::NewDevice || self.state != SessionState::Open)
    }

    fn require_live(&self) -> Result<(), KeysError> {
        if self.live() { Ok(()) } else { Err(KeysError::Session) }
    }

    // A, when the person picks the request: it fixes its view with `ik`, its own account's as it stands then, and the
    // comparison draws the r_A its `nonce` step carries.
    pub fn choose(
        &mut self,
        origin: &Origin,
        account: AccountId,
        ik: Ed25519Public,
        a: SasDevice,
    ) -> Result<Comparison, KeysError> {
        self.require_live()?;
        if self.role != Role::Approver || self.state != SessionState::Open {
            return Err(KeysError::Session);
        }
        let comparison = Comparison::approver(transcript(origin, account, self.request, ik), self.n, self.commit, a)?;
        self.ik = ik;
        self.a = Some((a, comparison.nonce()?));
        self.state = comparison.state();
        Ok(comparison)
    }

    // N reads the `nonce` step.
    pub fn receive_nonce(&mut self, comparison: &mut Comparison, a: SasDevice, r_a: [u8; 32]) -> Result<(), KeysError> {
        self.require_live()?;
        comparison.receive_nonce(a, r_a)?;
        self.a = Some((a, r_a));
        self.state = comparison.state();
        Ok(())
    }

    // N's `reveal` step, only once r_A is fixed.
    pub fn reveal(&mut self, comparison: &mut Comparison) -> Result<[u8; 32], KeysError> {
        self.require_live()?;
        let r_n = comparison.reveal()?;
        self.r_n = Some(r_n);
        self.state = comparison.state();
        Ok(r_n)
    }

    // A reads the first `reveal`. One that does not open the commitment ends the session.
    pub fn receive_reveal(&mut self, comparison: &mut Comparison, r_n: [u8; 32]) -> Result<(), KeysError> {
        self.require_live()?;
        match comparison.receive_reveal(r_n) {
            Ok(()) => {
                self.r_n = Some(r_n);
                self.state = comparison.state();
                Ok(())
            }
            Err(KeysError::Commitment) => {
                self.state = SessionState::Cancelled;
                self.end = Some(Ended::Cancelled(SessionEnd::Commitment));
                Err(KeysError::Commitment)
            }
            Err(error) => Err(error),
        }
    }

    // The five words. Computed once, when the session moves to its comparison; while it is being compared they come
    // from the same fixed view, never from a step read later.
    pub fn words(&mut self, origin: &Origin, account: AccountId) -> Result<Vec<&'static str>, KeysError> {
        self.require_live()?;
        if !matches!(self.state, SessionState::Revealed | SessionState::Compared) {
            return Err(KeysError::Session);
        }
        let (Some(r_n), Some((a, r_a))) = (self.r_n, self.a) else {
            return Err(KeysError::Session);
        };
        let transcript = transcript(origin, account, self.request, self.ik);
        // r_N opened this commitment when the reveal was taken or read, so a row where it does not was not written here.
        transcript.check_commitment(&self.n, &r_n, &self.commit)?;
        let words = transcript.words(&self.n, &r_n, &a, &r_a)?;
        self.state = SessionState::Compared;
        Ok(words)
    }

    // True when this confirm took the step. A live session already confirmed takes the same confirm again, so a person
    // who retries after a step that failed past it resumes the session instead of meeting `keys.session`.
    pub fn confirm(&mut self) -> Result<bool, KeysError> {
        self.require_live()?;
        match self.state {
            SessionState::Compared => {
                self.state = SessionState::Confirmed;
                Ok(true)
            }
            SessionState::Confirmed => Ok(false),
            _ => Err(KeysError::Session),
        }
    }

    // The person says the words differ: `keys.sas_mismatch`, and the session ends with a `mismatch` cancel.
    pub fn words_differ(&mut self) -> KeysError {
        if let Err(error) = self.require_live() {
            return error;
        }
        if self.state != SessionState::Compared {
            return KeysError::Session;
        }
        self.state = SessionState::Cancelled;
        self.end = Some(Ended::Cancelled(SessionEnd::Mismatch));
        KeysError::SasMismatch
    }

    // A `cancel` step, this side's or the other's.
    pub fn cancel(&mut self, reason: SessionEnd) -> Result<(), KeysError> {
        self.require_live()?;
        self.state = SessionState::Cancelled;
        self.end = Some(Ended::Cancelled(reason));
        Ok(())
    }

    pub fn taken_elsewhere(&mut self) {
        if self.live() {
            self.state = SessionState::Cancelled;
            self.end = Some(Ended::TakenElsewhere);
        }
    }

    pub fn purged_unapproved(&mut self) {
        if self.live() {
            self.state = SessionState::Expired;
            self.end = Some(Ended::Expired);
        }
    }

    // A: its approval change set applied.
    pub fn approved(&mut self) {
        self.end = Some(Ended::Approved);
        self.sent.approval = true;
    }

    // N: the merge committed; `sent.approval` marks its device keys switched to the approved ones.
    pub fn merged(&mut self) {
        self.end = Some(Ended::Approved);
    }

    // The server's `expires_at`, 600 seconds after it took the request. Once approved a session never expires, and
    // N, once its person confirmed, still takes an approval that applied in time however late it arrives: it ends
    // only when the server purges the request with no approval held.
    pub fn expire_if_due(&mut self, now_us: i64) -> bool {
        let merging = self.role == Role::NewDevice && self.state == SessionState::Confirmed;
        if self.live() && !merging && now_us >= self.expires_at_us {
            self.state = SessionState::Expired;
            self.end = Some(Ended::Expired);
            true
        } else {
            false
        }
    }

    // The other side's key device id and keys, as this side's view fixed them.
    pub fn peer(&self) -> Option<SasDevice> {
        match self.role {
            Role::NewDevice => self.a.map(|(a, _)| a),
            Role::Approver => Some(self.n),
        }
    }

    pub fn phase(&mut self, origin: &Origin, account: AccountId) -> Result<SessionPhase, KeysError> {
        let phase = match self.end {
            Some(Ended::Approved) => SessionPhase::Approved,
            Some(Ended::TakenElsewhere) => SessionPhase::TakenElsewhere,
            Some(Ended::Cancelled(reason)) => SessionPhase::Cancelled { reason },
            Some(Ended::Expired) => SessionPhase::Expired,
            None => match self.state {
                SessionState::Open => SessionPhase::Open,
                SessionState::Chosen => SessionPhase::Chosen,
                SessionState::Revealed | SessionState::Compared => {
                    let words = self.words(origin, account)?;
                    SessionPhase::Compare {
                        words: words.into_iter().map(str::to_owned).collect(),
                    }
                }
                SessionState::Confirmed => SessionPhase::Confirmed,
                SessionState::Cancelled | SessionState::Expired => SessionPhase::Expired,
            },
        };
        Ok(phase)
    }

    pub fn to_row(&self) -> KeyComparisonRow {
        let mut view = Vec::with_capacity(256);
        view.push(FORMAT);
        view.extend_from_slice(&self.ik.0);
        push_device(&mut view, &self.n);
        view.extend_from_slice(&self.commit);
        match self.r_n {
            Some(r_n) => {
                view.push(1);
                view.extend_from_slice(&r_n);
            }
            None => view.push(0),
        }
        match self.a {
            Some((a, r_a)) => {
                view.push(1);
                push_device(&mut view, &a);
                view.extend_from_slice(&r_a);
            }
            None => view.push(0),
        }
        view.push(end_code(self.end));
        view.push(sent_bits(self.sent));
        view.extend_from_slice(&self.requested_at_us.to_be_bytes());
        match &self.device {
            Some(device) => {
                view.push(1);
                let bytes = device.0.as_bytes();
                view.extend_from_slice(&u32::try_from(bytes.len()).unwrap_or(u32::MAX).to_be_bytes());
                view.extend_from_slice(bytes);
            }
            None => view.push(0),
        }
        let mut peer = Vec::new();
        if let Some(device) = self.peer() {
            push_device(&mut peer, &device);
        }
        KeyComparisonRow {
            session: self.request,
            role: self.role,
            peer,
            view,
            state: self.state,
            expires_at_us: self.expires_at_us,
        }
    }

    pub fn from_row(row: &KeyComparisonRow) -> Result<Self, SyncError> {
        let malformed = SyncError::Malformed { what: "key comparison" };
        let mut reader = Reader(&row.view);
        if reader.byte().ok_or(malformed.clone())? != FORMAT {
            return Err(malformed);
        }
        let ik = Ed25519Public(reader.array().ok_or(malformed.clone())?);
        let n = reader.device().ok_or(malformed.clone())?;
        let commit = reader.array().ok_or(malformed.clone())?;
        let r_n = match reader.byte() {
            Some(0) => None,
            Some(1) => Some(reader.array().ok_or(malformed.clone())?),
            _ => return Err(malformed),
        };
        let a = match reader.byte() {
            Some(0) => None,
            Some(1) => {
                let device = reader.device().ok_or(malformed.clone())?;
                Some((device, reader.array().ok_or(malformed.clone())?))
            }
            _ => return Err(malformed),
        };
        let end = end_from_code(reader.byte().ok_or(malformed.clone())?).ok_or(malformed.clone())?;
        let sent = sent_from_bits(reader.byte().ok_or(malformed.clone())?).ok_or(malformed.clone())?;
        let requested_at_us = i64::from_be_bytes(reader.array().ok_or(malformed.clone())?);
        let device = match reader.byte() {
            Some(0) => None,
            Some(1) => {
                let len = u32::from_be_bytes(reader.array().ok_or(malformed.clone())?);
                let bytes = reader.take(usize::try_from(len).map_err(|_| malformed.clone())?);
                let text = bytes.and_then(|bytes| String::from_utf8(bytes.to_vec()).ok());
                Some(DeviceRowId(text.ok_or(malformed.clone())?))
            }
            _ => return Err(malformed),
        };
        if !reader.0.is_empty() {
            return Err(malformed);
        }
        let record = Self {
            request: row.session,
            role: row.role,
            state: row.state,
            expires_at_us: row.expires_at_us,
            ik,
            n,
            commit,
            r_n,
            a,
            end,
            sent,
            requested_at_us,
            device,
        };
        let mut peer = Vec::new();
        if let Some(device) = record.peer() {
            push_device(&mut peer, &device);
        }
        // A reveal follows the `nonce` step on both sides, and a session past the reveal holds both.
        let past_reveal = matches!(
            record.state,
            SessionState::Revealed | SessionState::Compared | SessionState::Confirmed
        );
        if peer != row.peer || (record.r_n.is_some() && record.a.is_none()) || (past_reveal && record.r_n.is_none()) {
            return Err(malformed);
        }
        Ok(record)
    }
}

pub(crate) fn transcript(origin: &Origin, account: AccountId, request: RequestId, ik: Ed25519Public) -> Transcript {
    Transcript {
        origin: origin.clone(),
        account,
        request,
        ik,
    }
}

fn push_device(out: &mut Vec<u8>, device: &SasDevice) {
    out.extend_from_slice(device.key_device.0.as_bytes());
    out.extend_from_slice(&device.dek.0);
    out.extend_from_slice(&device.dsk.0);
}

const fn end_code(end: Option<Ended>) -> u8 {
    match end {
        None => 0,
        Some(Ended::Approved) => 1,
        Some(Ended::TakenElsewhere) => 2,
        Some(Ended::Cancelled(SessionEnd::User)) => 3,
        Some(Ended::Cancelled(SessionEnd::Mismatch)) => 4,
        Some(Ended::Cancelled(SessionEnd::Commitment)) => 5,
        Some(Ended::Expired) => 6,
    }
}

const fn end_from_code(code: u8) -> Option<Option<Ended>> {
    match code {
        0 => Some(None),
        1 => Some(Some(Ended::Approved)),
        2 => Some(Some(Ended::TakenElsewhere)),
        3 => Some(Some(Ended::Cancelled(SessionEnd::User))),
        4 => Some(Some(Ended::Cancelled(SessionEnd::Mismatch))),
        5 => Some(Some(Ended::Cancelled(SessionEnd::Commitment))),
        6 => Some(Some(Ended::Expired)),
        _ => None,
    }
}

const fn sent_bits(sent: Sent) -> u8 {
    (sent.opened as u8)
        | (sent.reveal as u8) << 1
        | (sent.approval as u8) << 2
        | (sent.cancel as u8) << 3
        | (sent.purged as u8) << 4
        | (sent.revoke_owed as u8) << 5
}

const fn sent_from_bits(bits: u8) -> Option<Sent> {
    if bits & 0xc0 != 0 {
        return None;
    }
    Some(Sent {
        opened: bits & 1 != 0,
        reveal: bits & 2 != 0,
        approval: bits & 4 != 0,
        cancel: bits & 8 != 0,
        purged: bits & 16 != 0,
        revoke_owed: bits & 32 != 0,
    })
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

    fn byte(&mut self) -> Option<u8> {
        self.take(1).map(|bytes| bytes[0])
    }

    fn array<const N: usize>(&mut self) -> Option<[u8; N]> {
        self.take(N).and_then(|bytes| <[u8; N]>::try_from(bytes).ok())
    }

    fn device(&mut self) -> Option<SasDevice> {
        let bytes = self.take(DEVICE_LEN)?;
        let key_device = KeyDeviceId(Uuid::from_slice(&bytes[..16]).ok()?);
        let dek = X25519Public(<[u8; 32]>::try_from(&bytes[16..48]).ok()?);
        let dsk = Ed25519Public(<[u8; 32]>::try_from(&bytes[48..80]).ok()?);
        Some(SasDevice { key_device, dek, dsk })
    }
}

#[cfg(test)]
mod tests {
    use tablepro_keys::keys::{DeviceKeys, Ed25519Seed};

    use super::*;

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    fn account() -> AccountId {
        AccountId(Uuid::from_u128(1))
    }

    fn device(keys: &DeviceKeys) -> SasDevice {
        SasDevice {
            key_device: keys.key_device,
            dek: keys.dek.public().unwrap(),
            dsk: keys.dsk.public().unwrap(),
        }
    }

    struct Pair {
        n: SessionRecord,
        n_comparison: Comparison,
        a: SessionRecord,
        a_comparison: Option<Comparison>,
        a_device: SasDevice,
    }

    // N wrote its request and A read it.
    fn pair() -> Pair {
        let ik = Ed25519Seed::generate().unwrap().public().unwrap();
        let n_keys = DeviceKeys::generate().unwrap();
        let a_keys = DeviceKeys::generate().unwrap();
        let request = RequestId(Uuid::from_u128(7));
        let (n, n_comparison) =
            SessionRecord::new_device(transcript(&origin(), account(), request, ik), device(&n_keys), 0, 600).unwrap();
        let a = SessionRecord::seen_request(request, ik, device(&n_keys), n.commit, 0, 600, None);
        Pair {
            n,
            n_comparison,
            a,
            a_comparison: None,
            a_device: device(&a_keys),
        }
    }

    impl Pair {
        fn choose(&mut self) -> [u8; 32] {
            let ik = self.a.ik;
            let comparison = self.a.choose(&origin(), account(), ik, self.a_device).unwrap();
            self.a_comparison = Some(comparison);
            self.a.a.unwrap().1
        }

        fn receive_reveal(&mut self, r_n: [u8; 32]) -> Result<(), KeysError> {
            self.a.receive_reveal(self.a_comparison.as_mut().unwrap(), r_n)
        }
    }

    fn through_reveal(pair: &mut Pair) {
        let r_a = pair.choose();
        pair.n
            .receive_nonce(&mut pair.n_comparison, pair.a_device, r_a)
            .unwrap();
        let r_n = pair.n.reveal(&mut pair.n_comparison).unwrap();
        pair.receive_reveal(r_n).unwrap();
    }

    #[test]
    fn both_sides_show_the_same_five_words_and_keep_them_while_compared() {
        let mut pair = pair();
        through_reveal(&mut pair);

        let n_words = pair.n.words(&origin(), account()).unwrap();
        let a_words = pair.a.words(&origin(), account()).unwrap();
        let again = pair.a.words(&origin(), account()).unwrap();

        assert_eq!(n_words.len(), 5);
        assert_eq!(n_words, a_words);
        assert_eq!(again, a_words);
        assert_eq!(pair.a.state, SessionState::Compared);
    }

    #[test]
    fn r_n_reaches_the_row_only_with_the_reveal() {
        let mut pair = pair();
        assert!(pair.n.needs_comparison());
        assert!(!pair.a.needs_comparison(), "A holds no comparison before it chooses");
        let r_a = pair.choose();
        assert!(pair.a.needs_comparison());
        pair.n
            .receive_nonce(&mut pair.n_comparison, pair.a_device, r_a)
            .unwrap();
        assert_eq!(pair.n.r_n, None);

        let r_n = pair.n.reveal(&mut pair.n_comparison).unwrap();
        pair.receive_reveal(r_n).unwrap();

        assert_eq!(pair.n.r_n, Some(r_n));
        assert!(!pair.n.needs_comparison());
        assert!(!pair.a.needs_comparison());
    }

    #[test]
    fn a_reveal_before_the_nonce_is_keys_session() {
        let mut pair = pair();

        let error = pair.n.reveal(&mut pair.n_comparison).unwrap_err();

        assert_eq!(error.code(), "keys.session");
        assert_eq!(pair.n.r_n, None);
    }

    #[test]
    fn a_reveal_that_does_not_open_the_commitment_ends_the_session() {
        let mut pair = pair();
        pair.choose();

        let error = pair.receive_reveal([5; 32]).unwrap_err();

        assert_eq!(error.code(), "keys.commitment");
        assert_eq!(pair.a.end, Some(Ended::Cancelled(SessionEnd::Commitment)));
        assert_eq!(pair.receive_reveal([3; 32]).unwrap_err().code(), "keys.session");
    }

    #[test]
    fn a_commitment_over_other_keys_is_keys_commitment() {
        let mut pair = pair();
        let other = DeviceKeys::generate().unwrap();
        pair.a.n.dek = other.dek.public().unwrap();
        let r_a = pair.choose();
        pair.n
            .receive_nonce(&mut pair.n_comparison, pair.a_device, r_a)
            .unwrap();
        let r_n = pair.n.reveal(&mut pair.n_comparison).unwrap();

        let error = pair.receive_reveal(r_n).unwrap_err();

        assert_eq!(error.code(), "keys.commitment");
    }

    #[test]
    fn a_second_reveal_is_keys_session() {
        let mut pair = pair();
        through_reveal(&mut pair);
        let r_n = pair.n.r_n.unwrap();

        let error = pair.receive_reveal(r_n).unwrap_err();

        assert_eq!(error.code(), "keys.session");
    }

    #[test]
    fn words_that_differ_end_the_session_with_a_mismatch() {
        let mut pair = pair();
        through_reveal(&mut pair);
        pair.n.words(&origin(), account()).unwrap();

        let error = pair.n.words_differ();

        assert_eq!(error.code(), "keys.sas_mismatch");
        assert_eq!(pair.n.end, Some(Ended::Cancelled(SessionEnd::Mismatch)));
        assert_eq!(pair.n.words(&origin(), account()).unwrap_err().code(), "keys.session");
        assert_eq!(pair.n.confirm().unwrap_err().code(), "keys.session");
    }

    #[test]
    fn words_differ_or_a_confirm_before_any_words_is_keys_session() {
        let mut pair = pair();
        through_reveal(&mut pair);

        assert_eq!(pair.n.words_differ().code(), "keys.session");
        assert_eq!(pair.n.confirm().unwrap_err().code(), "keys.session");
        assert!(pair.n.live());
    }

    #[test]
    fn a_confirm_taken_again_keeps_a_live_session_confirmed_and_an_ended_one_refuses_it() {
        let mut pair = pair();
        through_reveal(&mut pair);
        pair.a.words(&origin(), account()).unwrap();

        let first = pair.a.confirm().unwrap();
        let again = pair.a.confirm().unwrap();
        pair.a.approved();

        assert!(first);
        assert!(!again);
        assert_eq!(pair.a.state, SessionState::Confirmed);
        assert_eq!(pair.a.confirm().unwrap_err().code(), "keys.session");
    }

    #[test]
    fn a_nonce_step_with_one_field_changed_gives_n_other_words() {
        let mut pair = pair();
        let mut substituted = pair.a_device;
        substituted.key_device = KeyDeviceId(Uuid::from_u128(99));
        let r_a = pair.choose();
        pair.n.receive_nonce(&mut pair.n_comparison, substituted, r_a).unwrap();
        let r_n = pair.n.reveal(&mut pair.n_comparison).unwrap();
        pair.receive_reveal(r_n).unwrap();

        assert_ne!(
            pair.n.words(&origin(), account()).unwrap(),
            pair.a.words(&origin(), account()).unwrap()
        );
    }

    #[test]
    fn a_request_the_server_swapped_whole_gives_a_other_words() {
        let mut pair = pair();
        let fake_keys = DeviceKeys::generate().unwrap();
        let (fake, mut fake_comparison) = SessionRecord::new_device(
            transcript(&origin(), account(), pair.n.request, pair.n.ik),
            device(&fake_keys),
            0,
            600,
        )
        .unwrap();
        pair.a = SessionRecord::seen_request(pair.n.request, pair.n.ik, fake.n, fake.commit, 0, 600, None);
        let r_a = pair.choose();
        fake_comparison.receive_nonce(pair.a_device, r_a).unwrap();
        let fake_r_n = fake_comparison.reveal().unwrap();
        pair.n
            .receive_nonce(&mut pair.n_comparison, pair.a_device, r_a)
            .unwrap();
        pair.n.reveal(&mut pair.n_comparison).unwrap();
        pair.receive_reveal(fake_r_n).unwrap();

        assert_ne!(
            pair.n.words(&origin(), account()).unwrap(),
            pair.a.words(&origin(), account()).unwrap()
        );
    }

    #[test]
    fn every_step_after_an_end_is_keys_session() {
        let mut cancelled = pair();
        cancelled.n.cancel(SessionEnd::User).unwrap();
        let mut expired = pair();
        assert!(expired.a.expire_if_due(600));
        let ik = expired.a.ik;

        assert_eq!(
            cancelled
                .n
                .receive_nonce(&mut cancelled.n_comparison, cancelled.a_device, [4; 32])
                .unwrap_err()
                .code(),
            "keys.session"
        );
        assert_eq!(
            expired
                .a
                .choose(&origin(), account(), ik, expired.a_device)
                .unwrap_err()
                .code(),
            "keys.session"
        );
        assert_eq!(cancelled.n.cancel(SessionEnd::User).unwrap_err().code(), "keys.session");
        assert!(!cancelled.n.needs_comparison());
        assert_eq!(expired.a.phase(&origin(), account()).unwrap(), SessionPhase::Expired);
    }

    #[test]
    fn a_session_before_expires_at_is_live_and_an_approved_one_never_expires() {
        let mut pair = pair();

        assert!(!pair.n.expire_if_due(599));
        pair.n.approved();

        assert!(!pair.n.expire_if_due(10_000));
        assert_eq!(pair.n.phase(&origin(), account()).unwrap(), SessionPhase::Approved);
    }

    #[test]
    fn n_waiting_for_its_approval_ends_only_when_the_request_is_purged() {
        let mut pair = pair();
        through_reveal(&mut pair);
        pair.n.words(&origin(), account()).unwrap();
        pair.n.confirm().unwrap();

        assert!(!pair.n.expire_if_due(i64::MAX));
        pair.n.purged_unapproved();

        assert_eq!(pair.n.phase(&origin(), account()).unwrap(), SessionPhase::Expired);
    }

    #[test]
    fn a_row_round_trips_and_a_tampered_one_is_refused() {
        let mut pair = pair();
        through_reveal(&mut pair);
        pair.a.words(&origin(), account()).unwrap();
        pair.a.sent.opened = true;
        pair.a.sent.purged = true;
        pair.a.device = Some(DeviceRowId("dev_1".to_owned()));

        let row = pair.a.to_row();
        let back = SessionRecord::from_row(&row).unwrap();
        let mut bad_peer = row.clone();
        bad_peer.peer[0] ^= 1;
        let mut bad_view = row.clone();
        bad_view.view.push(0);
        let mut no_reveal = pair.a.clone();
        no_reveal.r_n = None;

        assert_eq!(back.to_row(), row);
        assert_eq!(
            back.clone().words(&origin(), account()).unwrap(),
            pair.a.words(&origin(), account()).unwrap()
        );
        assert!(SessionRecord::from_row(&bad_peer).is_err());
        assert!(SessionRecord::from_row(&bad_view).is_err());
        assert!(
            SessionRecord::from_row(&no_reveal.to_row()).is_err(),
            "a compared session holds the r_N it compared"
        );
    }

    #[test]
    fn a_row_whose_r_n_does_not_open_its_commitment_is_refused() {
        let mut pair = pair();
        through_reveal(&mut pair);
        pair.n.r_n = Some([9; 32]);

        let error = pair.n.words(&origin(), account()).unwrap_err();

        assert_eq!(error.code(), "keys.commitment");
    }
}
