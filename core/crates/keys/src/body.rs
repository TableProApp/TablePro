// Key object bodies (ADR 0051, Key object bodies): exactly the members the table lists. A
// duplicate, unknown, missing or wrongly typed member is keys.encoding, and a suite but `tp1`
// keys.suite. Every value the record id carries comes from the id.

use crate::KeysError;
use crate::b64;
use crate::cert::{AccountCertificate, CertKind, DeviceCertificate};
use crate::crypto::NONCE_LEN;
use crate::encoding::{AccountId, KeyDeviceId, SUITE, Version, uuid_from_wire};
use crate::envelope::{Sealed, check_sealed_len};
use crate::json::{self, JsonValue, Members, push_string};
use crate::keys::{Ed25519Public, Kid, Signature, X25519Public};
use crate::record_id::{KeyKind, KeyRecordId, SasStep};
use crate::recovery::{BLOB_CT_LEN, RecoveryBlob};
use crate::scope_key::{KeyRef, RING_CT_LEN, Ring, Start, VersionRecord};
use crate::wrap::{Wrap, WrapTarget, Wrapper};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccountBody {
    pub kind: CertKind,
    pub ik: Ed25519Public,
    pub ask: Ed25519Public,
    pub aek: X25519Public,
    pub sig: Signature,
    pub replace_sig: Option<Signature>,
}

impl AccountBody {
    pub fn of(certificate: &AccountCertificate) -> Self {
        Self {
            kind: certificate.kind,
            ik: certificate.ik,
            ask: certificate.ask,
            aek: certificate.aek,
            sig: certificate.sig,
            replace_sig: certificate.replace_sig,
        }
    }

    pub fn certificate(&self, account: AccountId, av: Version) -> AccountCertificate {
        AccountCertificate {
            account,
            av,
            kind: self.kind,
            ik: self.ik,
            ask: self.ask,
            aek: self.aek,
            sig: self.sig,
            replace_sig: self.replace_sig,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceBody {
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
    pub sig: Signature,
}

impl DeviceBody {
    pub fn of(certificate: &DeviceCertificate) -> Self {
        Self {
            dek: certificate.dek,
            dsk: certificate.dsk,
            sig: certificate.sig,
        }
    }

    pub fn certificate(&self, account: AccountId, key_device: KeyDeviceId, av: Version) -> DeviceCertificate {
        DeviceCertificate {
            account,
            key_device,
            av,
            dek: self.dek,
            dsk: self.dsk,
            sig: self.sig,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResetBody {
    pub av: Version,
    pub key_device: KeyDeviceId,
    pub account: AccountBody,
    pub device: DeviceBody,
    pub recovery: RecoveryBlob,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CancelReason {
    User,
    Mismatch,
    Commitment,
}

impl CancelReason {
    pub fn name(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Mismatch => "mismatch",
            Self::Commitment => "commitment",
        }
    }

    fn parse(text: &str) -> Result<Self, KeysError> {
        match text {
            "user" => Ok(Self::User),
            "mismatch" => Ok(Self::Mismatch),
            "commitment" => Ok(Self::Commitment),
            _ => Err(KeysError::encoding("unknown cancel reason")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestBody {
    pub key_device: KeyDeviceId,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
    pub commit: [u8; 32],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SasBody {
    Nonce {
        key_device: KeyDeviceId,
        dek: X25519Public,
        dsk: Ed25519Public,
        r: [u8; 32],
    },
    Reveal {
        r: [u8; 32],
    },
    Cancel {
        reason: CancelReason,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionBody {
    pub start: Start,
    pub kid: Kid,
    pub signer: AccountId,
    pub signer_av: Version,
    pub sig: Signature,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WrapBody {
    pub enc: [u8; 32],
    pub ct: Vec<u8>,
    pub wrapper: Wrapper,
    pub sig: Signature,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyBody {
    Account(AccountBody),
    Device(DeviceBody),
    Recovery(RecoveryBlob),
    Reset(Box<ResetBody>),
    // `sig` is the IK cancel, present when the recovery key signs it.
    Cancel { sig: Option<Signature> },
    Request(RequestBody),
    Sas(SasBody),
    Version(VersionBody),
    Wrap(WrapBody),
    Ring(Ring),
    Member(AccountBody),
}

// A key object as a record carries it: its kind and id, and its parsed `fields`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyObject {
    pub id: KeyRecordId,
    pub body: KeyBody,
}

// No record is longer than 1 MiB (ADR 0051, Limits), so a longer one is refused before its tree is built.
fn parse_fields(fields: &[u8]) -> Result<JsonValue, KeysError> {
    if fields.len() > crate::trust::RECORD_LIMIT {
        return Err(KeysError::encoding("fields longer than the 1 MiB record limit"));
    }
    json::parse(fields)
}

impl KeyObject {
    pub fn parse(kind: &str, record_id: &str, fields: &[u8]) -> Result<Self, KeysError> {
        let kind = KeyKind::parse(kind)?;
        let id = KeyRecordId::parse(kind, record_id)?;
        let value = parse_fields(fields)?;
        let body = parse_body(&id, &value)?;
        Ok(Self { id, body })
    }

    pub fn fields_json(&self) -> String {
        body_json(&self.body)
    }

    pub fn version_record(&self) -> Option<VersionRecord> {
        match (&self.id, &self.body) {
            (KeyRecordId::Version(key), KeyBody::Version(body)) => Some(VersionRecord {
                key: *key,
                start: body.start,
                kid: body.kid,
                signer: body.signer,
                signer_av: body.signer_av,
                sig: body.sig,
            }),
            _ => None,
        }
    }

    pub fn wrap(&self) -> Option<Wrap> {
        match (&self.id, &self.body) {
            (KeyRecordId::Wrap(target), KeyBody::Wrap(body)) => Some(Wrap {
                target: *target,
                enc: body.enc,
                ct: body.ct.clone(),
                wrapper: body.wrapper,
                sig: body.sig,
            }),
            _ => None,
        }
    }
}

fn check_suite(members: &mut Members<'_>) -> Result<(), KeysError> {
    let suite = members.string("suite")?;
    if suite == SUITE {
        Ok(())
    } else {
        Err(KeysError::Suite {
            found: suite.to_owned(),
        })
    }
}

fn bytes<const N: usize>(members: &mut Members<'_>, name: &str) -> Result<[u8; N], KeysError> {
    b64::decode_exact(members.string(name)?)
}

fn signature(members: &mut Members<'_>, name: &str) -> Result<Signature, KeysError> {
    bytes::<64>(members, name).map(Signature)
}

fn parse_account(value: &JsonValue) -> Result<AccountBody, KeysError> {
    let mut members = Members::of(value)?;
    check_suite(&mut members)?;
    let kind = CertKind::from_code(members.integer("kind")?)?;
    let ik = Ed25519Public(bytes(&mut members, "ik")?);
    let ask = Ed25519Public(bytes(&mut members, "ask")?);
    let aek = X25519Public(bytes(&mut members, "aek")?);
    let sig = signature(&mut members, "sig")?;
    let replace_sig = if kind == CertKind::Replace {
        Some(signature(&mut members, "replace_sig")?)
    } else {
        None
    };
    members.finish_strict()?;
    Ok(AccountBody {
        kind,
        ik,
        ask,
        aek,
        sig,
        replace_sig,
    })
}

fn parse_device(value: &JsonValue) -> Result<DeviceBody, KeysError> {
    let mut members = Members::of(value)?;
    check_suite(&mut members)?;
    let dek = X25519Public(bytes(&mut members, "dek")?);
    let dsk = Ed25519Public(bytes(&mut members, "dsk")?);
    let sig = signature(&mut members, "sig")?;
    members.finish_strict()?;
    Ok(DeviceBody { dek, dsk, sig })
}

fn parse_recovery(value: &JsonValue) -> Result<RecoveryBlob, KeysError> {
    let mut members = Members::of(value)?;
    check_suite(&mut members)?;
    let nonce = bytes::<NONCE_LEN>(&mut members, "nonce")?;
    let ct = bytes::<BLOB_CT_LEN>(&mut members, "ct")?;
    members.finish_strict()?;
    Ok(RecoveryBlob { nonce, ct })
}

fn key_device(members: &mut Members<'_>, name: &str) -> Result<KeyDeviceId, KeysError> {
    uuid_from_wire(members.string(name)?).map(KeyDeviceId)
}

fn parse_body(id: &KeyRecordId, value: &JsonValue) -> Result<KeyBody, KeysError> {
    let body = match id {
        KeyRecordId::Account { .. } => KeyBody::Account(parse_account(value)?),
        KeyRecordId::Member { .. } => KeyBody::Member(parse_account(value)?),
        KeyRecordId::Device { .. } => KeyBody::Device(parse_device(value)?),
        KeyRecordId::Recovery { .. } => KeyBody::Recovery(parse_recovery(value)?),
        KeyRecordId::Reset { .. } => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let av = members.version("av")?;
            let key_device = key_device(&mut members, "key_device")?;
            let account = parse_account(members.object("account")?)?;
            if !matches!(account.kind, CertKind::ResetKeepingKeys | CertKind::ResetEmpty) {
                return Err(KeysError::encoding("a reset proposes a certificate of kind 2 or 3"));
            }
            let device = parse_device(members.object("device")?)?;
            let recovery = parse_recovery(members.object("recovery")?)?;
            members.finish_strict()?;
            KeyBody::Reset(Box::new(ResetBody {
                av,
                key_device,
                account,
                device,
                recovery,
            }))
        }
        KeyRecordId::Cancel { .. } => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let sig = match members.optional("sig") {
                Some(text) => Some(Signature(b64::decode_exact(json::as_str(text)?)?)),
                None => None,
            };
            members.finish_strict()?;
            KeyBody::Cancel { sig }
        }
        KeyRecordId::Request { .. } => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let body = RequestBody {
                key_device: key_device(&mut members, "key_device")?,
                dek: X25519Public(bytes(&mut members, "dek")?),
                dsk: Ed25519Public(bytes(&mut members, "dsk")?),
                commit: bytes(&mut members, "commit")?,
            };
            members.finish_strict()?;
            KeyBody::Request(body)
        }
        KeyRecordId::Sas { step, .. } => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let body = match step {
                SasStep::Nonce => SasBody::Nonce {
                    key_device: key_device(&mut members, "key_device")?,
                    dek: X25519Public(bytes(&mut members, "dek")?),
                    dsk: Ed25519Public(bytes(&mut members, "dsk")?),
                    r: bytes(&mut members, "r")?,
                },
                SasStep::Reveal => SasBody::Reveal {
                    r: bytes(&mut members, "r")?,
                },
                SasStep::Cancel => SasBody::Cancel {
                    reason: CancelReason::parse(members.string("reason")?)?,
                },
            };
            members.finish_strict()?;
            KeyBody::Sas(body)
        }
        KeyRecordId::Version(_) => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let body = VersionBody {
                start: Start::from_code(members.integer("start")?)?,
                kid: Kid(bytes(&mut members, "kid")?),
                signer: AccountId(uuid_from_wire(members.string("signer")?)?),
                signer_av: members.version("signer_av")?,
                sig: signature(&mut members, "sig")?,
            };
            members.finish_strict()?;
            KeyBody::Version(body)
        }
        KeyRecordId::Wrap(target) => KeyBody::Wrap(parse_wrap(*target, value)?),
        KeyRecordId::Ring(_) => {
            let mut members = Members::of(value)?;
            check_suite(&mut members)?;
            let ring = Ring {
                nonce: bytes(&mut members, "nonce")?,
                ct: bytes::<RING_CT_LEN>(&mut members, "ct")?,
            };
            members.finish_strict()?;
            KeyBody::Ring(ring)
        }
    };
    Ok(body)
}

fn parse_wrap(target: WrapTarget, value: &JsonValue) -> Result<WrapBody, KeysError> {
    let mut members = Members::of(value)?;
    check_suite(&mut members)?;
    let enc = bytes(&mut members, "enc")?;
    let ct = b64::decode(members.string("ct")?)?;
    match target.expected_ct_len() {
        Some(len) if ct.len() != len => return Err(KeysError::encoding("wrap ct of the wrong length")),
        Some(_) => {}
        None => check_sealed_len(&ct)?,
    }
    let wrapper = Wrapper {
        account: AccountId(uuid_from_wire(members.string("wrapper")?)?),
        av: members.version("wrapper_av")?,
        key_device: key_device(&mut members, "wrapper_device")?,
    };
    let sig = signature(&mut members, "sig")?;
    members.finish_strict()?;
    Ok(WrapBody { enc, ct, wrapper, sig })
}

// The clear fields of a `secret_envelope` or a `history_entry`: `suite`, `kv`, `nonce`, `ct`.
pub fn parse_sealed(fields: &[u8]) -> Result<Sealed, KeysError> {
    let value = parse_fields(fields)?;
    let mut members = Members::of(&value)?;
    check_suite(&mut members)?;
    let kv = members.version("kv")?;
    let nonce = bytes(&mut members, "nonce")?;
    let ct = b64::decode(members.string("ct")?)?;
    check_sealed_len(&ct)?;
    members.finish_strict()?;
    Ok(Sealed { kv, nonce, ct })
}

pub fn sealed_json(sealed: &Sealed) -> String {
    let mut out = String::new();
    Writer::new(&mut out)
        .int("kv", sealed.kv.get())
        .bytes("nonce", &sealed.nonce)
        .bytes("ct", &sealed.ct)
        .end();
    out
}

// Writes a body with `suite` first and the rest in the order of ADR 0051's table.
struct Writer<'a> {
    out: &'a mut String,
}

impl<'a> Writer<'a> {
    fn new(out: &'a mut String) -> Self {
        out.push_str("{\"suite\":\"tp1\"");
        Self { out }
    }

    fn name(&mut self, name: &str) {
        self.out.push(',');
        push_string(self.out, name);
        self.out.push(':');
    }

    fn bytes(&mut self, name: &str, value: &[u8]) -> &mut Self {
        self.string(name, &b64::encode(value))
    }

    fn string(&mut self, name: &str, value: &str) -> &mut Self {
        self.name(name);
        push_string(self.out, value);
        self
    }

    fn int(&mut self, name: &str, value: u32) -> &mut Self {
        self.name(name);
        self.out.push_str(&value.to_string());
        self
    }

    fn raw(&mut self, name: &str, json: &str) -> &mut Self {
        self.name(name);
        self.out.push_str(json);
        self
    }

    fn end(&mut self) {
        self.out.push('}');
    }
}

fn account_json(body: &AccountBody) -> String {
    let mut out = String::new();
    let mut writer = Writer::new(&mut out);
    writer
        .int("kind", u32::from(body.kind.code()))
        .bytes("ik", &body.ik.0)
        .bytes("ask", &body.ask.0)
        .bytes("aek", &body.aek.0)
        .bytes("sig", &body.sig.0);
    if let Some(replace_sig) = &body.replace_sig {
        writer.bytes("replace_sig", &replace_sig.0);
    }
    writer.end();
    out
}

fn device_json(body: &DeviceBody) -> String {
    let mut out = String::new();
    Writer::new(&mut out)
        .bytes("dek", &body.dek.0)
        .bytes("dsk", &body.dsk.0)
        .bytes("sig", &body.sig.0)
        .end();
    out
}

fn recovery_json(blob: &RecoveryBlob) -> String {
    let mut out = String::new();
    Writer::new(&mut out)
        .bytes("nonce", &blob.nonce)
        .bytes("ct", &blob.ct)
        .end();
    out
}

pub fn body_json(body: &KeyBody) -> String {
    let mut out = String::new();
    match body {
        KeyBody::Account(account) | KeyBody::Member(account) => return account_json(account),
        KeyBody::Device(device) => return device_json(device),
        KeyBody::Recovery(blob) => return recovery_json(blob),
        KeyBody::Reset(reset) => Writer::new(&mut out)
            .int("av", reset.av.get())
            .string("key_device", &reset.key_device.to_wire())
            .raw("account", &account_json(&reset.account))
            .raw("device", &device_json(&reset.device))
            .raw("recovery", &recovery_json(&reset.recovery))
            .end(),
        KeyBody::Cancel { sig } => {
            let mut writer = Writer::new(&mut out);
            if let Some(sig) = sig {
                writer.bytes("sig", &sig.0);
            }
            writer.end();
        }
        KeyBody::Request(request) => Writer::new(&mut out)
            .string("key_device", &request.key_device.to_wire())
            .bytes("dek", &request.dek.0)
            .bytes("dsk", &request.dsk.0)
            .bytes("commit", &request.commit)
            .end(),
        KeyBody::Sas(SasBody::Nonce {
            key_device,
            dek,
            dsk,
            r,
        }) => Writer::new(&mut out)
            .string("key_device", &key_device.to_wire())
            .bytes("dek", &dek.0)
            .bytes("dsk", &dsk.0)
            .bytes("r", r)
            .end(),
        KeyBody::Sas(SasBody::Reveal { r }) => Writer::new(&mut out).bytes("r", r).end(),
        KeyBody::Sas(SasBody::Cancel { reason }) => Writer::new(&mut out).string("reason", reason.name()).end(),
        KeyBody::Version(version) => Writer::new(&mut out)
            .int("start", u32::from(version.start.code()))
            .bytes("kid", &version.kid.0)
            .string("signer", &version.signer.to_wire())
            .int("signer_av", version.signer_av.get())
            .bytes("sig", &version.sig.0)
            .end(),
        KeyBody::Wrap(wrap) => Writer::new(&mut out)
            .bytes("enc", &wrap.enc)
            .bytes("ct", &wrap.ct)
            .string("wrapper", &wrap.wrapper.account.to_wire())
            .int("wrapper_av", wrap.wrapper.av.get())
            .string("wrapper_device", &wrap.wrapper.key_device.to_wire())
            .bytes("sig", &wrap.sig.0)
            .end(),
        KeyBody::Ring(ring) => Writer::new(&mut out)
            .bytes("nonce", &ring.nonce)
            .bytes("ct", &ring.ct)
            .end(),
    }
    out
}

impl VersionBody {
    pub fn of(record: &VersionRecord) -> Self {
        Self {
            start: record.start,
            kid: record.kid,
            signer: record.signer,
            signer_av: record.signer_av,
            sig: record.sig,
        }
    }

    pub fn record(&self, key: KeyRef) -> VersionRecord {
        VersionRecord {
            key,
            start: self.start,
            kid: self.kid,
            signer: self.signer,
            signer_av: self.signer_av,
            sig: self.sig,
        }
    }
}

impl WrapBody {
    pub fn of(wrap: &Wrap) -> Self {
        Self {
            enc: wrap.enc,
            ct: wrap.ct.clone(),
            wrapper: wrap.wrapper,
            sig: wrap.sig,
        }
    }
}

// Two key objects are the same when their kind, record id and fields are equal as JSON values
// (ADR 0051, The same object). Another object at an id the client holds is keys.conflict.
pub fn check_same_object(
    held_kind: &str,
    held_id: &str,
    held: &[u8],
    offered_kind: &str,
    offered_id: &str,
    offered: &[u8],
) -> Result<(), KeysError> {
    let held = parse_fields(held)?;
    let offered = parse_fields(offered)?;
    if held_kind == offered_kind && held_id == offered_id && held.same_as(&offered) {
        Ok(())
    } else {
        Err(KeysError::Conflict)
    }
}

#[cfg(test)]
mod tests {
    use super::KeyObject;
    use crate::KeysError;

    const DEVICE: &str = "019A6B2E-8F3C-7D41-B2A5-6C0E9F14D7B8/DB09A1EA-A519-42FF-94F3-CEEE6232F1C2/4";
    const KEY32: &str = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE";
    const SIG: &str = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg";

    fn device_fields(extra: &str) -> String {
        format!(r#"{{"suite":"tp1","dek":"{KEY32}","dsk":"{KEY32}","sig":"{SIG}"{extra}}}"#)
    }

    #[test]
    fn a_device_body_round_trips() {
        let object = KeyObject::parse("key.device", DEVICE, device_fields("").as_bytes()).unwrap();
        assert_eq!(object.fields_json(), device_fields(""));
    }

    #[test]
    fn strict_members() {
        let encoding = |fields: &str| {
            matches!(
                KeyObject::parse("key.device", DEVICE, fields.as_bytes()),
                Err(KeysError::Encoding { .. })
            )
        };
        assert!(encoding(&device_fields(r#","x":1"#)), "unknown member");
        assert!(
            encoding(&device_fields(&format!(r#","dek":"{KEY32}""#))),
            "duplicate member"
        );
        assert!(
            encoding(&device_fields("").replace(&format!(r#","sig":"{SIG}""#), "")),
            "missing member"
        );
        assert!(
            encoding(&device_fields("").replace(&format!(r#""dek":"{KEY32}""#), r#""dek":1"#)),
            "wrong type"
        );
        assert!(
            encoding(&device_fields("").replace(KEY32, "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQ")),
            "short key"
        );
        assert!(
            encoding(&device_fields("").replace(KEY32, "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQF")),
            "pad bits"
        );
        assert_eq!(
            KeyObject::parse("key.device", DEVICE, device_fields("").replace("tp1", "tp2").as_bytes()).unwrap_err(),
            KeysError::Suite {
                found: "tp2".to_owned()
            }
        );
    }
}
