use uuid::Uuid;

use crate::KeysError;
use crate::encoding::{
    AccountId, KeyDeviceId, KeyPurpose, RequestId, ResetId, Version, WrapPurpose, uuid_from_wire, uuid_to_wire,
};
use crate::scope_key::KeyRef;
use crate::wrap::{Recipient, WrapTarget};

// ADR 0051, Kinds: valid UTF-8 without U+0000, 1 to 255 UTF-16 code units.
pub fn check_record_id(id: &str) -> Result<(), KeysError> {
    // Counting stops past the limit, so a long id costs no more than a short one.
    let units = id.encode_utf16().take(256).count();
    if units == 0 || units > 255 || id.contains('\0') {
        return Err(KeysError::encoding("record id is empty, too long or holds U+0000"));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyKind {
    Account,
    Device,
    Recovery,
    Reset,
    Cancel,
    Request,
    Sas,
    Version,
    Wrap,
    Ring,
    Member,
}

impl KeyKind {
    pub const ALL: [Self; 11] = [
        Self::Account,
        Self::Device,
        Self::Recovery,
        Self::Reset,
        Self::Cancel,
        Self::Request,
        Self::Sas,
        Self::Version,
        Self::Wrap,
        Self::Ring,
        Self::Member,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Self::Account => "key.account",
            Self::Device => "key.device",
            Self::Recovery => "key.recovery",
            Self::Reset => "key.reset",
            Self::Cancel => "key.cancel",
            Self::Request => "key.request",
            Self::Sas => "key.sas",
            Self::Version => "key.version",
            Self::Wrap => "key.wrap",
            Self::Ring => "key.ring",
            Self::Member => "key.member",
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        Self::ALL
            .into_iter()
            .find(|kind| kind.name() == text)
            .ok_or(KeysError::encoding("not a key kind"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SasStep {
    Nonce,
    Reveal,
    Cancel,
}

impl SasStep {
    pub fn name(self) -> &'static str {
        match self {
            Self::Nonce => "nonce",
            Self::Reveal => "reveal",
            Self::Cancel => "cancel",
        }
    }

    fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "nonce" => Ok(Self::Nonce),
            "reveal" => Ok(Self::Reveal),
            "cancel" => Ok(Self::Cancel),
            _ => Err(KeysError::encoding("not a session step")),
        }
    }
}

// A key object's record id (ADR 0052, Key objects): its parts joined by `/`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyRecordId {
    Account {
        account: AccountId,
        av: Version,
    },
    Device {
        account: AccountId,
        key_device: KeyDeviceId,
        av: Version,
    },
    Recovery {
        account: AccountId,
        av: Version,
    },
    Reset {
        account: AccountId,
        reset: ResetId,
    },
    Cancel {
        account: AccountId,
        reset: ResetId,
    },
    Request {
        request: RequestId,
    },
    Sas {
        request: RequestId,
        step: SasStep,
    },
    Version(KeyRef),
    Wrap(WrapTarget),
    Ring(KeyRef),
    Member {
        account: AccountId,
        av: Version,
    },
}

// A decimal version with no leading zero.
fn parse_version(part: &str) -> Result<Version, KeysError> {
    let well_formed = !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()) && !part.starts_with('0');
    if !well_formed {
        return Err(KeysError::encoding(
            "version part is not decimal without a leading zero",
        ));
    }
    part.parse::<u32>()
        .map_err(|_| KeysError::encoding("version out of 1 to 2^31-1"))
        .and_then(Version::new)
}

fn parse_key_ref(owner: &str, purpose: &str, version: &str) -> Result<KeyRef, KeysError> {
    Ok(KeyRef {
        owner: uuid_from_wire(owner)?,
        purpose: KeyPurpose::parse(purpose)?,
        version: parse_version(version)?,
    })
}

impl KeyRecordId {
    pub fn kind(&self) -> KeyKind {
        match self {
            Self::Account { .. } => KeyKind::Account,
            Self::Device { .. } => KeyKind::Device,
            Self::Recovery { .. } => KeyKind::Recovery,
            Self::Reset { .. } => KeyKind::Reset,
            Self::Cancel { .. } => KeyKind::Cancel,
            Self::Request { .. } => KeyKind::Request,
            Self::Sas { .. } => KeyKind::Sas,
            Self::Version(_) => KeyKind::Version,
            Self::Wrap(_) => KeyKind::Wrap,
            Self::Ring(_) => KeyKind::Ring,
            Self::Member { .. } => KeyKind::Member,
        }
    }

    pub fn parse(kind: KeyKind, id: &str) -> Result<Self, KeysError> {
        check_record_id(id)?;
        let parts: Vec<&str> = id.split('/').collect();
        let account = |part: &str| uuid_from_wire(part).map(AccountId);
        let parsed = match (kind, parts.as_slice()) {
            (KeyKind::Account, [owner, av]) => Self::Account {
                account: account(owner)?,
                av: parse_version(av)?,
            },
            (KeyKind::Device, [owner, device, av]) => Self::Device {
                account: account(owner)?,
                key_device: KeyDeviceId(uuid_from_wire(device)?),
                av: parse_version(av)?,
            },
            (KeyKind::Recovery, [owner, av]) => Self::Recovery {
                account: account(owner)?,
                av: parse_version(av)?,
            },
            (KeyKind::Reset, [owner, reset]) => Self::Reset {
                account: account(owner)?,
                reset: ResetId(uuid_from_wire(reset)?),
            },
            (KeyKind::Cancel, [owner, reset]) => Self::Cancel {
                account: account(owner)?,
                reset: ResetId(uuid_from_wire(reset)?),
            },
            (KeyKind::Request, [request]) => Self::Request {
                request: RequestId(uuid_from_wire(request)?),
            },
            (KeyKind::Sas, [request, step]) => Self::Sas {
                request: RequestId(uuid_from_wire(request)?),
                step: SasStep::parse(step)?,
            },
            (KeyKind::Version, [owner, purpose, version]) => Self::Version(parse_key_ref(owner, purpose, version)?),
            (KeyKind::Ring, [owner, purpose, version]) => Self::Ring(parse_key_ref(owner, purpose, version)?),
            (KeyKind::Wrap, [owner, purpose, version, recipient_type, recipient, recipient_version]) => {
                let recipient = match *recipient_type {
                    "device" => Recipient::Device(KeyDeviceId(uuid_from_wire(recipient)?)),
                    "account" => Recipient::Account(AccountId(uuid_from_wire(recipient)?)),
                    _ => return Err(KeysError::encoding("unknown recipient type")),
                };
                let target = WrapTarget {
                    owner: uuid_from_wire(owner)?,
                    purpose: WrapPurpose::parse(purpose)?,
                    version: parse_version(version)?,
                    recipient,
                    recipient_version: parse_version(recipient_version)?,
                };
                target.check_form()?;
                Self::Wrap(target)
            }
            (KeyKind::Member, [owner, av]) => Self::Member {
                account: account(owner)?,
                av: parse_version(av)?,
            },
            _ => return Err(KeysError::encoding("record id does not have its kind's parts")),
        };
        Ok(parsed)
    }

    pub fn to_wire(&self) -> String {
        let key_ref = |key: &KeyRef| format!("{}/{}/{}", uuid_to_wire(key.owner), key.purpose.name(), key.version);
        match self {
            Self::Account { account, av } | Self::Recovery { account, av } | Self::Member { account, av } => {
                format!("{}/{av}", account.to_wire())
            }
            Self::Device {
                account,
                key_device,
                av,
            } => format!("{}/{}/{av}", account.to_wire(), key_device.to_wire()),
            Self::Reset { account, reset } | Self::Cancel { account, reset } => {
                format!("{}/{}", account.to_wire(), reset.to_wire())
            }
            Self::Request { request } => request.to_wire(),
            Self::Sas { request, step } => format!("{}/{}", request.to_wire(), step.name()),
            Self::Version(key) | Self::Ring(key) => key_ref(key),
            Self::Wrap(target) => format!(
                "{}/{}/{}/{}/{}/{}",
                uuid_to_wire(target.owner),
                target.purpose.name(),
                target.version,
                target.recipient.type_name(),
                uuid_to_wire(target.recipient.id()),
                target.recipient_version
            ),
        }
    }

    // The account the id binds the writer to, where the id names one (ADR 0052; ADR 0051, Writer binding).
    pub fn bound_account(&self) -> Option<Uuid> {
        match self {
            Self::Account { account, .. }
            | Self::Device { account, .. }
            | Self::Recovery { account, .. }
            | Self::Reset { account, .. }
            | Self::Cancel { account, .. }
            | Self::Member { account, .. } => Some(account.0),
            Self::Version(key) | Self::Ring(key) => (key.purpose != KeyPurpose::Team).then_some(key.owner),
            Self::Wrap(target) => (target.purpose != WrapPurpose::Key(KeyPurpose::Team)).then_some(target.owner),
            Self::Request { .. } | Self::Sas { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{KeyKind, KeyRecordId, check_record_id};

    const EXAMPLES: [(KeyKind, &str); 13] = [
        (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/1"),
        (
            KeyKind::Device,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
        ),
        (KeyKind::Recovery, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/4"),
        (
            KeyKind::Reset,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78",
        ),
        (
            KeyKind::Cancel,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/8A41C3E2-5B6D-4F7A-9C10-2E3D4B5A6F78",
        ),
        (KeyKind::Request, "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357"),
        (KeyKind::Sas, "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357/nonce"),
        (KeyKind::Version, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/history/2"),
        (KeyKind::Version, "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5"),
        (
            KeyKind::Wrap,
            "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/account/4/device/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
        ),
        (
            KeyKind::Wrap,
            "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5/account/019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2",
        ),
        (KeyKind::Ring, "019A6B30-1D27-7E9A-8C44-2F5B7A1E0C63/team/5"),
        (KeyKind::Member, "019A6B31-4C8D-7F02-9A16-3E7D5B2C8F90/2"),
    ];

    #[test]
    fn adr_0052_examples_round_trip() {
        for (kind, id) in EXAMPLES {
            let parsed = KeyRecordId::parse(kind, id).unwrap();
            assert_eq!(parsed.kind(), kind);
            assert_eq!(parsed.to_wire(), id);
        }
    }

    #[test]
    fn malformed_ids_are_refused() {
        for (kind, id) in [
            (KeyKind::Account, "019a6b2e-8f3c-7d41-b2a5-6c0e9f14d7b8/1"),
            (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/01"),
            (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/0"),
            (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/2147483648"),
            (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/+1"),
            (KeyKind::Account, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/1/"),
            (KeyKind::Sas, "5E2C8B14-7A3D-4F61-9B08-C4D2E6F1A357/approve"),
            (KeyKind::Version, "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/account/2"),
            (
                KeyKind::Wrap,
                "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/account/4/device/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/5",
            ),
            (
                KeyKind::Wrap,
                "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/team/4/device/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
            ),
            (
                KeyKind::Wrap,
                "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/trust/4/account/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4",
            ),
        ] {
            assert!(KeyRecordId::parse(kind, id).is_err(), "{id}");
        }
        assert!(check_record_id("").is_err());
        assert!(check_record_id("a\0b").is_err());
        assert!(check_record_id(&"x".repeat(256)).is_err());
        assert!(check_record_id(&"x".repeat(255)).is_ok());
        assert!(check_record_id(&"\u{1F600}".repeat(127)).is_ok(), "254 UTF-16 units");
        assert!(check_record_id(&"\u{1F600}".repeat(128)).is_err(), "256 UTF-16 units");
    }

    proptest! {
        #[test]
        fn whatever_parses_writes_back_the_same_id(kind in 0..11_usize, id in "[0-9A-Fa-z/-]{0,120}") {
            if let Ok(parsed) = KeyRecordId::parse(KeyKind::ALL[kind], &id) {
                prop_assert_eq!(parsed.to_wire(), id);
            }
        }
    }
}
