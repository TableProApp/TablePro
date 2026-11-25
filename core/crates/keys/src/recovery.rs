use std::fmt;

use secrecy::SecretString;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::KeysError;
use crate::base32;
use crate::crypto::{self, NONCE_LEN};
use crate::encoding::{AccountId, Frame, Label, Origin, Version};
use crate::keys::{AccountKeys, Ed25519Seed};

pub const BLOB_CT_LEN: usize = 64 + crypto::TAG_LEN;

// R: 32 bytes from the system RNG, in memory only while a flow uses it.
#[derive(Clone)]
pub struct RecoveryKey(Zeroizing<[u8; 32]>);

impl fmt::Debug for RecoveryKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("RecoveryKey(redacted)")
    }
}

impl Zeroize for RecoveryKey {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl ZeroizeOnDrop for RecoveryKey {}

// The recovery blob of one `av`: `ASK seed || AEK private key` under K_rec, unpadded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecoveryBlob {
    pub nonce: [u8; NONCE_LEN],
    pub ct: [u8; BLOB_CT_LEN],
}

impl RecoveryKey {
    pub fn generate() -> Result<Self, KeysError> {
        let mut bytes = Zeroizing::new([0_u8; 32]);
        crypto::random(bytes.as_mut())?;
        Ok(Self(bytes))
    }

    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(Zeroizing::new(bytes))
    }

    pub fn expose(&self) -> &[u8; 32] {
        &self.0
    }

    fn checksum(r: &[u8; 32]) -> Result<[u8; 3], KeysError> {
        let mut frame = Frame::new(Label::RecoveryChecksum);
        frame.lp(r);
        let digest = crypto::sha256(&frame.finish()?);
        Ok([digest[0], digest[1], digest[2]])
    }

    // B = R || checksum, 35 bytes, as 56 symbols in 14 groups of 4 joined by `-`.
    pub fn to_text(&self) -> Result<SecretString, KeysError> {
        let mut b = Zeroizing::new([0_u8; 35]);
        b[..32].copy_from_slice(self.expose());
        b[32..].copy_from_slice(&Self::checksum(self.expose())?);
        let symbols = Zeroizing::new(base32::encode(b.as_slice()));
        let mut text = String::with_capacity(69);
        for (index, symbol) in symbols.chars().enumerate() {
            if index > 0 && index % 4 == 0 {
                text.push('-');
            }
            text.push(symbol);
        }
        Ok(SecretString::from(text))
    }

    // Drops hyphens and spaces, upper-cases, reads O as 0 and I and L as 1.
    pub fn parse(text: &str) -> Result<Self, KeysError> {
        let mut symbols = Zeroizing::new(String::with_capacity(56));
        for character in text.chars() {
            match character.to_ascii_uppercase() {
                '-' | ' ' => {}
                'O' => symbols.push('0'),
                'I' | 'L' => symbols.push('1'),
                other => symbols.push(other),
            }
        }
        if symbols.len() != 56 {
            return Err(KeysError::RecoveryKey);
        }
        let b = Zeroizing::new(base32::decode(&symbols).map_err(|_| KeysError::RecoveryKey)?);
        if b.len() != 35 {
            return Err(KeysError::RecoveryKey);
        }
        let mut r = Zeroizing::new([0_u8; 32]);
        r.copy_from_slice(&b[..32]);
        if Self::checksum(&r)? != b[32..35] {
            return Err(KeysError::RecoveryKey);
        }
        Ok(Self(r))
    }

    // IK's seed: HKDF-SHA256(R, LP("tablepro/v1/identity") || LP("tp1") || LP(origin) || LP(account)).
    pub fn identity_seed(&self, origin: &Origin, account: AccountId) -> Result<Ed25519Seed, KeysError> {
        let mut info = Frame::new(Label::Identity);
        info.origin(origin).id(account.0);
        crypto::hkdf32(self.expose(), &info.finish()?).map(|seed| Ed25519Seed::from_bytes(*seed))
    }

    pub fn blob_key(&self, origin: &Origin, account: AccountId) -> Result<Zeroizing<[u8; 32]>, KeysError> {
        let mut info = Frame::new(Label::RecoveryWrap);
        info.origin(origin).id(account.0);
        crypto::hkdf32(self.expose(), &info.finish()?)
    }

    pub fn seal_blob(
        &self,
        origin: &Origin,
        account: AccountId,
        av: Version,
        keys: &AccountKeys,
    ) -> Result<RecoveryBlob, KeysError> {
        self.seal_blob_with_nonce(origin, account, av, keys, crypto::random_array()?)
    }

    pub fn seal_blob_with_nonce(
        &self,
        origin: &Origin,
        account: AccountId,
        av: Version,
        keys: &AccountKeys,
        nonce: [u8; NONCE_LEN],
    ) -> Result<RecoveryBlob, KeysError> {
        let key = self.blob_key(origin, account)?;
        let ct = crypto::aes_seal(
            &key,
            &nonce,
            &blob_aad(origin, account, av)?,
            keys.to_plaintext().as_slice(),
        )?;
        let ct = <[u8; BLOB_CT_LEN]>::try_from(ct.as_slice()).map_err(|_| KeysError::encoding("blob ct length"))?;
        Ok(RecoveryBlob { nonce, ct })
    }

    // The caller then checks the keys against the certificate at `av` (AccountKeys::check_against).
    pub fn open_blob(
        &self,
        origin: &Origin,
        account: AccountId,
        av: Version,
        blob: &RecoveryBlob,
    ) -> Result<AccountKeys, KeysError> {
        let key = self.blob_key(origin, account)?;
        let plaintext = crypto::aes_open(&key, &blob.nonce, &blob_aad(origin, account, av)?, &blob.ct)?;
        AccountKeys::from_plaintext(&plaintext)
    }
}

pub fn blob_aad(origin: &Origin, account: AccountId, av: Version) -> Result<Vec<u8>, KeysError> {
    let mut aad = Frame::new(Label::Recovery);
    aad.origin(origin).id(account.0).u32(av.get());
    aad.finish()
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;
    use secrecy::ExposeSecret;
    use uuid::Uuid;

    use super::RecoveryKey;
    use crate::KeysError;
    use crate::encoding::{AccountId, Origin, Version};
    use crate::keys::AccountKeys;

    #[test]
    fn text_is_fourteen_groups_of_four() {
        let text = RecoveryKey::from_bytes([0; 32]).to_text().unwrap();
        let groups: Vec<_> = text.expose_secret().split('-').collect();
        assert_eq!(groups.len(), 14);
        assert!(groups.iter().all(|group| group.len() == 4));
    }

    #[test]
    fn reading_forgives_case_hyphens_spaces_and_lookalikes() {
        let r = RecoveryKey::from_bytes([0; 32]);
        let text = r.to_text().unwrap().expose_secret().to_owned();
        let sloppy = text.to_lowercase().replace('0', "o").replace('-', " ");
        assert_eq!(RecoveryKey::parse(&sloppy).unwrap().expose(), r.expose());
    }

    #[test]
    fn a_bad_checksum_or_length_is_refused() {
        let text = RecoveryKey::from_bytes([5; 32])
            .to_text()
            .unwrap()
            .expose_secret()
            .to_owned();
        let mut changed: Vec<char> = text.chars().collect();
        changed[0] = if changed[0] == '1' { '2' } else { '1' };
        let changed: String = changed.into_iter().collect();
        assert_eq!(RecoveryKey::parse(&changed).unwrap_err(), KeysError::RecoveryKey);
        assert_eq!(
            RecoveryKey::parse(&text[..text.len() - 1]).unwrap_err(),
            KeysError::RecoveryKey
        );
        assert_eq!(
            RecoveryKey::parse(&format!("{text}0")).unwrap_err(),
            KeysError::RecoveryKey
        );
        assert_eq!(
            RecoveryKey::parse(&text.replace('-', "\t")).unwrap_err(),
            KeysError::RecoveryKey
        );
    }

    #[test]
    fn the_blob_opens_only_for_its_origin_account_and_av() {
        let r = RecoveryKey::generate().unwrap();
        let origin = Origin::parse("https://sync.example.com").unwrap();
        let account = AccountId(Uuid::from_u128(1));
        let av = Version::new(3).unwrap();
        let keys = AccountKeys::generate().unwrap();
        let blob = r.seal_blob(&origin, account, av, &keys).unwrap();
        let opened = r.open_blob(&origin, account, av, &blob).unwrap();
        assert_eq!(opened.ask.expose(), keys.ask.expose());
        let other = Origin::parse("https://other.example.com").unwrap();
        assert_eq!(r.open_blob(&other, account, av, &blob).unwrap_err(), KeysError::Open);
        assert_eq!(
            r.open_blob(&origin, AccountId(Uuid::from_u128(2)), av, &blob)
                .unwrap_err(),
            KeysError::Open
        );
        assert_eq!(
            r.open_blob(&origin, account, Version::new(4).unwrap(), &blob)
                .unwrap_err(),
            KeysError::Open
        );
    }

    proptest! {
        #[test]
        fn text_round_trips(bytes in any::<[u8; 32]>()) {
            let r = RecoveryKey::from_bytes(bytes);
            let text = r.to_text().unwrap();
            let parsed = RecoveryKey::parse(text.expose_secret()).unwrap();
            prop_assert_eq!(parsed.expose(), &bytes);
        }
    }
}
