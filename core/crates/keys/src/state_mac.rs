use zeroize::Zeroizing;

use crate::KeysError;
use crate::crypto;
use crate::encoding::{AccountId, Frame, Label, Origin};

// The state file's MAC (ADR 0054, Integrity and freshness):
// HMAC-SHA256(key, LP("tablepro/v1/state") || LP("tp1") || LP(origin) || LP(account) || state), with
// state = LP(file id) || LP(counter) || LP(key digest) || LP(sync digest) and the counter 8 bytes big-endian.
#[derive(Debug, Clone, Copy)]
pub struct StateSnapshot<'a> {
    pub file_id: &'a [u8; 16],
    pub counter: u64,
    pub key_digest: &'a [u8; 32],
    pub sync_digest: &'a [u8; 32],
}

pub fn state_mac_input(origin: &Origin, account: AccountId, state: StateSnapshot<'_>) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::State);
    frame
        .origin(origin)
        .id(account.0)
        .lp(state.file_id)
        .lp(&state.counter.to_be_bytes())
        .lp(state.key_digest)
        .lp(state.sync_digest);
    frame.finish()
}

pub fn state_mac(
    key: &Zeroizing<[u8; 32]>,
    origin: &Origin,
    account: AccountId,
    state: StateSnapshot<'_>,
) -> Result<[u8; 32], KeysError> {
    Ok(crypto::hmac_sha256(
        key.as_slice(),
        &state_mac_input(origin, account, state)?,
    ))
}
