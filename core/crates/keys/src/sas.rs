// Device approval's transcript (ADR 0056, Approving a device): N commits to its view before r_A
// exists, A's create-only `nonce` step fixes r_A before r_N is revealed, and each side hashes
// its own view into five words.

use crate::KeysError;
use crate::crypto;
use crate::encoding::{AccountId, Frame, KeyDeviceId, Label, Origin, RequestId};
use crate::keys::{Ed25519Public, X25519Public};
use crate::words;

pub const SAS_WORDS: usize = 5;

// One side's key device id and keys, as the request or the `nonce` step carries them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SasDevice {
    pub key_device: KeyDeviceId,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
}

// What both sides fix: the account, the request and the account's IK (N's from the newest
// certificate it read, A's its own account's).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transcript {
    pub origin: Origin,
    pub account: AccountId,
    pub request: RequestId,
    pub ik: Ed25519Public,
}

impl Transcript {
    fn frame(&self, label: Label, n: &SasDevice, r_n: &[u8; 32]) -> Frame {
        let mut frame = Frame::new(label);
        frame
            .origin(&self.origin)
            .id(self.account.0)
            .id(self.request.0)
            .id(n.key_device.0)
            .lp(&self.ik.0)
            .lp(&n.dek.0)
            .lp(&n.dsk.0)
            .lp(r_n);
        frame
    }

    pub fn commitment(&self, n: &SasDevice, r_n: &[u8; 32]) -> Result<[u8; 32], KeysError> {
        Ok(crypto::sha256(&self.frame(Label::SasCommit, n, r_n).finish()?))
    }

    pub fn check_commitment(&self, n: &SasDevice, r_n: &[u8; 32], commit: &[u8; 32]) -> Result<(), KeysError> {
        if self.commitment(n, r_n)? == *commit {
            Ok(())
        } else {
            Err(KeysError::Commitment)
        }
    }

    pub fn digest(&self, n: &SasDevice, r_n: &[u8; 32], a: &SasDevice, r_a: &[u8; 32]) -> Result<[u8; 32], KeysError> {
        let mut frame = self.frame(Label::Sas, n, r_n);
        frame.id(a.key_device.0).lp(&a.dek.0).lp(&a.dsk.0).lp(r_a);
        Ok(crypto::sha256(&frame.finish()?))
    }

    pub fn words(
        &self,
        n: &SasDevice,
        r_n: &[u8; 32],
        a: &SasDevice,
        r_a: &[u8; 32],
    ) -> Result<Vec<&'static str>, KeysError> {
        Ok(words::words(&self.digest(n, r_n, a, r_a)?, SAS_WORDS))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    NewDevice,
    Approver,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    // N's request is written.
    Open,
    // A's `nonce` step is written.
    Chosen,
    // N's `reveal` step is written; for A, it opened the commitment.
    Revealed,
    // This side showed its words, which it does once.
    Compared,
    Confirmed,
    Cancelled,
    Expired,
}

// One comparison session as one side sees it. Each step is taken once and in order; a step out
// of order, a second comparison or a step after the session ended is keys.session.
#[derive(Debug, Clone)]
pub struct Comparison {
    role: Role,
    state: SessionState,
    transcript: Transcript,
    n: SasDevice,
    r_n: Option<[u8; 32]>,
    commit: [u8; 32],
    a: Option<(SasDevice, [u8; 32])>,
}

impl Comparison {
    // N, having fixed its view and drawn r_N; the request carries `commit`.
    pub fn new_device(transcript: Transcript, n: SasDevice, r_n: [u8; 32]) -> Result<Self, KeysError> {
        let commit = transcript.commitment(&n, &r_n)?;
        Ok(Self {
            role: Role::NewDevice,
            state: SessionState::Open,
            transcript,
            n,
            r_n: Some(r_n),
            commit,
            a: None,
        })
    }

    // A, having written its `nonce` step for the request it read.
    pub fn approver(transcript: Transcript, n: SasDevice, commit: [u8; 32], a: SasDevice, r_a: [u8; 32]) -> Self {
        Self {
            role: Role::Approver,
            state: SessionState::Chosen,
            transcript,
            n,
            r_n: None,
            commit,
            a: Some((a, r_a)),
        }
    }

    pub fn role(&self) -> Role {
        self.role
    }

    pub fn state(&self) -> SessionState {
        self.state
    }

    pub fn commit(&self) -> [u8; 32] {
        self.commit
    }

    fn step(&mut self, role: Role, from: SessionState, to: SessionState) -> Result<(), KeysError> {
        if self.role != role || self.state != from {
            return Err(KeysError::Session);
        }
        self.state = to;
        Ok(())
    }

    // N reads A's `nonce` step.
    pub fn receive_nonce(&mut self, a: SasDevice, r_a: [u8; 32]) -> Result<(), KeysError> {
        self.step(Role::NewDevice, SessionState::Open, SessionState::Chosen)?;
        self.a = Some((a, r_a));
        Ok(())
    }

    // N's `reveal` step, only once r_A is fixed.
    pub fn reveal(&mut self) -> Result<[u8; 32], KeysError> {
        let r_n = self.r_n.ok_or(KeysError::Session)?;
        self.step(Role::NewDevice, SessionState::Chosen, SessionState::Revealed)?;
        Ok(r_n)
    }

    // A reads N's first `reveal`: it must open the commitment with the keys the request carries.
    pub fn receive_reveal(&mut self, r_n: [u8; 32]) -> Result<(), KeysError> {
        if self.role != Role::Approver || self.state != SessionState::Chosen {
            return Err(KeysError::Session);
        }
        if let Err(error) = self.transcript.check_commitment(&self.n, &r_n, &self.commit) {
            self.state = SessionState::Cancelled;
            return Err(error);
        }
        self.r_n = Some(r_n);
        self.state = SessionState::Revealed;
        Ok(())
    }

    // The five words, shown once per session.
    pub fn words(&mut self) -> Result<Vec<&'static str>, KeysError> {
        let (Some(r_n), Some((a, r_a))) = (self.r_n, self.a) else {
            return Err(KeysError::Session);
        };
        self.step(self.role, SessionState::Revealed, SessionState::Compared)?;
        self.transcript.words(&self.n, &r_n, &a, &r_a)
    }

    pub fn confirm(&mut self) -> Result<(), KeysError> {
        self.step(self.role, SessionState::Compared, SessionState::Confirmed)
    }

    // The person says the words differ: the session ends with a `mismatch` cancel.
    pub fn words_differ(&mut self) -> KeysError {
        if self.state == SessionState::Compared {
            self.state = SessionState::Cancelled;
            KeysError::SasMismatch
        } else {
            KeysError::Session
        }
    }

    pub fn receive_cancel(&mut self) -> Result<(), KeysError> {
        if matches!(self.state, SessionState::Cancelled | SessionState::Expired) {
            return Err(KeysError::Session);
        }
        self.state = SessionState::Cancelled;
        Ok(())
    }

    // The server's `expires_at`, 600 seconds after it took the request.
    pub fn check_live(&mut self, now: u64, expires_at: u64) -> Result<(), KeysError> {
        if matches!(self.state, SessionState::Cancelled | SessionState::Expired) {
            return Err(KeysError::Session);
        }
        if now >= expires_at {
            self.state = SessionState::Expired;
            return Err(KeysError::Session);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{Comparison, SasDevice, SessionState, Transcript};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyDeviceId, Origin, RequestId};
    use crate::keys::{DeviceKeys, Ed25519Seed};

    fn device(keys: &DeviceKeys) -> SasDevice {
        SasDevice {
            key_device: keys.key_device,
            dek: keys.dek.public().unwrap(),
            dsk: keys.dsk.public().unwrap(),
        }
    }

    fn transcript(ik: &Ed25519Seed) -> Transcript {
        Transcript {
            origin: Origin::parse("https://sync.example.com").unwrap(),
            account: AccountId(Uuid::from_u128(1)),
            request: RequestId(Uuid::from_u128(2)),
            ik: ik.public().unwrap(),
        }
    }

    #[test]
    fn both_sides_show_the_same_words() {
        let ik = Ed25519Seed::generate().unwrap();
        let n_keys = DeviceKeys::generate().unwrap();
        let a_keys = DeviceKeys::generate().unwrap();
        let mut n = Comparison::new_device(transcript(&ik), device(&n_keys), [3; 32]).unwrap();
        let mut a = Comparison::approver(transcript(&ik), device(&n_keys), n.commit(), device(&a_keys), [4; 32]);
        assert_eq!(
            n.reveal().unwrap_err(),
            KeysError::Session,
            "no reveal before the nonce"
        );
        n.receive_nonce(device(&a_keys), [4; 32]).unwrap();
        let r_n = n.reveal().unwrap();
        a.receive_reveal(r_n).unwrap();
        let n_words = n.words().unwrap();
        assert_eq!(n_words, a.words().unwrap());
        assert_eq!(n_words.len(), 5);
        assert_eq!(a.words().unwrap_err(), KeysError::Session, "one comparison per session");
        n.confirm().unwrap();
        a.confirm().unwrap();
        assert_eq!(a.receive_reveal(r_n).unwrap_err(), KeysError::Session);
    }

    #[test]
    fn a_reveal_that_does_not_open_the_commitment_ends_the_session() {
        let ik = Ed25519Seed::generate().unwrap();
        let n_keys = DeviceKeys::generate().unwrap();
        let a_keys = DeviceKeys::generate().unwrap();
        let n = Comparison::new_device(transcript(&ik), device(&n_keys), [3; 32]).unwrap();
        let mut a = Comparison::approver(transcript(&ik), device(&n_keys), n.commit(), device(&a_keys), [4; 32]);
        assert_eq!(a.receive_reveal([5; 32]).unwrap_err(), KeysError::Commitment);
        assert_eq!(a.state(), SessionState::Cancelled);
    }

    #[test]
    fn a_changed_field_on_one_side_changes_the_words() {
        let ik = Ed25519Seed::generate().unwrap();
        let n_keys = DeviceKeys::generate().unwrap();
        let a_keys = DeviceKeys::generate().unwrap();
        let view = transcript(&ik);
        let words = view
            .words(&device(&n_keys), &[3; 32], &device(&a_keys), &[4; 32])
            .unwrap();
        let mut other_id = device(&n_keys);
        other_id.key_device = KeyDeviceId(Uuid::from_u128(99));
        assert_ne!(
            view.words(&other_id, &[3; 32], &device(&a_keys), &[4; 32]).unwrap(),
            words
        );
        let mut other_ik = view.clone();
        other_ik.ik = Ed25519Seed::generate().unwrap().public().unwrap();
        assert_ne!(
            other_ik
                .words(&device(&n_keys), &[3; 32], &device(&a_keys), &[4; 32])
                .unwrap(),
            words
        );
    }

    #[test]
    fn a_session_after_its_end_refuses_every_step() {
        let ik = Ed25519Seed::generate().unwrap();
        let n_keys = DeviceKeys::generate().unwrap();
        let mut n = Comparison::new_device(transcript(&ik), device(&n_keys), [3; 32]).unwrap();
        assert_eq!(n.check_live(599, 600), Ok(()));
        assert_eq!(n.check_live(600, 600), Err(KeysError::Session));
        assert_eq!(
            n.receive_nonce(device(&n_keys), [1; 32]).unwrap_err(),
            KeysError::Session
        );
        assert_eq!(n.receive_cancel().unwrap_err(), KeysError::Session);
    }
}
