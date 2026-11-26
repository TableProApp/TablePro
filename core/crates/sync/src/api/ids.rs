use std::fmt;

use tablepro_keys::encoding::{AccountId, TeamId};
use tablepro_records::Kind;
use uuid::Uuid;

use super::error::SyncError;

// A scope as 0051 names it on the wire: `personal`, `history`, or the team's TypeID, `team_` and the team's UUID in
// lower-case Crockford base32.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ScopeName {
    Personal,
    History,
    Team(TeamId),
}

const TYPEID_ALPHABET: &[u8; 32] = b"0123456789abcdefghjkmnpqrstvwxyz";
const TEAM_PREFIX: &str = "team_";

impl ScopeName {
    pub fn wire(self) -> String {
        match self {
            Self::Personal => "personal".to_owned(),
            Self::History => "history".to_owned(),
            Self::Team(team) => format!("{TEAM_PREFIX}{}", typeid_suffix(team.0)),
        }
    }

    pub fn parse(text: &str) -> Result<Self, SyncError> {
        match text {
            "personal" => Ok(Self::Personal),
            "history" => Ok(Self::History),
            _ => text
                .strip_prefix(TEAM_PREFIX)
                .and_then(parse_typeid_suffix)
                .map(|uuid| Self::Team(TeamId(uuid)))
                .ok_or(SyncError::Malformed { what: "scope name" }),
        }
    }

    // 0051's scope type, which `tablepro_records` checks kinds against.
    pub fn records_scope(self) -> tablepro_records::Scope {
        match self {
            Self::Personal => tablepro_records::Scope::Personal,
            Self::History => tablepro_records::Scope::History,
            Self::Team(_) => tablepro_records::Scope::Team,
        }
    }

    // The key scope a record of this sync scope is sealed or signed in (0056, Encoding).
    pub fn key_scope(self, account: AccountId) -> tablepro_keys::encoding::Scope {
        match self {
            Self::Personal => tablepro_keys::encoding::Scope::Personal(account),
            Self::History => tablepro_keys::encoding::Scope::History(account),
            Self::Team(team) => tablepro_keys::encoding::Scope::Team(team),
        }
    }
}

impl fmt::Display for ScopeName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.wire())
    }
}

fn typeid_suffix(uuid: Uuid) -> String {
    let value = uuid.as_u128();
    (0..26)
        .rev()
        .map(|index| {
            let symbol = (value >> (index * 5)) & 0x1f;
            char::from(TYPEID_ALPHABET[usize::from(u8::try_from(symbol).unwrap_or(0))])
        })
        .collect()
}

// A TypeID suffix is 26 symbols whose first carries the two zero bits above 128.
fn parse_typeid_suffix(text: &str) -> Option<Uuid> {
    if text.len() != 26 || !text.starts_with(|c: char| ('0'..='7').contains(&c)) {
        return None;
    }
    let mut value: u128 = 0;
    for byte in text.bytes() {
        let symbol = TYPEID_ALPHABET.iter().position(|candidate| *candidate == byte)?;
        value = (value << 5) | u128::try_from(symbol).ok()?;
    }
    Some(Uuid::from_u128(value))
}

// Another server id as its TypeID, a prefix such as `acct_`, `epoch_` or `dev_` and the UUID's suffix (0051, Ids).
pub fn typeid(prefix: &str, uuid: Uuid) -> String {
    format!("{prefix}{}", typeid_suffix(uuid))
}

pub fn parse_typeid(prefix: &str, text: &str) -> Option<Uuid> {
    text.strip_prefix(prefix).and_then(parse_typeid_suffix)
}

// An epoch's id: a random UUID, never a counter (0051, Epochs).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct EpochId(pub Uuid);

// Where a pull resumes. The service's cursor is opaque text; CloudKit's is the zone's change token.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Cursor {
    Service(String),
    CloudKit(Vec<u8>),
}

// A write's precondition. The service's tag is opaque base64url text (0051, Change tags) and CloudKit's is the
// record's archived system fields (0054); a client never parses either.
#[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum ChangeTag {
    Service(String),
    CloudKit(Vec<u8>),
}

impl fmt::Debug for ChangeTag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Service(tag) => f.debug_tuple("Service").field(tag).finish(),
            Self::CloudKit(bytes) => f.debug_tuple("CloudKit").field(&bytes.len()).finish(),
        }
    }
}

// A kind as the wire carries it. A well-formed kind this build does not know is kept and sent back unchanged (0054).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct KindName(String);

impl KindName {
    pub fn parse(name: &str) -> Result<Self, SyncError> {
        if tablepro_records::kind::well_formed(name) {
            Ok(Self(name.to_owned()))
        } else {
            Err(SyncError::Malformed { what: "kind" })
        }
    }

    pub fn of(kind: Kind) -> Self {
        Self(kind.as_str().to_owned())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn known(&self) -> Option<Kind> {
        Kind::parse(&self.0).ok().flatten()
    }

    pub fn is_key(&self) -> bool {
        self.0.starts_with("key.")
    }
}

impl From<Kind> for KindName {
    fn from(kind: Kind) -> Self {
        Self::of(kind)
    }
}

impl fmt::Display for KindName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

// One record in one scope: the store's key, and the key of every per-record state row.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct RecordKey {
    pub scope: ScopeName,
    pub kind: KindName,
    pub record_id: String,
}

impl RecordKey {
    pub fn new(scope: ScopeName, kind: impl Into<KindName>, record_id: impl Into<String>) -> Self {
        Self {
            scope,
            kind: kind.into(),
            record_id: record_id.into(),
        }
    }
}

// 1 to 255 visible ASCII characters; our clients send a UUIDv4 per batch (0051, Idempotency).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct IdempotencyKey(pub String);

impl IdempotencyKey {
    pub fn parse(text: &str) -> Result<Self, SyncError> {
        let visible = !text.is_empty() && text.len() <= 255 && text.bytes().all(|byte| (0x21..=0x7e).contains(&byte));
        if visible {
            Ok(Self(text.to_owned()))
        } else {
            Err(SyncError::Malformed {
                what: "idempotency key",
            })
        }
    }
}

// A device row's id as the server names it (`dev_...`), which a token and a stop report carry.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeviceRowId(pub String);

// The 16 random bytes a state file is made with (0054, `binding`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FileId(pub [u8; 16]);

// The hex digest that names one identity's state file (0054, One per provider and account). It stays the same when
// the file is lost or made again, so the device store finds an anchor that outlived its file by it.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct StateName(pub String);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn another_id_type_reads_back_under_its_own_prefix_only() {
        let uuid = Uuid::parse_str("01890a5d-ac96-774b-bcce-b302099a8057").unwrap();

        let account = typeid("acct_", uuid);

        assert_eq!(account, "acct_01h455vb4pex5vsknk084sn02q");
        assert_eq!(parse_typeid("acct_", &account), Some(uuid));
        assert_eq!(parse_typeid("dev_", &account), None);
        assert_eq!(parse_typeid("acct_", "acct_81h455vb4pex5vsknk084sn02q"), None);
        assert_eq!(parse_typeid("acct_", "acct_01h455vb4pex5vsknk084sn02"), None);
        assert_eq!(parse_typeid("acct_", "acct_01h455vb4pex5vsknk084sn0iq"), None);
    }

    #[test]
    fn a_team_scope_is_its_typeid() {
        let team = TeamId(Uuid::parse_str("01890a5d-ac96-774b-bcce-b302099a8057").unwrap());

        let wire = ScopeName::Team(team).wire();

        assert_eq!(wire, "team_01h455vb4pex5vsknk084sn02q");
        assert_eq!(ScopeName::parse(&wire).unwrap(), ScopeName::Team(team));
        assert_eq!(
            ScopeName::Team(TeamId(Uuid::nil())).wire(),
            "team_00000000000000000000000000"
        );
    }

    #[test]
    fn a_scope_name_that_is_not_one_is_refused() {
        for text in [
            "",
            "Personal",
            "team_",
            "team_81h455vb4pex5vsknk084sn02q",
            "team_01h455vb4pex5vsknk084sn02u",
        ] {
            assert!(ScopeName::parse(text).is_err(), "{text}");
        }
        assert_eq!(ScopeName::parse("history").unwrap(), ScopeName::History);
    }

    #[test]
    fn a_kind_keeps_what_this_build_does_not_know() {
        let unknown = KindName::parse("future_kind").unwrap();

        assert_eq!(unknown.known(), None);
        assert_eq!(KindName::parse("connection").unwrap().known(), Some(Kind::Connection));
        assert!(KindName::parse("Not.A.Kind").is_err());
        assert!(KindName::parse("key.account").unwrap().is_key());
    }

    #[test]
    fn an_idempotency_key_is_visible_ascii() {
        assert!(IdempotencyKey::parse("4a6f").is_ok());
        assert!(IdempotencyKey::parse("").is_err());
        assert!(IdempotencyKey::parse("a b").is_err());
        assert!(IdempotencyKey::parse(&"a".repeat(256)).is_err());
    }
}
