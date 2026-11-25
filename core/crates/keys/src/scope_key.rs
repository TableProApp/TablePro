use crate::KeysError;
use crate::crypto::{self, NONCE_LEN, TAG_LEN};
use crate::encoding::{AccountId, Frame, KeyPurpose, Label, Origin, Scope, Version};
use crate::keys::{Ed25519Public, Ed25519Seed, Kid, ScopeKey, Signature};
use uuid::Uuid;

pub const RING_PLAINTEXT_LEN: usize = 4 + 32;
pub const RING_CT_LEN: usize = RING_PLAINTEXT_LEN + TAG_LEN;

// A scope key as its version records, rings and wraps name it: the owner (the account for
// `personal` and `history`, the team for `team`), the purpose and the version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct KeyRef {
    pub owner: Uuid,
    pub purpose: KeyPurpose,
    pub version: Version,
}

impl KeyRef {
    pub fn scope(self) -> Scope {
        self.purpose.scope(self.owner)
    }
}

// `start` is 0 for the next version of a key and 1 for a version that starts it over.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Start {
    Next,
    Over,
}

impl Start {
    pub fn code(self) -> u8 {
        match self {
            Self::Next => 0,
            Self::Over => 1,
        }
    }

    pub fn from_code(code: i64) -> Result<Self, KeysError> {
        match code {
            0 => Ok(Self::Next),
            1 => Ok(Self::Over),
            _ => Err(KeysError::encoding("start is not 0 or 1")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionRecord {
    pub key: KeyRef,
    pub start: Start,
    pub kid: Kid,
    pub signer: AccountId,
    pub signer_av: Version,
    pub sig: Signature,
}

pub fn version_message(
    origin: &Origin,
    key: KeyRef,
    start: Start,
    kid: &Kid,
    signer: AccountId,
    signer_av: Version,
) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Version);
    frame
        .origin(origin)
        .scope(key.scope())
        .lp(key.purpose.name().as_bytes())
        .u32(key.version.get())
        .u8(start.code())
        .lp(&kid.0)
        .id(signer.0)
        .u32(signer_av.get());
    frame.finish()
}

impl VersionRecord {
    pub fn sign(
        origin: &Origin,
        key: KeyRef,
        start: Start,
        scope_key: &ScopeKey,
        signer: AccountId,
        signer_av: Version,
        signer_ask: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        let kid = scope_key.kid()?;
        let sig = signer_ask.sign(&version_message(origin, key, start, &kid, signer, signer_av)?)?;
        Ok(Self {
            key,
            start,
            kid,
            signer,
            signer_av,
            sig,
        })
    }

    pub fn message(&self, origin: &Origin) -> Result<Vec<u8>, KeysError> {
        version_message(origin, self.key, self.start, &self.kid, self.signer, self.signer_av)
    }

    // `signer_ask` is the ASK of the signer's certificate at `signer_av`.
    pub fn verify(&self, origin: &Origin, signer_ask: &Ed25519Public) -> Result<(), KeysError> {
        signer_ask.verify(&self.message(origin)?, &self.sig)
    }

    // The SHA-256 of the record's signed bytes: what a client anchors and what a trust plaintext names.
    pub fn digest(&self, origin: &Origin) -> Result<[u8; 32], KeysError> {
        Ok(crypto::sha256(&self.message(origin)?))
    }

    // A key unwrapped or read from a ring must match the record's kid (AES-GCM does not commit to its key).
    pub fn check_key(&self, key: &ScopeKey) -> Result<(), KeysError> {
        if key.kid()? == self.kid {
            Ok(())
        } else {
            Err(KeysError::Kid)
        }
    }
}

// `u32(v - 1) || K_(v-1)` under an HKDF subkey of K_v, written with version v's record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ring {
    pub nonce: [u8; NONCE_LEN],
    pub ct: [u8; RING_CT_LEN],
}

fn ring_key(origin: &Origin, key: KeyRef, newer: &ScopeKey) -> Result<zeroize::Zeroizing<[u8; 32]>, KeysError> {
    let mut info = Frame::new(Label::RingKey);
    info.origin(origin)
        .scope(key.scope())
        .lp(key.purpose.name().as_bytes())
        .u32(key.version.get());
    crypto::hkdf32(newer.expose(), &info.finish()?)
}

pub fn ring_aad(origin: &Origin, key: KeyRef) -> Result<Vec<u8>, KeysError> {
    let mut aad = Frame::new(Label::Ring);
    aad.origin(origin)
        .scope(key.scope())
        .lp(key.purpose.name().as_bytes())
        .u32(key.version.get());
    aad.finish()
}

impl Ring {
    // `key` names version v, the ring's own; `newer` is K_v and `older` K_(v-1).
    pub fn seal(origin: &Origin, key: KeyRef, newer: &ScopeKey, older: &ScopeKey) -> Result<Self, KeysError> {
        Self::seal_with_nonce(origin, key, newer, older, crypto::random_array()?)
    }

    pub fn seal_with_nonce(
        origin: &Origin,
        key: KeyRef,
        newer: &ScopeKey,
        older: &ScopeKey,
        nonce: [u8; NONCE_LEN],
    ) -> Result<Self, KeysError> {
        let below = key.version.previous().ok_or(KeysError::Ring)?;
        let mut plaintext = zeroize::Zeroizing::new([0_u8; RING_PLAINTEXT_LEN]);
        plaintext[..4].copy_from_slice(&below.get().to_be_bytes());
        plaintext[4..].copy_from_slice(older.expose());
        let ct = crypto::aes_seal(
            &*ring_key(origin, key, newer)?,
            &nonce,
            &ring_aad(origin, key)?,
            plaintext.as_slice(),
        )?;
        let ct = <[u8; RING_CT_LEN]>::try_from(ct.as_slice()).map_err(|_| KeysError::encoding("ring ct length"))?;
        Ok(Self { nonce, ct })
    }

    // Opens version v's ring with K_v and checks the key it holds against version v-1's record.
    pub fn open(
        &self,
        origin: &Origin,
        key: KeyRef,
        newer: &ScopeKey,
        below: &VersionRecord,
    ) -> Result<ScopeKey, KeysError> {
        let plaintext = crypto::aes_open(
            &*ring_key(origin, key, newer)?,
            &self.nonce,
            &ring_aad(origin, key)?,
            &self.ct,
        )?;
        let mut version = [0_u8; 4];
        version.copy_from_slice(&plaintext[..4]);
        let expected = key.version.previous().ok_or(KeysError::Ring)?;
        if u32::from_be_bytes(version) != expected.get() {
            return Err(KeysError::Ring);
        }
        if below.key
            != (KeyRef {
                version: expected,
                ..key
            })
        {
            return Err(KeysError::encoding(
                "the version record is not the ring's version below",
            ));
        }
        let older = ScopeKey::from_slice(&plaintext[4..])?;
        below.check_key(&older)?;
        Ok(older)
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{KeyRef, Ring, Start, VersionRecord};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyPurpose, Origin, Version};
    use crate::keys::{Ed25519Seed, ScopeKey};

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    fn key_ref(version: u32) -> KeyRef {
        KeyRef {
            owner: Uuid::from_u128(7),
            purpose: KeyPurpose::Team,
            version: Version::new(version).unwrap(),
        }
    }

    #[test]
    fn a_walk_down_three_rings() {
        let ask = Ed25519Seed::generate().unwrap();
        let signer = AccountId(Uuid::from_u128(1));
        let av = Version::FIRST;
        let keys: Vec<ScopeKey> = (0..4).map(|_| ScopeKey::generate().unwrap()).collect();
        let records: Vec<VersionRecord> = (0..4)
            .map(|index| {
                let start = if index == 0 { Start::Over } else { Start::Next };
                VersionRecord::sign(
                    &origin(),
                    key_ref(index + 1),
                    start,
                    &keys[index as usize],
                    signer,
                    av,
                    &ask,
                )
                .unwrap()
            })
            .collect();
        for record in &records {
            assert_eq!(record.verify(&origin(), &ask.public().unwrap()), Ok(()));
        }
        let rings: Vec<Ring> = (1..4)
            .map(|index| {
                Ring::seal(
                    &origin(),
                    key_ref(index + 1),
                    &keys[index as usize],
                    &keys[index as usize - 1],
                )
                .unwrap()
            })
            .collect();

        let mut current = keys[3].clone();
        for version in (2..=4).rev() {
            let ring = &rings[version as usize - 2];
            current = ring
                .open(&origin(), key_ref(version), &current, &records[version as usize - 2])
                .unwrap();
        }
        assert_eq!(current.expose(), keys[0].expose());

        assert!(matches!(
            rings[2].open(&origin(), key_ref(4), &keys[3], &records[1]).unwrap_err(),
            KeysError::Encoding { .. }
        ));
        let mut wrong_kid = records[2].clone();
        wrong_kid.kid = keys[0].kid().unwrap();
        assert_eq!(
            rings[2].open(&origin(), key_ref(4), &keys[3], &wrong_kid).unwrap_err(),
            KeysError::Kid
        );
        assert_eq!(
            rings[2].open(&origin(), key_ref(4), &keys[2], &records[2]).unwrap_err(),
            KeysError::Open
        );
    }
}
