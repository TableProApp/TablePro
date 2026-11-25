use uuid::Uuid;
use zeroize::Zeroizing;

use crate::KeysError;
use crate::crypto::{self, TAG_LEN};
use crate::encoding::{AccountId, Frame, KeyDeviceId, Label, Origin, Scope, Version, WrapPurpose};
use crate::keys::{
    AccountKeys, AccountPublicKeys, Ed25519Public, Ed25519Seed, ScopeKey, Signature, X25519Public, X25519Secret,
};
use crate::scope_key::{KeyRef, VersionRecord};
use crate::trust::TrustPlaintext;

pub const ACCOUNT_CT_LEN: usize = 64 + TAG_LEN;
pub const SCOPE_KEY_CT_LEN: usize = 32 + TAG_LEN;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Recipient {
    // `account` and `trust` wraps go to a key device at the `av`.
    Device(KeyDeviceId),
    // Scope keys go to an account at its `av`.
    Account(AccountId),
}

impl Recipient {
    pub fn type_name(self) -> &'static str {
        match self {
            Self::Device(_) => "device",
            Self::Account(_) => "account",
        }
    }

    pub fn id(self) -> Uuid {
        match self {
            Self::Device(device) => device.0,
            Self::Account(account) => account.0,
        }
    }
}

// What a `key.wrap` record id names: the owner, purpose and version of what it wraps, and the
// recipient at its version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct WrapTarget {
    pub owner: Uuid,
    pub purpose: WrapPurpose,
    pub version: Version,
    pub recipient: Recipient,
    pub recipient_version: Version,
}

impl WrapTarget {
    pub fn scope(self) -> Scope {
        self.purpose.scope(self.owner)
    }

    // ADR 0052: `account` and `trust` go to a device at the `av` they carry; scope keys to an account.
    pub fn check_form(self) -> Result<(), KeysError> {
        let well_formed = match (self.purpose, self.recipient) {
            (WrapPurpose::Account | WrapPurpose::Trust, Recipient::Device(_)) => self.recipient_version == self.version,
            (WrapPurpose::Key(_), Recipient::Account(_)) => true,
            _ => false,
        };
        if well_formed {
            Ok(())
        } else {
            Err(KeysError::encoding("wrap recipient does not fit its purpose"))
        }
    }

    pub fn expected_ct_len(self) -> Option<usize> {
        match self.purpose {
            WrapPurpose::Account => Some(ACCOUNT_CT_LEN),
            WrapPurpose::Key(_) => Some(SCOPE_KEY_CT_LEN),
            WrapPurpose::Trust => None,
        }
    }
}

// Who signed a wrap, as its fields name it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Wrapper {
    pub account: AccountId,
    pub av: Version,
    pub key_device: KeyDeviceId,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Wrap {
    pub target: WrapTarget,
    pub enc: [u8; 32],
    pub ct: Vec<u8>,
    pub wrapper: Wrapper,
    pub sig: Signature,
}

pub fn wrap_info(origin: &Origin, target: WrapTarget, pk_r: &X25519Public) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Wrap);
    frame
        .origin(origin)
        .scope(target.scope())
        .lp(target.purpose.name().as_bytes())
        .u32(target.version.get())
        .lp(target.recipient.type_name().as_bytes())
        .id(target.recipient.id())
        .u32(target.recipient_version.get())
        .lp(&pk_r.0);
    frame.finish()
}

pub fn wrap_sig_message(info: &[u8], enc: &[u8; 32], ct: &[u8], wrapper: Wrapper) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::WrapSig);
    frame
        .lp(info)
        .lp(enc)
        .lp(ct)
        .id(wrapper.account.0)
        .u32(wrapper.av.get())
        .id(wrapper.key_device.0);
    frame.finish()
}

impl Wrap {
    // `signer` is the writing device's DSK for `account` and `trust`, else the wrapper's ASK at `wrapper.av`.
    pub fn seal(
        origin: &Origin,
        target: WrapTarget,
        pk_r: &X25519Public,
        plaintext: &[u8],
        wrapper: Wrapper,
        signer: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        target.check_form()?;
        let info = wrap_info(origin, target, pk_r)?;
        let (enc, ct) = crypto::hpke_seal(&pk_r.0, &info, plaintext)?;
        let sig = signer.sign(&wrap_sig_message(&info, &enc, &ct, wrapper)?)?;
        Ok(Self {
            target,
            enc,
            ct,
            wrapper,
            sig,
        })
    }

    pub fn seal_account(
        origin: &Origin,
        target: WrapTarget,
        dek: &X25519Public,
        keys: &AccountKeys,
        wrapper: Wrapper,
        dsk: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        require_purpose(target, WrapPurpose::Account)?;
        Self::seal(origin, target, dek, keys.to_plaintext().as_slice(), wrapper, dsk)
    }

    pub fn seal_trust(
        origin: &Origin,
        target: WrapTarget,
        dek: &X25519Public,
        trust: &TrustPlaintext,
        wrapper: Wrapper,
        dsk: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        require_purpose(target, WrapPurpose::Trust)?;
        let padded = crate::padding::pad(trust.encode().as_bytes())?;
        Self::seal(origin, target, dek, &padded, wrapper, dsk)
    }

    pub fn seal_scope_key(
        origin: &Origin,
        target: WrapTarget,
        aek: &X25519Public,
        key: &ScopeKey,
        wrapper: Wrapper,
        ask: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        if !matches!(target.purpose, WrapPurpose::Key(_)) {
            return Err(KeysError::encoding("not a scope key wrap"));
        }
        Self::seal(origin, target, aek, key.expose(), wrapper, ask)
    }

    pub fn info(&self, origin: &Origin, pk_r: &X25519Public) -> Result<Vec<u8>, KeysError> {
        wrap_info(origin, self.target, pk_r)
    }

    // The signature over `info`, rebuilt with `pk_r` from the recipient's certificate at the
    // recipient version, and over `enc`, `ct` and the wrapper fields.
    pub fn verify(&self, origin: &Origin, pk_r: &X25519Public, signer: &Ed25519Public) -> Result<(), KeysError> {
        let info = self.info(origin, pk_r)?;
        signer.verify(&wrap_sig_message(&info, &self.enc, &self.ct, self.wrapper)?, &self.sig)
    }

    // The recipient's side. `certified` is the public key the recipient's certificate names at the
    // recipient version; a recipient whose own key differs gets keys.mismatch before anything opens.
    fn open_checked(
        &self,
        origin: &Origin,
        secret: &X25519Secret,
        certified: &X25519Public,
        signer: &Ed25519Public,
        signature_error: KeysError,
    ) -> Result<Zeroizing<Vec<u8>>, KeysError> {
        if secret.public()? != *certified {
            return Err(KeysError::Mismatch {
                what: "the wrap's pkR is not the recipient's certified key",
            });
        }
        let info = self.info(origin, certified)?;
        signer
            .verify(&wrap_sig_message(&info, &self.enc, &self.ct, self.wrapper)?, &self.sig)
            .map_err(|_| signature_error)?;
        crypto::hpke_open(secret.expose(), &self.enc, &info, &self.ct)
    }

    // An `account` wrap: signed by the DSK this device compared, holding the keys `certificate` names.
    pub fn open_account(
        &self,
        origin: &Origin,
        dek: &X25519Secret,
        certified_dek: &X25519Public,
        compared_dsk: &Ed25519Public,
        certificate: &AccountPublicKeys,
    ) -> Result<AccountKeys, KeysError> {
        require_purpose(self.target, WrapPurpose::Account)?;
        let plaintext = self.open_checked(origin, dek, certified_dek, compared_dsk, KeysError::NotCompared)?;
        let keys = AccountKeys::from_plaintext(&plaintext)?;
        keys.check_against(&certificate.ask, &certificate.aek)?;
        Ok(keys)
    }

    pub fn open_trust(
        &self,
        origin: &Origin,
        dek: &X25519Secret,
        certified_dek: &X25519Public,
        compared_dsk: &Ed25519Public,
    ) -> Result<TrustPlaintext, KeysError> {
        require_purpose(self.target, WrapPurpose::Trust)?;
        let padded = self.open_checked(origin, dek, certified_dek, compared_dsk, KeysError::NotCompared)?;
        TrustPlaintext::parse(crate::padding::unpad(&padded)?)
    }

    // A scope key: signed by the wrapper's ASK at `wrapper.av`, checked against its version record's kid.
    pub fn open_scope_key(
        &self,
        origin: &Origin,
        aek: &X25519Secret,
        certified_aek: &X25519Public,
        wrapper_ask: &Ed25519Public,
        record: &VersionRecord,
    ) -> Result<ScopeKey, KeysError> {
        let WrapPurpose::Key(purpose) = self.target.purpose else {
            return Err(KeysError::encoding("not a scope key wrap"));
        };
        let wraps = KeyRef {
            owner: self.target.owner,
            purpose,
            version: self.target.version,
        };
        if record.key != wraps {
            return Err(KeysError::encoding("the version record is not the wrapped version's"));
        }
        let plaintext = self.open_checked(origin, aek, certified_aek, wrapper_ask, KeysError::Signature)?;
        let bytes = <[u8; 32]>::try_from(plaintext.as_slice()).map_err(|_| KeysError::encoding("scope key length"))?;
        let key = ScopeKey::from_bytes(bytes);
        record.check_key(&key)?;
        Ok(key)
    }
}

fn require_purpose(target: WrapTarget, purpose: WrapPurpose) -> Result<(), KeysError> {
    if target.purpose == purpose {
        Ok(())
    } else {
        Err(KeysError::encoding("wrong wrap purpose"))
    }
}

pub fn scope_key_target(key: KeyRef, recipient: AccountId, recipient_av: Version) -> WrapTarget {
    WrapTarget {
        owner: key.owner,
        purpose: WrapPurpose::Key(key.purpose),
        version: key.version,
        recipient: Recipient::Account(recipient),
        recipient_version: recipient_av,
    }
}

pub fn device_target(account: AccountId, purpose: WrapPurpose, av: Version, key_device: KeyDeviceId) -> WrapTarget {
    WrapTarget {
        owner: account.0,
        purpose,
        version: av,
        recipient: Recipient::Device(key_device),
        recipient_version: av,
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{Wrap, Wrapper, device_target, scope_key_target};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, Version, WrapPurpose};
    use crate::keys::{AccountKeys, DeviceKeys, ScopeKey, X25519Secret};
    use crate::scope_key::{KeyRef, Start, VersionRecord};

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    #[test]
    fn an_account_wrap_opens_only_under_the_compared_dsk_and_certified_dek() {
        let account = AccountId(Uuid::from_u128(1));
        let av = Version::new(2).unwrap();
        let keys = AccountKeys::generate().unwrap();
        let approver = DeviceKeys::generate().unwrap();
        let new_device = DeviceKeys::generate().unwrap();
        let wrapper = Wrapper {
            account,
            av,
            key_device: approver.key_device,
        };
        let target = device_target(account, WrapPurpose::Account, av, new_device.key_device);
        let dek = new_device.dek.public().unwrap();
        let wrap = Wrap::seal_account(&origin(), target, &dek, &keys, wrapper, &approver.dsk).unwrap();
        let public = keys.public().unwrap();

        let opened = wrap
            .open_account(
                &origin(),
                &new_device.dek,
                &dek,
                &approver.dsk.public().unwrap(),
                &public,
            )
            .unwrap();
        assert_eq!(opened.ask.expose(), keys.ask.expose());

        let other_dsk = DeviceKeys::generate().unwrap().dsk.public().unwrap();
        assert_eq!(
            wrap.open_account(&origin(), &new_device.dek, &dek, &other_dsk, &public)
                .unwrap_err(),
            KeysError::NotCompared
        );

        let other_dek = X25519Secret::generate().unwrap().public().unwrap();
        assert!(matches!(
            wrap.open_account(
                &origin(),
                &new_device.dek,
                &other_dek,
                &approver.dsk.public().unwrap(),
                &public
            ),
            Err(KeysError::Mismatch { .. })
        ));

        let other_keys = AccountKeys::generate().unwrap().public().unwrap();
        assert!(matches!(
            wrap.open_account(
                &origin(),
                &new_device.dek,
                &dek,
                &approver.dsk.public().unwrap(),
                &other_keys
            ),
            Err(KeysError::Mismatch { .. })
        ));
    }

    #[test]
    fn a_scope_key_wrap_checks_the_signature_and_the_kid() {
        let team = Uuid::from_u128(5);
        let admin = AccountId(Uuid::from_u128(1));
        let member = AccountId(Uuid::from_u128(2));
        let admin_keys = AccountKeys::generate().unwrap();
        let member_keys = AccountKeys::generate().unwrap();
        let av = Version::FIRST;
        let tk = ScopeKey::generate().unwrap();
        let key = KeyRef {
            owner: team,
            purpose: KeyPurpose::Team,
            version: Version::FIRST,
        };
        let record = VersionRecord::sign(&origin(), key, Start::Over, &tk, admin, av, &admin_keys.ask).unwrap();
        let wrapper = Wrapper {
            account: admin,
            av,
            key_device: KeyDeviceId(Uuid::from_u128(9)),
        };
        let aek = member_keys.aek.public().unwrap();
        let wrap = Wrap::seal_scope_key(
            &origin(),
            scope_key_target(key, member, av),
            &aek,
            &tk,
            wrapper,
            &admin_keys.ask,
        )
        .unwrap();
        let admin_ask = admin_keys.ask.public().unwrap();

        assert_eq!(wrap.verify(&origin(), &aek, &admin_ask), Ok(()));
        let opened = wrap
            .open_scope_key(&origin(), &member_keys.aek, &aek, &admin_ask, &record)
            .unwrap();
        assert_eq!(opened.expose(), tk.expose());

        let other = ScopeKey::generate().unwrap();
        let other_record =
            VersionRecord::sign(&origin(), key, Start::Over, &other, admin, av, &admin_keys.ask).unwrap();
        assert_eq!(
            wrap.open_scope_key(&origin(), &member_keys.aek, &aek, &admin_ask, &other_record)
                .unwrap_err(),
            KeysError::Kid
        );

        let mut tampered = wrap.clone();
        tampered.wrapper.av = Version::new(2).unwrap();
        assert_eq!(tampered.verify(&origin(), &aek, &admin_ask), Err(KeysError::Signature));
    }
}
