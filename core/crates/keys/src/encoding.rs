use std::fmt;

use uuid::Uuid;

use crate::KeysError;

pub const SUITE: &str = "tp1";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Label {
    RecoveryChecksum,
    Identity,
    RecoveryWrap,
    Recovery,
    Account,
    Replace,
    Cancel,
    Device,
    KeyId,
    Version,
    Wrap,
    WrapSig,
    RingKey,
    Ring,
    EnvelopeKey,
    Envelope,
    HistoryKey,
    History,
    SasCommit,
    Sas,
    Fingerprint,
    State,
}

impl Label {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::RecoveryChecksum => "tablepro/v1/recovery-checksum",
            Self::Identity => "tablepro/v1/identity",
            Self::RecoveryWrap => "tablepro/v1/recovery-wrap",
            Self::Recovery => "tablepro/v1/recovery",
            Self::Account => "tablepro/v1/account",
            Self::Replace => "tablepro/v1/replace",
            Self::Cancel => "tablepro/v1/cancel",
            Self::Device => "tablepro/v1/device",
            Self::KeyId => "tablepro/v1/key-id",
            Self::Version => "tablepro/v1/version",
            Self::Wrap => "tablepro/v1/wrap",
            Self::WrapSig => "tablepro/v1/wrap-sig",
            Self::RingKey => "tablepro/v1/ring-key",
            Self::Ring => "tablepro/v1/ring",
            Self::EnvelopeKey => "tablepro/v1/envelope-key",
            Self::Envelope => "tablepro/v1/envelope",
            Self::HistoryKey => "tablepro/v1/history-key",
            Self::History => "tablepro/v1/history",
            Self::SasCommit => "tablepro/v1/sas-commit",
            Self::Sas => "tablepro/v1/sas",
            Self::Fingerprint => "tablepro/v1/fingerprint",
            Self::State => "tablepro/v1/state",
        }
    }
}

pub fn lp(bytes: &[u8]) -> Result<Vec<u8>, KeysError> {
    let mut frame = Frame::empty();
    frame.lp(bytes);
    frame.finish()
}

// Builds the framed input of a signature, HKDF info, AAD or hash. A field past u32::MAX bytes
// poisons the frame instead of being cut, and finish refuses it.
pub(crate) struct Frame {
    bytes: Vec<u8>,
    overflow: bool,
}

impl Frame {
    pub(crate) fn empty() -> Self {
        Self {
            bytes: Vec::new(),
            overflow: false,
        }
    }

    pub(crate) fn new(label: Label) -> Self {
        let mut frame = Self::empty();
        frame.lp(label.as_str().as_bytes()).lp(SUITE.as_bytes());
        frame
    }

    pub(crate) fn lp(&mut self, bytes: &[u8]) -> &mut Self {
        match u32::try_from(bytes.len()) {
            Ok(len) => {
                self.bytes.extend_from_slice(&len.to_be_bytes());
                self.bytes.extend_from_slice(bytes);
            }
            Err(_) => self.overflow = true,
        }
        self
    }

    pub(crate) fn reserve(&mut self, additional: usize) {
        self.bytes.reserve_exact(additional);
    }

    pub(crate) fn u32(&mut self, value: u32) -> &mut Self {
        self.bytes.extend_from_slice(&value.to_be_bytes());
        self
    }

    pub(crate) fn u8(&mut self, value: u8) -> &mut Self {
        self.bytes.push(value);
        self
    }

    pub(crate) fn origin(&mut self, origin: &Origin) -> &mut Self {
        self.lp(origin.as_str().as_bytes())
    }

    pub(crate) fn id(&mut self, id: Uuid) -> &mut Self {
        self.lp(id.as_bytes())
    }

    pub(crate) fn scope(&mut self, scope: Scope) -> &mut Self {
        self.lp(scope.type_name().as_bytes()).id(scope.owner())
    }

    pub(crate) fn finish(self) -> Result<Vec<u8>, KeysError> {
        if self.overflow {
            return Err(KeysError::encoding("a framed field is longer than u32::MAX bytes"));
        }
        Ok(self.bytes)
    }
}

// The API origin's ASCII serialization (RFC 6454 section 6.2), as ADR 0047 compares it.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Origin(String);

impl Origin {
    // Text that is already an origin's serialization, such as `https://sync.example.com`.
    pub fn parse(text: &str) -> Result<Self, KeysError> {
        let origin = Self::of_url(text)?;
        if origin.0 != text {
            return Err(KeysError::encoding("origin is not in its ASCII serialization"));
        }
        Ok(origin)
    }

    // The origin of any URL: `https://sync.example.com:443/v2` gives `https://sync.example.com`.
    pub fn of_url(url: &str) -> Result<Self, KeysError> {
        let url = url::Url::parse(url).map_err(|_| KeysError::encoding("origin is not a URL"))?;
        let origin = url.origin();
        if !origin.is_tuple() {
            return Err(KeysError::encoding("origin is opaque"));
        }
        Ok(Self(origin.ascii_serialization()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for Origin {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

// A UUID in a record id or a JSON field: 8-4-4-4-12 upper-case hexadecimal digits (ADR 0052).
pub fn uuid_to_wire(id: Uuid) -> String {
    let mut buffer = Uuid::encode_buffer();
    id.hyphenated().encode_upper(&mut buffer).to_owned()
}

pub fn uuid_from_wire(text: &str) -> Result<Uuid, KeysError> {
    let bytes = text.as_bytes();
    let well_formed = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            8 | 13 | 18 | 23 => *byte == b'-',
            _ => byte.is_ascii_digit() || (b'A'..=b'F').contains(byte),
        });
    if !well_formed {
        return Err(KeysError::encoding("UUID is not upper-case 8-4-4-4-12 text"));
    }
    Uuid::parse_str(text).map_err(|_| KeysError::encoding("UUID is not upper-case 8-4-4-4-12 text"))
}

macro_rules! id_type {
    ($name:ident) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub struct $name(pub Uuid);

        impl $name {
            pub fn to_wire(self) -> String {
                uuid_to_wire(self.0)
            }

            pub fn from_wire(text: &str) -> Result<Self, KeysError> {
                uuid_from_wire(text).map(Self)
            }
        }
    };
}

id_type!(AccountId);
id_type!(TeamId);
id_type!(KeyDeviceId);
id_type!(RequestId);
id_type!(ResetId);
id_type!(HistoryId);

// Draws a random UUIDv4 from the system random source, as a key device, request, reset or history id.
pub fn random_uuid() -> Result<Uuid, KeysError> {
    let mut bytes = [0_u8; 16];
    crate::crypto::random(&mut bytes)?;
    Ok(uuid::Builder::from_random_bytes(bytes).into_uuid())
}

// A key version or `av`: 1 to 2^31-1, stepping by one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Version(u32);

impl Version {
    pub const FIRST: Self = Self(1);
    pub const MAX: u32 = (1 << 31) - 1;

    pub fn new(value: u32) -> Result<Self, KeysError> {
        if (1..=Self::MAX).contains(&value) {
            Ok(Self(value))
        } else {
            Err(KeysError::encoding("version out of 1 to 2^31-1"))
        }
    }

    pub fn from_i64(value: i64) -> Result<Self, KeysError> {
        u32::try_from(value)
            .map_err(|_| KeysError::encoding("version out of 1 to 2^31-1"))
            .and_then(Self::new)
    }

    pub fn get(self) -> u32 {
        self.0
    }

    pub fn next(self) -> Result<Self, KeysError> {
        Self::new(self.0 + 1)
    }

    pub fn previous(self) -> Option<Self> {
        Self::new(self.0 - 1).ok()
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

// `LP(type) || LP(owner)`. Every key object of the personal and history purposes lives in the
// personal scope; history entries name the history scope.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scope {
    Personal(AccountId),
    History(AccountId),
    Team(TeamId),
}

impl Scope {
    pub fn type_name(self) -> &'static str {
        match self {
            Self::Personal(_) => "personal",
            Self::History(_) => "history",
            Self::Team(_) => "team",
        }
    }

    pub fn owner(self) -> Uuid {
        match self {
            Self::Personal(account) | Self::History(account) => account.0,
            Self::Team(team) => team.0,
        }
    }

    pub fn bytes(self) -> Vec<u8> {
        let mut frame = Frame::empty();
        frame.scope(self);
        frame.bytes
    }
}

// The purpose of a scope key: its version records, rings and the wraps that carry it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum KeyPurpose {
    Personal,
    History,
    Team,
}

impl KeyPurpose {
    pub fn name(self) -> &'static str {
        match self {
            Self::Personal => "personal",
            Self::History => "history",
            Self::Team => "team",
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "personal" => Ok(Self::Personal),
            "history" => Ok(Self::History),
            "team" => Ok(Self::Team),
            _ => Err(KeysError::encoding("unknown key purpose")),
        }
    }

    // The scope a key object of this purpose lives in, from its owner.
    pub fn scope(self, owner: Uuid) -> Scope {
        match self {
            Self::Personal | Self::History => Scope::Personal(AccountId(owner)),
            Self::Team => Scope::Team(TeamId(owner)),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum WrapPurpose {
    Account,
    Trust,
    Key(KeyPurpose),
}

impl WrapPurpose {
    pub fn name(self) -> &'static str {
        match self {
            Self::Account => "account",
            Self::Trust => "trust",
            Self::Key(purpose) => purpose.name(),
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "account" => Ok(Self::Account),
            "trust" => Ok(Self::Trust),
            _ => KeyPurpose::parse(text).map(Self::Key),
        }
    }

    pub fn scope(self, owner: Uuid) -> Scope {
        match self {
            Self::Account | Self::Trust => Scope::Personal(AccountId(owner)),
            Self::Key(purpose) => purpose.scope(owner),
        }
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{Frame, Label, Origin, Scope, TeamId, Version, lp, uuid_from_wire, uuid_to_wire};

    #[test]
    fn lp_prefixes_a_big_endian_u32_length() {
        assert_eq!(lp(b"").unwrap(), vec![0, 0, 0, 0]);
        assert_eq!(lp(&[0, 0]).unwrap(), vec![0, 0, 0, 2, 0, 0]);
        let long = vec![7_u8; 65_536];
        assert_eq!(&lp(&long).unwrap()[..4], &[0, 1, 0, 0]);
    }

    #[test]
    fn a_frame_starts_with_its_label_and_the_suite() {
        let frame = Frame::new(Label::KeyId).finish().unwrap();
        let mut expected = lp(b"tablepro/v1/key-id").unwrap();
        expected.extend(lp(b"tp1").unwrap());
        assert_eq!(frame, expected);
    }

    #[test]
    fn origins_drop_the_default_port_and_the_path() {
        assert_eq!(
            Origin::of_url("https://Sync.Example.com:443/v2").unwrap().as_str(),
            "https://sync.example.com"
        );
        assert_eq!(
            Origin::of_url("https://sync.example.com:8443").unwrap().as_str(),
            "https://sync.example.com:8443"
        );
        assert!(Origin::parse("https://sync.example.com/").is_err());
        assert!(Origin::parse("https://sync.example.com").is_ok());
        assert!(Origin::of_url("file:///tmp/x").is_err());
    }

    #[test]
    fn uuids_are_upper_case_text_on_the_wire() {
        let id = Uuid::from_u128(0x019a_6b2e_8f3c_7d41_b2a5_6c0e_9f14_d7b8);
        assert_eq!(uuid_to_wire(id), "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8");
        assert_eq!(uuid_from_wire("019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8").unwrap(), id);
        assert!(uuid_from_wire("019a6b2e-8f3c-7d41-b2a5-6c0e9f14d7b8").is_err());
        assert!(uuid_from_wire("019A6B2E8F3C7D41B2A56C0E9F14D7B8").is_err());
        assert!(uuid_from_wire("{019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8}").is_err());
    }

    #[test]
    fn versions_run_from_one_to_two_to_the_31_minus_one() {
        assert!(Version::new(0).is_err());
        assert!(Version::new(1).is_ok());
        assert!(Version::new((1 << 31) - 1).is_ok());
        assert!(Version::new(1 << 31).is_err());
        assert!(Version::new((1 << 31) - 1).unwrap().next().is_err());
        assert_eq!(Version::FIRST.previous(), None);
    }

    #[test]
    fn a_scope_is_its_type_and_owner_framed() {
        let team = TeamId(Uuid::from_u128(1));
        let mut expected = lp(b"team").unwrap();
        expected.extend(lp(&Uuid::from_u128(1).into_bytes()).unwrap());
        assert_eq!(Scope::Team(team).bytes(), expected);
    }
}
