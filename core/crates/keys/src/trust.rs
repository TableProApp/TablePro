use std::collections::HashSet;

use uuid::Uuid;
use zeroize::Zeroizing;

use crate::KeysError;
use crate::b64;
use crate::body::{KeyBody, WrapBody, body_json};
use crate::crypto::TAG_LEN;
use crate::encoding::{AccountId, KeyDeviceId, KeyPurpose, Version, uuid_from_wire, uuid_to_wire};
use crate::json::{self, Count, JsonValue, Members, Sink, push_string};
use crate::keys::Ed25519Public;
use crate::keys::Signature;
use crate::padding;
use crate::wrap::Wrapper;

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

// An IK seen replaced, with the `av` of the replace certificate that retired it (ADR 0066, Replace points). A
// certificate under it verifies as history only below that `av`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Replaced {
    pub ik: Ed25519Public,
    pub av: Version,
}

// The replace point of `ik` in a replaced list, if it is in it.
pub fn replace_point(replaced: &[Replaced], ik: &Ed25519Public) -> Option<Version> {
    replaced.iter().find(|entry| entry.ik == *ik).map(|entry| entry.av)
}

// Two replaced lists as one: each IK once, in the order it was replaced, at the lower of its two points (ADR 0066,
// Replace points).
pub fn merge_replaced(own: &[Replaced], offered: &[Replaced]) -> Vec<Replaced> {
    let mut out = own.to_vec();
    for entry in offered {
        match out.iter_mut().find(|held| held.ik == entry.ik) {
            Some(held) => held.av = held.av.min(entry.av),
            None => out.push(*entry),
        }
    }
    out
}

#[derive(Clone, PartialEq, Eq)]
pub struct TrustPin {
    pub account: AccountId,
    pub ik: Ed25519Public,
    pub av: Version,
    pub how: PinHow,
    pub alert: bool,
    // In the order each was replaced.
    pub replaced: Vec<Replaced>,
}

impl TrustPin {
    // Left out first when the trust wrap would pass the record limit; pinned on first use again.
    pub fn droppable(&self) -> bool {
        self.how == PinHow::FirstUse && !self.alert && self.replaced.is_empty()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct TrustVersion {
    // The account for `personal` and `history`, the team for `team`.
    pub owner: Uuid,
    pub purpose: KeyPurpose,
    pub version: Version,
    // The SHA-256 of that version record's signed bytes.
    pub record: [u8; 32],
}

// The `trust` wrap's plaintext: the approver's pins and the newest version of each scope key it holds.
#[derive(Clone, PartialEq, Eq, Default)]
pub struct TrustPlaintext {
    pub pins: Vec<TrustPin>,
    pub versions: Vec<TrustVersion>,
}

// Whom a person trusts is private, so no account, key or digest is printed.
impl std::fmt::Debug for TrustPin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TrustPin")
            .field("how", &self.how)
            .field("alert", &self.alert)
            .field("replaced", &self.replaced.len())
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for TrustVersion {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TrustVersion")
            .field("purpose", &self.purpose)
            .field("version", &self.version)
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for TrustPlaintext {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TrustPlaintext")
            .field("pins", &self.pins)
            .field("versions", &self.versions)
            .finish()
    }
}

// 1 MiB a record, on its `fields` encoded without HTML escaping (ADR 0051, Limits).
pub const RECORD_LIMIT: usize = 1 << 20;

// Written straight into `out`, so the integer leaves no copy on the heap.
fn push_version(out: &mut impl Sink, version: Version) {
    let mut digits = [0_u8; 10];
    let mut at = digits.len();
    let mut value = version.get();
    loop {
        at -= 1;
        digits[at] = b'0' + (value % 10) as u8;
        value /= 10;
        if value == 0 {
            break;
        }
    }
    for digit in &digits[at..] {
        out.push(char::from(*digit));
    }
}

fn encode_pin(pin: &TrustPin, out: &mut impl Sink) {
    out.push_str("{\"account\":");
    push_string(out, &Zeroizing::new(pin.account.to_wire()));
    out.push_str(",\"ik\":");
    push_string(out, &Zeroizing::new(b64::encode(&pin.ik.0)));
    out.push_str(",\"av\":");
    push_version(out, pin.av);
    out.push_str(",\"how\":");
    push_string(out, pin.how.name());
    out.push_str(if pin.alert {
        ",\"alert\":true,\"replaced\":["
    } else {
        ",\"alert\":false,\"replaced\":["
    });
    for (position, replaced) in pin.replaced.iter().enumerate() {
        if position > 0 {
            out.push(',');
        }
        out.push_str("{\"ik\":");
        push_string(out, &Zeroizing::new(b64::encode(&replaced.ik.0)));
        out.push_str(",\"av\":");
        push_version(out, replaced.av);
        out.push('}');
    }
    out.push_str("]}");
}

fn encode_version(version: &TrustVersion, out: &mut impl Sink) {
    out.push_str("{\"owner\":");
    push_string(out, &Zeroizing::new(uuid_to_wire(version.owner)));
    out.push_str(",\"purpose\":");
    push_string(out, version.purpose.name());
    out.push_str(",\"version\":");
    push_version(out, version.version);
    out.push_str(",\"record\":");
    push_string(out, &Zeroizing::new(b64::encode(&version.record)));
    out.push('}');
}

// The length of a `trust` wrap record's `fields` whose plaintext is `plaintext_len` bytes before padding.
pub fn trust_wrap_record_len(plaintext_len: usize, wrapper_av: Version) -> Result<usize, KeysError> {
    let empty = WrapBody {
        enc: [0; 32],
        ct: Vec::new(),
        wrapper: Wrapper {
            account: AccountId(Uuid::nil()),
            av: wrapper_av,
            key_device: KeyDeviceId(Uuid::nil()),
        },
        sig: Signature([0; 64]),
    };
    let base = body_json(&KeyBody::Wrap(empty)).len();
    let ct = padding::padded_len(plaintext_len)?
        .checked_add(TAG_LEN)
        .ok_or(KeysError::encoding("trust plaintext too long"))?;
    Ok(base + (ct * 4).div_ceil(3))
}

impl TrustPlaintext {
    // Sized before it is written, so no copy of the plaintext is left behind by a reallocation.
    pub fn encode(&self) -> Zeroizing<String> {
        let mut count = Count::default();
        self.encode_into(&mut count);
        let mut out = Zeroizing::new(String::with_capacity(count.0));
        self.encode_into(&mut *out);
        out
    }

    fn encode_into(&self, out: &mut impl Sink) {
        out.push_str("{\"v\":1,\"pins\":[");
        for (index, pin) in self.pins.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            encode_pin(pin, out);
        }
        out.push_str("],\"versions\":[");
        for (index, version) in self.versions.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            encode_version(version, out);
        }
        out.push_str("]}");
    }

    // Refuses a duplicate, missing or wrongly typed member and an unknown `v`; ignores an unknown
    // member. `pins` holds one entry per account and `versions` one per scope key.
    pub fn parse(bytes: &[u8]) -> Result<Self, KeysError> {
        let value = Zeroizing::new(json::parse(bytes)?);
        let mut members = Members::of(&value)?;
        check_format(&mut members)?;
        let pins = members.array("pins")?.iter().map(parse_pin).collect::<Result<_, _>>()?;
        let versions = members
            .array("versions")?
            .iter()
            .map(parse_version)
            .collect::<Result<_, _>>()?;
        let trust = Self { pins, versions };
        trust.check_unique()?;
        Ok(trust)
    }

    pub fn check_unique(&self) -> Result<(), KeysError> {
        let accounts: HashSet<AccountId> = self.pins.iter().map(|pin| pin.account).collect();
        let keys: HashSet<(Uuid, KeyPurpose)> = self
            .versions
            .iter()
            .map(|version| (version.owner, version.purpose))
            .collect();
        if accounts.len() != self.pins.len() || keys.len() != self.versions.len() {
            return Err(KeysError::encoding(
                "a second pin for an account, or a second version for a scope key",
            ));
        }
        Ok(())
    }

    // The plaintext whose `trust` wrap record fits `limit`, leaving out from the end as many pins as it
    // takes with `how` `first_use`, no alert and no replaced IK; None when it still does not fit, since
    // no alert, comparison or replaced IK is dropped (ADR 0056, Pins).
    pub fn fit_record(&self, limit: usize, wrapper_av: Version) -> Result<Option<Self>, KeysError> {
        let mut empty = Count::default();
        Self {
            pins: Vec::new(),
            versions: self.versions.clone(),
        }
        .encode_into(&mut empty);
        let empty = empty.0;
        let pin_lens: Vec<usize> = self
            .pins
            .iter()
            .map(|pin| {
                let mut count = Count::default();
                encode_pin(pin, &mut count);
                count.0
            })
            .collect();
        let mut kept = vec![true; self.pins.len()];
        let mut kept_len: usize = pin_lens.iter().sum();
        let mut kept_count = self.pins.len();
        // Each pass leaves out the next droppable pin from the end, so the whole fit is one walk.
        let mut droppable = (0..self.pins.len()).rev().filter(|index| self.pins[*index].droppable());
        loop {
            let plaintext_len = empty + kept_len + kept_count.saturating_sub(1);
            if trust_wrap_record_len(plaintext_len, wrapper_av)? <= limit {
                let pins = self
                    .pins
                    .iter()
                    .zip(&kept)
                    .filter(|(_, keep)| **keep)
                    .map(|(pin, _)| pin.clone())
                    .collect();
                return Ok(Some(Self {
                    pins,
                    versions: self.versions.clone(),
                }));
            }
            let Some(last) = droppable.next() else {
                return Ok(None);
            };
            kept[last] = false;
            kept_len -= pin_lens[last];
            kept_count -= 1;
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
    let replaced: Vec<Replaced> = members
        .array("replaced")?
        .iter()
        .map(parse_replaced)
        .collect::<Result<_, _>>()?;
    let iks: HashSet<Ed25519Public> = replaced.iter().map(|entry| entry.ik).collect();
    if iks.len() != replaced.len() {
        return Err(KeysError::encoding("an IK twice in a pin's replaced list"));
    }
    Ok(TrustPin {
        account,
        ik,
        av,
        how,
        alert,
        replaced,
    })
}

fn parse_replaced(value: &JsonValue) -> Result<Replaced, KeysError> {
    let mut members = Members::of(value)?;
    let ik = Ed25519Public(b64::decode_exact(members.string("ik")?)?);
    let av = members.version("av")?;
    Ok(Replaced { ik, av })
}

pub(crate) fn parse_version(value: &JsonValue) -> Result<TrustVersion, KeysError> {
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

    use super::{PinHow, Replaced, TrustPin, TrustPlaintext, TrustVersion, merge_replaced, trust_wrap_record_len};
    use crate::KeysError;
    use crate::encoding::{AccountId, KeyPurpose, Version};
    use crate::keys::Ed25519Public;

    fn pin(account: u128, how: PinHow, alert: bool, replaced: usize) -> TrustPin {
        TrustPin {
            account: AccountId(Uuid::from_u128(account)),
            ik: Ed25519Public([3; 32]),
            av: Version::new(4).unwrap(),
            how,
            alert,
            replaced: (0..replaced)
                .map(|index| Replaced {
                    ik: Ed25519Public([4 + u8::try_from(index).unwrap(); 32]),
                    av: Version::new(2).unwrap(),
                })
                .collect(),
        }
    }

    fn sample() -> TrustPlaintext {
        TrustPlaintext {
            pins: vec![pin(1, PinHow::Compared, true, 1), pin(2, PinHow::FirstUse, false, 0)],
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
        let encoded = trust.encode();
        assert_eq!(encoded.capacity(), encoded.len(), "sized once, so never moved");
        assert_eq!(TrustPlaintext::parse(trust.encode().as_bytes()).unwrap(), trust);
    }

    #[test]
    fn a_replaced_entry_carries_its_point_and_one_ik_twice_is_refused() {
        let text = sample().encode();
        let entry = format!("{{\"ik\":\"{}\",\"av\":2}}", crate::b64::encode(&[4; 32]));
        let twice = text.replacen(&entry, &format!("{entry},{entry}"), 1);

        assert!(text.contains(&format!("\"replaced\":[{entry}]")));
        assert!(matches!(
            TrustPlaintext::parse(twice.as_bytes()),
            Err(KeysError::Encoding { .. })
        ));
    }

    #[test]
    fn a_merge_keeps_each_ik_once_in_order_at_its_lower_point() {
        let entry = |byte: u8, av: u32| Replaced {
            ik: Ed25519Public([byte; 32]),
            av: Version::new(av).unwrap(),
        };

        let merged = merge_replaced(&[entry(1, 5), entry(2, 3)], &[entry(2, 2), entry(3, 7), entry(1, 6)]);

        assert_eq!(merged, vec![entry(1, 5), entry(2, 2), entry(3, 7)]);
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
        let second_pin = text.replace(
            "00000000-0000-0000-0000-000000000002",
            "00000000-0000-0000-0000-000000000001",
        );
        assert!(TrustPlaintext::parse(second_pin.as_bytes()).is_err());
    }

    #[test]
    fn fitting_drops_only_plain_first_use_pins_from_the_end() {
        let av = Version::new(3).unwrap();
        let many: Vec<TrustPin> = (1..=40)
            .map(|account| pin(account, PinHow::FirstUse, false, 0))
            .collect();
        let mut pins = vec![
            pin(100, PinHow::Compared, false, 0),
            pin(101, PinHow::FirstUse, false, 1),
        ];
        pins.extend(many);
        pins.push(pin(102, PinHow::Replaced, true, 2));
        let trust = TrustPlaintext {
            pins,
            versions: Vec::new(),
        };
        let size = |trust: &TrustPlaintext| trust_wrap_record_len(trust.encode().len(), av).unwrap();
        // Dropping one pin at a time from the end and measuring the whole record, as the ADR words it.
        let naive = |limit: usize| {
            let mut candidate = trust.clone();
            loop {
                if size(&candidate) <= limit {
                    return Some(candidate);
                }
                let last = candidate.pins.iter().rposition(TrustPin::droppable)?;
                candidate.pins.remove(last);
            }
        };
        let floor = TrustPlaintext {
            pins: trust.pins.iter().filter(|pin| !pin.droppable()).cloned().collect(),
            versions: Vec::new(),
        };
        for limit in (size(&floor) - 2)..=(size(&trust) + 2) {
            assert_eq!(trust.fit_record(limit, av).unwrap(), naive(limit), "limit {limit}");
        }
        assert_eq!(trust.fit_record(size(&floor) - 1, av).unwrap(), None);
        assert!(trust.fit_record(size(&floor), av).unwrap().is_some());
    }

    #[test]
    fn the_record_length_follows_the_padding_scale() {
        let av = Version::new(9).unwrap();
        assert_eq!(
            trust_wrap_record_len(0, av).unwrap(),
            trust_wrap_record_len(63, av).unwrap()
        );
        assert!(trust_wrap_record_len(64, av).unwrap() > trust_wrap_record_len(63, av).unwrap());
    }
}
