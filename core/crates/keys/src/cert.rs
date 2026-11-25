use crate::KeysError;
use crate::encoding::{AccountId, Frame, KeyDeviceId, Label, Origin, Version};
use crate::keys::{AccountPublicKeys, Ed25519Public, Ed25519Seed, Signature, X25519Public};

// An account certificate's `kind` (ADR 0056, Signed objects and wraps).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CertKind {
    GenesisOrRotation,
    Replace,
    ResetKeepingKeys,
    ResetEmpty,
}

impl CertKind {
    pub fn code(self) -> u8 {
        match self {
            Self::GenesisOrRotation => 0,
            Self::Replace => 1,
            Self::ResetKeepingKeys => 2,
            Self::ResetEmpty => 3,
        }
    }

    pub fn from_code(code: i64) -> Result<Self, KeysError> {
        match code {
            0 => Ok(Self::GenesisOrRotation),
            1 => Ok(Self::Replace),
            2 => Ok(Self::ResetKeepingKeys),
            3 => Ok(Self::ResetEmpty),
            _ => Err(KeysError::encoding("certificate kind out of 0 to 3")),
        }
    }
}

// What an account certificate signs. `key.account` and `key.member` carry it; the account and
// `av` come from the record id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountCertificate {
    pub account: AccountId,
    pub av: Version,
    pub kind: CertKind,
    pub ik: Ed25519Public,
    pub ask: Ed25519Public,
    pub aek: X25519Public,
    pub sig: Signature,
    // The old IK's endorsement, with kind 1 only.
    pub replace_sig: Option<Signature>,
}

pub fn account_message(
    origin: &Origin,
    account: AccountId,
    av: Version,
    ik: &Ed25519Public,
    ask: &Ed25519Public,
    aek: &X25519Public,
    kind: CertKind,
) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Account);
    frame
        .origin(origin)
        .id(account.0)
        .u32(av.get())
        .lp(&ik.0)
        .lp(&ask.0)
        .lp(&aek.0)
        .u8(kind.code());
    frame.finish()
}

pub fn replace_message(
    origin: &Origin,
    account: AccountId,
    av: Version,
    new_ik: &Ed25519Public,
) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Replace);
    frame.origin(origin).id(account.0).u32(av.get()).lp(&new_ik.0);
    frame.finish()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IkChange {
    Same,
    // A new IK the old one endorsed: followed with a notice.
    Endorsed,
}

impl AccountCertificate {
    // `ik` signs a certificate naming itself. With kind 1, `previous_ik` (the IK of the certificate
    // at `av - 1`) also endorses it.
    pub fn sign(
        origin: &Origin,
        account: AccountId,
        av: Version,
        kind: CertKind,
        ik: &Ed25519Seed,
        public: AccountPublicKeys,
        previous_ik: Option<&Ed25519Seed>,
    ) -> Result<Self, KeysError> {
        let AccountPublicKeys { ask, aek } = public;
        let ik_public = ik.public()?;
        let sig = ik.sign(&account_message(origin, account, av, &ik_public, &ask, &aek, kind)?)?;
        let replace_sig = match (kind, previous_ik) {
            (CertKind::Replace, Some(previous)) => {
                Some(previous.sign(&replace_message(origin, account, av, &ik_public)?)?)
            }
            (CertKind::Replace, None) => return Err(KeysError::Unendorsed),
            (_, _) => None,
        };
        Ok(Self {
            account,
            av,
            kind,
            ik: ik_public,
            ask,
            aek,
            sig,
            replace_sig,
        })
    }

    pub fn message(&self, origin: &Origin) -> Result<Vec<u8>, KeysError> {
        account_message(origin, self.account, self.av, &self.ik, &self.ask, &self.aek, self.kind)
    }

    // The signature under the IK the certificate names. Whether that IK is the pinned one, or one
    // it endorsed, is `ik_change`.
    pub fn verify(&self, origin: &Origin) -> Result<(), KeysError> {
        self.ik.verify(&self.message(origin)?, &self.sig)
    }

    // Verifies the certificate, then its IK against the IK the client holds for this account.
    pub fn ik_change(&self, origin: &Origin, previous_ik: &Ed25519Public) -> Result<IkChange, KeysError> {
        self.verify(origin)?;
        if self.ik == *previous_ik {
            return Ok(IkChange::Same);
        }
        let endorsed = self.kind == CertKind::Replace
            && self.replace_sig.as_ref().is_some_and(|sig| {
                replace_message(origin, self.account, self.av, &self.ik)
                    .is_ok_and(|message| previous_ik.verify(&message, sig).is_ok())
            });
        if endorsed {
            Ok(IkChange::Endorsed)
        } else {
            Err(KeysError::Unendorsed)
        }
    }
}

// A device certificate, one per (key device, `av`), signed by ASK at `av`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceCertificate {
    pub account: AccountId,
    pub key_device: KeyDeviceId,
    pub av: Version,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
    pub sig: Signature,
}

pub fn device_message(
    origin: &Origin,
    account: AccountId,
    av: Version,
    key_device: KeyDeviceId,
    dek: &X25519Public,
    dsk: &Ed25519Public,
) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Device);
    frame
        .origin(origin)
        .id(account.0)
        .u32(av.get())
        .id(key_device.0)
        .lp(&dek.0)
        .lp(&dsk.0);
    frame.finish()
}

impl DeviceCertificate {
    pub fn sign(
        origin: &Origin,
        account: AccountId,
        av: Version,
        key_device: KeyDeviceId,
        dek: X25519Public,
        dsk: Ed25519Public,
        ask: &Ed25519Seed,
    ) -> Result<Self, KeysError> {
        let sig = ask.sign(&device_message(origin, account, av, key_device, &dek, &dsk)?)?;
        Ok(Self {
            account,
            key_device,
            av,
            dek,
            dsk,
            sig,
        })
    }

    // `ask` is the ASK the account certificate at `av` names.
    pub fn verify(&self, origin: &Origin, ask: &Ed25519Public) -> Result<(), KeysError> {
        ask.verify(
            &device_message(origin, self.account, self.av, self.key_device, &self.dek, &self.dsk)?,
            &self.sig,
        )
    }
}

// Cancelling a reset with the recovery key: IK signs the reset's `av` (the current plus one) and
// the IK it proposes, so a cancel never applies to another attempt.
pub fn cancel_message(
    origin: &Origin,
    account: AccountId,
    reset_av: Version,
    proposed_ik: &Ed25519Public,
) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::new(Label::Cancel);
    frame
        .origin(origin)
        .id(account.0)
        .u32(reset_av.get())
        .lp(&proposed_ik.0);
    frame.finish()
}

pub fn sign_cancel(
    origin: &Origin,
    account: AccountId,
    reset_av: Version,
    proposed_ik: &Ed25519Public,
    ik: &Ed25519Seed,
) -> Result<Signature, KeysError> {
    ik.sign(&cancel_message(origin, account, reset_av, proposed_ik)?)
}

pub fn verify_cancel(
    origin: &Origin,
    account: AccountId,
    reset_av: Version,
    proposed_ik: &Ed25519Public,
    sig: &Signature,
    ik: &Ed25519Public,
) -> Result<(), KeysError> {
    ik.verify(&cancel_message(origin, account, reset_av, proposed_ik)?, sig)
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{AccountCertificate, CertKind, DeviceCertificate, IkChange, sign_cancel, verify_cancel};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyDeviceId, Origin, Version};
    use crate::keys::{AccountKeys, Ed25519Seed, X25519Secret};

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    fn cert(ik: &Ed25519Seed, av: u32, kind: CertKind, previous: Option<&Ed25519Seed>) -> AccountCertificate {
        let keys = AccountKeys::generate().unwrap();
        AccountCertificate::sign(
            &origin(),
            AccountId(Uuid::from_u128(1)),
            Version::new(av).unwrap(),
            kind,
            ik,
            keys.public().unwrap(),
            previous,
        )
        .unwrap()
    }

    #[test]
    fn a_rotation_keeps_the_ik_and_a_replace_is_endorsed() {
        let ik = Ed25519Seed::generate().unwrap();
        let rotation = cert(&ik, 2, CertKind::GenesisOrRotation, None);
        assert_eq!(rotation.ik_change(&origin(), &ik.public().unwrap()), Ok(IkChange::Same));

        let new_ik = Ed25519Seed::generate().unwrap();
        let replace = cert(&new_ik, 3, CertKind::Replace, Some(&ik));
        assert_eq!(
            replace.ik_change(&origin(), &ik.public().unwrap()),
            Ok(IkChange::Endorsed)
        );

        let reset = cert(&new_ik, 3, CertKind::ResetKeepingKeys, None);
        assert_eq!(
            reset.ik_change(&origin(), &ik.public().unwrap()),
            Err(KeysError::Unendorsed)
        );

        let mut forged = replace.clone();
        forged.replace_sig = Some(new_ik.sign(b"x").unwrap());
        assert_eq!(
            forged.ik_change(&origin(), &ik.public().unwrap()),
            Err(KeysError::Unendorsed)
        );
    }

    #[test]
    fn a_certificate_under_another_ik_fails() {
        let ik = Ed25519Seed::generate().unwrap();
        let mut certificate = cert(&ik, 1, CertKind::GenesisOrRotation, None);
        certificate.ik = Ed25519Seed::generate().unwrap().public().unwrap();
        assert_eq!(certificate.verify(&origin()), Err(KeysError::Signature));
    }

    #[test]
    fn device_certificates_and_cancels_verify() {
        let ask = Ed25519Seed::generate().unwrap();
        let account = AccountId(Uuid::from_u128(1));
        let av = Version::new(4).unwrap();
        let device = DeviceCertificate::sign(
            &origin(),
            account,
            av,
            KeyDeviceId(Uuid::from_u128(9)),
            X25519Secret::generate().unwrap().public().unwrap(),
            Ed25519Seed::generate().unwrap().public().unwrap(),
            &ask,
        )
        .unwrap();
        assert_eq!(device.verify(&origin(), &ask.public().unwrap()), Ok(()));
        let mut other = device.clone();
        other.av = Version::new(5).unwrap();
        assert_eq!(
            other.verify(&origin(), &ask.public().unwrap()),
            Err(KeysError::Signature)
        );

        let ik = Ed25519Seed::generate().unwrap();
        let proposed = Ed25519Seed::generate().unwrap().public().unwrap();
        let sig = sign_cancel(&origin(), account, av, &proposed, &ik).unwrap();
        assert_eq!(
            verify_cancel(&origin(), account, av, &proposed, &sig, &ik.public().unwrap()),
            Ok(())
        );
        let later = Ed25519Seed::generate().unwrap().public().unwrap();
        assert_eq!(
            verify_cancel(&origin(), account, av, &later, &sig, &ik.public().unwrap()),
            Err(KeysError::Signature)
        );
    }
}
