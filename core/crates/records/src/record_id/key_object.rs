// 0052, Key objects: parts joined by `/`. A part is an upper-case UUID, a decimal version from 1 to 2^31-1 with no
// leading zero, or a name of lower-case ASCII letters, digits and `-` starting with a letter.

use std::fmt;

use uuid::Uuid;

use super::{parse_uuid, uuid_id};
use crate::kind::{Kind, Scope};

const MAX_VERSION: u32 = (1 << 31) - 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyPurpose {
    Account,
    Trust,
    Personal,
    History,
    Team,
}

impl KeyPurpose {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Account => "account",
            Self::Trust => "trust",
            Self::Personal => "personal",
            Self::History => "history",
            Self::Team => "team",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        [Self::Account, Self::Trust, Self::Personal, Self::History, Self::Team]
            .into_iter()
            .find(|purpose| purpose.as_str() == text)
    }

    // The scope a version, wrap or ring of this purpose lives in: personal and history keys in the personal scope.
    pub const fn scope(self) -> Scope {
        match self {
            Self::Team => Scope::Team,
            _ => Scope::Personal,
        }
    }

    const fn is_scope_key(self) -> bool {
        matches!(self, Self::Personal | Self::History | Self::Team)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Recipient {
    // A key device, at the account version the wrap names.
    Device { key_device: Uuid, av: u32 },
    Account { account: Uuid, av: u32 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SasStep {
    Nonce,
    Reveal,
    Cancel,
}

impl SasStep {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Nonce => "nonce",
            Self::Reveal => "reveal",
            Self::Cancel => "cancel",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyObjectId {
    Account {
        account: Uuid,
        av: u32,
    },
    Device {
        account: Uuid,
        key_device: Uuid,
        av: u32,
    },
    Recovery {
        account: Uuid,
        av: u32,
    },
    Reset {
        account: Uuid,
        reset: Uuid,
    },
    Cancel {
        account: Uuid,
        reset: Uuid,
    },
    Request {
        request: Uuid,
    },
    Sas {
        request: Uuid,
        step: SasStep,
    },
    Version {
        owner: Uuid,
        purpose: KeyPurpose,
        version: u32,
    },
    Wrap {
        owner: Uuid,
        purpose: KeyPurpose,
        version: u32,
        recipient: Recipient,
    },
    Ring {
        owner: Uuid,
        purpose: KeyPurpose,
        version: u32,
    },
    Member {
        account: Uuid,
        av: u32,
    },
}

impl KeyObjectId {
    pub const fn kind(&self) -> Kind {
        match self {
            Self::Account { .. } => Kind::KeyAccount,
            Self::Device { .. } => Kind::KeyDevice,
            Self::Recovery { .. } => Kind::KeyRecovery,
            Self::Reset { .. } => Kind::KeyReset,
            Self::Cancel { .. } => Kind::KeyCancel,
            Self::Request { .. } => Kind::KeyRequest,
            Self::Sas { .. } => Kind::KeySas,
            Self::Version { .. } => Kind::KeyVersion,
            Self::Wrap { .. } => Kind::KeyWrap,
            Self::Ring { .. } => Kind::KeyRing,
            Self::Member { .. } => Kind::KeyMember,
        }
    }

    // The account whose caller alone may write the object, compared as bytes in upper case (0051, Writer binding).
    // Team versions, wraps and rings bind to their signer instead, which the id does not name.
    pub fn bound_account(&self) -> Option<Uuid> {
        match *self {
            Self::Account { account, .. }
            | Self::Device { account, .. }
            | Self::Recovery { account, .. }
            | Self::Reset { account, .. }
            | Self::Cancel { account, .. }
            | Self::Member { account, .. } => Some(account),
            Self::Version { owner, purpose, .. }
            | Self::Wrap { owner, purpose, .. }
            | Self::Ring { owner, purpose, .. }
                if purpose != KeyPurpose::Team =>
            {
                Some(owner)
            }
            _ => None,
        }
    }

    pub fn parse(kind: Kind, id: &str) -> Option<Self> {
        let parts: Vec<&str> = id.split('/').collect();
        let parsed = match (kind, parts.as_slice()) {
            (Kind::KeyAccount, [account, av]) => Self::Account {
                account: parse_uuid(account)?,
                av: version(av)?,
            },
            (Kind::KeyDevice, [account, key_device, av]) => Self::Device {
                account: parse_uuid(account)?,
                key_device: parse_uuid(key_device)?,
                av: version(av)?,
            },
            (Kind::KeyRecovery, [account, av]) => Self::Recovery {
                account: parse_uuid(account)?,
                av: version(av)?,
            },
            (Kind::KeyReset, [account, reset]) => Self::Reset {
                account: parse_uuid(account)?,
                reset: parse_uuid(reset)?,
            },
            (Kind::KeyCancel, [account, reset]) => Self::Cancel {
                account: parse_uuid(account)?,
                reset: parse_uuid(reset)?,
            },
            (Kind::KeyRequest, [request]) => Self::Request {
                request: parse_uuid(request)?,
            },
            (Kind::KeySas, [request, step]) => Self::Sas {
                request: parse_uuid(request)?,
                step: [SasStep::Nonce, SasStep::Reveal, SasStep::Cancel]
                    .into_iter()
                    .find(|known| known.as_str() == *step)?,
            },
            (Kind::KeyVersion, [owner, purpose, number]) => Self::Version {
                owner: parse_uuid(owner)?,
                purpose: Some(KeyPurpose::parse(purpose)?).filter(|purpose| purpose.is_scope_key())?,
                version: version(number)?,
            },
            (Kind::KeyRing, [owner, purpose, number]) => Self::Ring {
                owner: parse_uuid(owner)?,
                purpose: Some(KeyPurpose::parse(purpose)?).filter(|purpose| purpose.is_scope_key())?,
                version: version(number)?,
            },
            (Kind::KeyWrap, [owner, purpose, number, recipient_type, recipient, recipient_version]) => {
                let purpose = KeyPurpose::parse(purpose)?;
                let recipient_id = parse_uuid(recipient)?;
                let recipient_version = version(recipient_version)?;
                let recipient = match (purpose.is_scope_key(), *recipient_type) {
                    (false, "device") => Recipient::Device {
                        key_device: recipient_id,
                        av: recipient_version,
                    },
                    (true, "account") => Recipient::Account {
                        account: recipient_id,
                        av: recipient_version,
                    },
                    _ => return None,
                };
                Self::Wrap {
                    owner: parse_uuid(owner)?,
                    purpose,
                    version: version(number)?,
                    recipient,
                }
            }
            (Kind::KeyMember, [account, av]) => Self::Member {
                account: parse_uuid(account)?,
                av: version(av)?,
            },
            _ => return None,
        };
        // An `account` or `trust` wrap goes to a device at the very `av` it carries.
        if let Self::Wrap {
            purpose: KeyPurpose::Account | KeyPurpose::Trust,
            version,
            recipient: Recipient::Device { av, .. },
            ..
        } = parsed
            && version != av
        {
            return None;
        }
        Some(parsed)
    }
}

fn version(text: &str) -> Option<u32> {
    let well_formed = !text.is_empty() && !text.starts_with('0') && text.bytes().all(|b| b.is_ascii_digit());
    well_formed
        .then(|| text.parse::<u32>().ok())
        .flatten()
        .filter(|number| (1..=MAX_VERSION).contains(number))
}

impl fmt::Display for KeyObjectId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::Account { account, av } | Self::Recovery { account, av } | Self::Member { account, av } => {
                write!(f, "{}/{av}", uuid_id(account))
            }
            Self::Device {
                account,
                key_device,
                av,
            } => {
                write!(f, "{}/{}/{av}", uuid_id(account), uuid_id(key_device))
            }
            Self::Reset { account, reset } | Self::Cancel { account, reset } => {
                write!(f, "{}/{}", uuid_id(account), uuid_id(reset))
            }
            Self::Request { request } => f.write_str(&uuid_id(request)),
            Self::Sas { request, step } => write!(f, "{}/{}", uuid_id(request), step.as_str()),
            Self::Version {
                owner,
                purpose,
                version,
            }
            | Self::Ring {
                owner,
                purpose,
                version,
            } => {
                write!(f, "{}/{}/{version}", uuid_id(owner), purpose.as_str())
            }
            Self::Wrap {
                owner,
                purpose,
                version,
                recipient,
            } => {
                let (kind, id, at) = match recipient {
                    Recipient::Device { key_device, av } => ("device", key_device, av),
                    Recipient::Account { account, av } => ("account", account, av),
                };
                write!(
                    f,
                    "{}/{}/{version}/{kind}/{}/{at}",
                    uuid_id(owner),
                    purpose.as_str(),
                    uuid_id(id)
                )
            }
        }
    }
}
