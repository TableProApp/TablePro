use uuid::Uuid;

use crate::KeysError;
use crate::b64;
use crate::encoding::{AccountId, KeyPurpose, Version, uuid_from_wire, uuid_to_wire};
use crate::json::{self, JsonValue, Members, push_string};
use crate::keys::Ed25519Public;

// How a pin was made (ADR 0056, Pins).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PinHow {
    FirstUse,
    Compared,
    Replaced,
}

impl PinHow {
    pub fn name(self) -> &'static str {
        match self {
            Self::FirstUse => "first_use",
            Self::Compared => "compared",
            Self::Replaced => "replaced",
        }
    }

    pub fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "first_use" => Ok(Self::FirstUse),
            "compared" => Ok(Self::Compared),
            "replaced" => Ok(Self::Replaced),
            _ => Err(KeysError::encoding("unknown pin `how`")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustPin {
    pub account: AccountId,
    pub ik: Ed25519Public,
    pub av: Version,
    pub how: PinHow,
    pub alert: bool,
    // In the order each was replaced.
    pub replaced: Vec<Ed25519Public>,
}

impl TrustPin {
    // Left out first when the trust wrap would pass the record limit; pinned on first use again.
    pub fn droppable(&self) -> bool {
        self.how == PinHow::FirstUse && !self.alert && self.replaced.is_empty()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrustVersion {
    // The account for `personal` and `history`, the team for `team`.
    pub owner: Uuid,
    pub purpose: KeyPurpose,
    pub version: Version,
    // The SHA-256 of that version record's signed bytes.
    pub record: [u8; 32],
}

// The `trust` wrap's plaintext: the approver's pins and the newest version of each scope key it holds.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TrustPlaintext {
    pub pins: Vec<TrustPin>,
    pub versions: Vec<TrustVersion>,
}

impl TrustPlaintext {
    pub fn encode(&self) -> String {
        let mut out = String::from("{\"v\":1,\"pins\":[");
        for (index, pin) in self.pins.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str("{\"account\":");
            push_string(&mut out, &pin.account.to_wire());
            out.push_str(",\"ik\":");
            push_string(&mut out, &b64::encode(&pin.ik.0));
            out.push_str(&format!(",\"av\":{},\"how\":", pin.av));
            push_string(&mut out, pin.how.name());
            out.push_str(if pin.alert {
                ",\"alert\":true,\"replaced\":["
            } else {
                ",\"alert\":false,\"replaced\":["
            });
            for (position, replaced) in pin.replaced.iter().enumerate() {
                if position > 0 {
                    out.push(',');
                }
                push_string(&mut out, &b64::encode(&replaced.0));
            }
            out.push_str("]}");
        }
        out.push_str("],\"versions\":[");
        for (index, version) in self.versions.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str("{\"owner\":");
            push_string(&mut out, &uuid_to_wire(version.owner));
            out.push_str(",\"purpose\":");
            push_string(&mut out, version.purpose.name());
            out.push_str(&format!(",\"version\":{},\"record\":", version.version));
            push_string(&mut out, &b64::encode(&version.record));
            out.push('}');
        }
        out.push_str("]}");
        out
    }

    // Refuses a duplicate, missing or wrongly typed member and an unknown `v`; ignores an unknown member.
    pub fn parse(bytes: &[u8]) -> Result<Self, KeysError> {
        let value = json::parse(bytes)?;
        let mut members = Members::of(&value)?;
        check_format(&mut members)?;
        let pins = members.array("pins")?.iter().map(parse_pin).collect::<Result<_, _>>()?;
        let versions = members
            .array("versions")?
            .iter()
            .map(parse_version)
            .collect::<Result<_, _>>()?;
        Ok(Self { pins, versions })
    }

    // The plaintext with as many droppable pins left out, from the end, as it takes for `fits` to
    // hold; None when it still does not fit, since no alert, comparison or replaced IK is dropped.
    pub fn fit(&self, fits: impl Fn(&Self) -> bool) -> Option<Self> {
        let mut candidate = self.clone();
        loop {
            if fits(&candidate) {
                return Some(candidate);
            }
            let last = candidate.pins.iter().rposition(TrustPin::droppable)?;
            candidate.pins.remove(last);
        }
    }
}

pub(crate) fn check_format(members: &mut Members<'_>) -> Result<(), KeysError> {
    if json::as_integer(members.required("v")?)? != 1 {
        return Err(KeysError::encoding("unknown plaintext format `v`"));
    }
    Ok(())
}

fn parse_pin(value: &JsonValue) -> Result<TrustPin, KeysError> {
    let mut members = Members::of(value)?;
    let account = AccountId(uuid_from_wire(members.string("account")?)?);
    let ik = Ed25519Public(b64::decode_exact(members.string("ik")?)?);
    let av = members.version("av")?;
    let how = PinHow::parse(members.string("how")?)?;
    let alert = members.boolean("alert")?;
    let replaced = members
        .array("replaced")?
        .iter()
        .map(|item| json::as_str(item).and_then(b64::decode_exact).map(Ed25519Public))
        .collect::<Result<_, _>>()?;
    Ok(TrustPin {
        account,
        ik,
        av,
        how,
        alert,
        replaced,
    })
}

fn parse_version(value: &JsonValue) -> Result<TrustVersion, KeysError> {
    let mut members = Members::of(value)?;
    let owner = uuid_from_wire(members.string("owner")?)?;
    let purpose = KeyPurpose::parse(members.string("purpose")?)?;
    let version = members.version("version")?;
    let record = b64::decode_exact(members.string("record")?)?;
    Ok(TrustVersion {
        owner,
        purpose,
        version,
        record,
    })
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::{PinHow, TrustPin, TrustPlaintext, TrustVersion};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyPurpose, Version};
    use crate::keys::Ed25519Public;

    fn pin(how: PinHow, alert: bool, replaced: usize) -> TrustPin {
        TrustPin {
            account: AccountId(Uuid::from_u128(1)),
            ik: Ed25519Public([3; 32]),
            av: Version::new(4).unwrap(),
            how,
            alert,
            replaced: vec![Ed25519Public([4; 32]); replaced],
        }
    }

    fn sample() -> TrustPlaintext {
        TrustPlaintext {
            pins: vec![pin(PinHow::Compared, true, 1), pin(PinHow::FirstUse, false, 0)],
            versions: vec![TrustVersion {
                owner: Uuid::from_u128(2),
                purpose: KeyPurpose::Team,
                version: Version::new(7).unwrap(),
                record: [5; 32],
            }],
        }
    }

    #[test]
    fn round_trips() {
        let trust = sample();
        assert_eq!(TrustPlaintext::parse(trust.encode().as_bytes()).unwrap(), trust);
    }

    #[test]
    fn unknown_members_are_ignored_and_bad_ones_refused() {
        let text = sample().encode();
        let extra = text.replacen("{\"v\":1,", "{\"v\":1,\"later\":{\"x\":[1]},", 1);
        assert_eq!(TrustPlaintext::parse(extra.as_bytes()).unwrap(), sample());
        let unknown_v = text.replacen("\"v\":1", "\"v\":2", 1);
        assert!(matches!(
            TrustPlaintext::parse(unknown_v.as_bytes()),
            Err(KeysError::Encoding { .. })
        ));
        let duplicate = text.replacen("{\"v\":1,", "{\"v\":1,\"v\":1,", 1);
        assert!(TrustPlaintext::parse(duplicate.as_bytes()).is_err());
        let wrong_type = text.replacen("\"alert\":true", "\"alert\":1", 1);
        assert!(TrustPlaintext::parse(wrong_type.as_bytes()).is_err());
        let missing = text.replacen("\"alert\":true,", "", 1);
        assert!(TrustPlaintext::parse(missing.as_bytes()).is_err());
        let lower_case = text.replace(
            "00000000-0000-0000-0000-000000000001",
            "00000000-0000-0000-0000-00000000000a",
        );
        assert!(TrustPlaintext::parse(lower_case.as_bytes()).is_err());
    }

    #[test]
    fn fitting_drops_only_plain_first_use_pins() {
        let trust = TrustPlaintext {
            pins: vec![
                pin(PinHow::FirstUse, false, 0),
                pin(PinHow::FirstUse, false, 1),
                pin(PinHow::FirstUse, false, 0),
            ],
            versions: Vec::new(),
        };
        let fitted = trust.fit(|candidate| candidate.pins.len() <= 1).unwrap();
        assert_eq!(fitted.pins, vec![pin(PinHow::FirstUse, false, 1)]);
        assert_eq!(trust.fit(|candidate| candidate.pins.is_empty()), None);
    }
}
