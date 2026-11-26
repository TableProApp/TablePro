// The account and device key material a device holds (0056, Keys), and the account objects every account change set
// carries: genesis, rotation, replace, recovery and a reset's activation build them here.

use std::sync::Arc;

use tablepro_keys::KeysError;
use tablepro_keys::body::{AccountBody, DeviceBody, KeyBody, KeyObject, WrapBody};
use tablepro_keys::cert::{AccountCertificate, CertKind, DeviceCertificate, IkChange};
use tablepro_keys::encoding::{KeyDeviceId, KeyPurpose, ResetId, Version, WrapPurpose};
use tablepro_keys::keys::{
    AccountKeys, AccountPublicKeys, DeviceKeys, Ed25519Public, Ed25519Seed, X25519Public, X25519Secret,
};
use tablepro_keys::record_id::{KeyKind, KeyRecordId};
use tablepro_keys::recovery::RecoveryKey;
use tablepro_keys::trust::{PinHow, Replaced, merge_replaced};
use tablepro_keys::wrap::{Wrap, Wrapper, device_target};
use uuid::Uuid;
use zeroize::Zeroizing;

use super::KeyService;
use super::pins::seen_replaced;
use crate::api::device_store::DeviceItem;
use crate::api::error::SyncError;
use crate::api::ids::ScopeName;
use crate::api::key_flows::LockCause;
use crate::api::state::{KeyPinRow, KeyVersionRow, KeyVersionState, Row, StateTxn};
use crate::api::transport::DpopKey;

// The first byte of every item this file writes, so a later format can be told apart.
const ITEM_FORMAT: u8 = 1;
// The device keys item while a Sign Out is under way.
const SIGNING_OUT: u8 = 2;
const DEVICE_KEYS_LEN: usize = 16 + 32 + 32;
const ACCOUNT_KEYS_LEN: usize = 32 + 32;

// The device keys of this (origin, account, device row): the ones in force, and while an approval is in flight the new
// ones beside them, which replace them once it applies (0056, Keys).
#[derive(Debug, Clone, Default)]
pub struct HeldDeviceKeys {
    pub current: Option<DeviceKeys>,
    pub pending: Option<DeviceKeys>,
}

// A reset this device proposed: the account keys and device keys its proposal certifies, kept until it activates or
// ends (0054, `key_pending`).
#[derive(Debug, Clone)]
pub struct ResetKeys {
    pub account: AccountKeys,
    pub device: DeviceKeys,
}

pub(crate) struct SigningOut {
    pub(crate) keys: HeldDeviceKeys,
    pub(crate) resets: Vec<ResetId>,
}

// This device's own account as its key tables and device store hold it: the newest `av` it verified, the IK it
// pinned, and the keys at that `av`.
#[derive(Debug, Clone)]
pub struct OwnAccount {
    pub av: Version,
    pub ik: Ed25519Public,
    pub public: AccountPublicKeys,
    pub keys: AccountKeys,
    pub device: DeviceKeys,
}

// A key device an account change set certifies: its id and the keys a comparison fixed, never a certificate's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeptDevice {
    pub key_device: KeyDeviceId,
    pub dek: X25519Public,
    pub dsk: Ed25519Public,
}

impl KeptDevice {
    pub fn of(keys: &DeviceKeys) -> Result<Self, SyncError> {
        Ok(Self {
            key_device: keys.key_device,
            dek: keys.dek.public()?,
            dsk: keys.dsk.public()?,
        })
    }
}

// The account objects of one account change set at `av`: the certificate under `ik`, the recovery blob under
// `recovery`, a device certificate for each kept device and, when `wrapper` is set, an `account` wrap to each signed by
// the wrapper's DSK (0056, Account flows).
pub struct AccountObjectsPlan<'a> {
    pub av: Version,
    pub kind: CertKind,
    pub ik: &'a Ed25519Seed,
    // With kind 1, the IK of the certificate at `av - 1`, which endorses `ik`.
    pub endorsing_ik: Option<&'a Ed25519Seed>,
    pub recovery: &'a RecoveryKey,
    pub keys: &'a AccountKeys,
    pub devices: &'a [KeptDevice],
    // None at genesis, which wraps the account keys to no device.
    pub wrapper: Option<&'a DeviceKeys>,
}

impl KeyService {
    // A Sign Out under way holds no keys any flow may use.
    pub async fn device_keys(&self) -> Result<HeldDeviceKeys, SyncError> {
        match self.device_store.load(self.device_keys_item()).await? {
            None => Ok(HeldDeviceKeys::default()),
            Some(bytes) if bytes.first() == Some(&SIGNING_OUT) => Ok(HeldDeviceKeys::default()),
            Some(bytes) => decode_held_device_keys(&bytes),
        }
    }

    pub async fn store_device_keys(&self, keys: &HeldDeviceKeys) -> Result<(), SyncError> {
        if self.signing_out().await?.is_some() {
            return Err(SyncError::NotAllowed {
                what: "store device keys before a Sign Out under way finishes",
            });
        }
        // Sized up front, so no secret byte is left behind in a buffer a reallocation frees.
        let mut out = Zeroizing::new(Vec::with_capacity(1 + 2 * (1 + DEVICE_KEYS_LEN)));
        out.push(ITEM_FORMAT);
        encode_held_device_keys(keys, &mut out);
        Ok(self.device_store.store(self.device_keys_item(), out).await?)
    }

    // A Sign Out that started and has not finished: the device keys it proves with and the resets whose keys it
    // erases. Kept in the device keys' own item, so the secrets go before the record of what to erase does.
    pub(crate) async fn signing_out(&self) -> Result<Option<SigningOut>, SyncError> {
        match self.device_store.load(self.device_keys_item()).await? {
            Some(bytes) if bytes.first() == Some(&SIGNING_OUT) => decode_signing_out(&bytes).map(Some),
            _ => Ok(None),
        }
    }

    pub(crate) async fn start_signing_out(&self, signing_out: &SigningOut) -> Result<(), SyncError> {
        let mut out = Zeroizing::new(Vec::with_capacity(
            1 + 2 + 16 * signing_out.resets.len() + 2 * (1 + DEVICE_KEYS_LEN),
        ));
        out.push(SIGNING_OUT);
        let resets = u16::try_from(signing_out.resets.len()).map_err(|_| SyncError::Malformed {
            what: "too many resets to sign out of",
        })?;
        out.extend_from_slice(&resets.to_be_bytes());
        for reset in &signing_out.resets {
            out.extend_from_slice(reset.0.as_bytes());
        }
        encode_held_device_keys(&signing_out.keys, &mut out);
        Ok(self.device_store.store(self.device_keys_item(), out).await?)
    }

    // The device keys in force, made and stored first when the row has none: a device proves even its first pull, and
    // its genesis or its first request certifies them (0056, Approving a device, step 1).
    pub async fn ensure_device_keys(&self) -> Result<DeviceKeys, SyncError> {
        let held = self.device_keys().await?;
        if let Some(current) = held.current {
            return Ok(current);
        }
        let device = DeviceKeys::generate()?;
        self.store_device_keys(&HeldDeviceKeys {
            current: Some(device.clone()),
            pending: held.pending,
        })
        .await?;
        Ok(device)
    }

    pub(crate) async fn erase_device_keys(&self) -> Result<(), SyncError> {
        Ok(self.device_store.delete(self.device_keys_item()).await?)
    }

    // ASK and AEK at one `av`, kept while a scope key is still wrapped to that AEK.
    pub async fn account_keys(&self, av: Version) -> Result<Option<AccountKeys>, SyncError> {
        // A Sign Out under way leaves no key a flow may use.
        if self.signing_out().await?.is_some() {
            return Ok(None);
        }
        match self.device_store.load(self.account_keys_item(av)).await? {
            Some(bytes) => {
                let body = item_body(&bytes, ACCOUNT_KEYS_LEN, "account keys item")?;
                Ok(Some(AccountKeys::from_plaintext(body)?))
            }
            None => Ok(None),
        }
    }

    pub async fn store_account_keys(&self, av: Version, keys: &AccountKeys) -> Result<(), SyncError> {
        let mut out = Zeroizing::new(Vec::with_capacity(1 + ACCOUNT_KEYS_LEN));
        out.push(ITEM_FORMAT);
        out.extend_from_slice(keys.to_plaintext().as_slice());
        Ok(self.device_store.store(self.account_keys_item(av), out).await?)
    }

    pub(crate) async fn erase_account_keys(&self, av: Version) -> Result<(), SyncError> {
        Ok(self.device_store.delete(self.account_keys_item(av)).await?)
    }

    pub async fn reset_keys(&self, reset: ResetId) -> Result<Option<ResetKeys>, SyncError> {
        if self.signing_out().await?.is_some() {
            return Ok(None);
        }
        self.load_reset_keys(reset).await
    }

    // Sign Out reads them to prove the reset's end, past the gate above.
    pub(crate) async fn load_reset_keys(&self, reset: ResetId) -> Result<Option<ResetKeys>, SyncError> {
        match self.device_store.load(self.reset_keys_item(reset)).await? {
            Some(bytes) => {
                let body = item_body(&bytes, ACCOUNT_KEYS_LEN + DEVICE_KEYS_LEN, "reset keys item")?;
                Ok(Some(ResetKeys {
                    account: AccountKeys::from_plaintext(&body[..ACCOUNT_KEYS_LEN])?,
                    device: decode_device_keys(&body[ACCOUNT_KEYS_LEN..])?,
                }))
            }
            None => Ok(None),
        }
    }

    pub async fn store_reset_keys(&self, reset: ResetId, keys: &ResetKeys) -> Result<(), SyncError> {
        let mut out = Zeroizing::new(Vec::with_capacity(1 + ACCOUNT_KEYS_LEN + DEVICE_KEYS_LEN));
        out.push(ITEM_FORMAT);
        out.extend_from_slice(keys.account.to_plaintext().as_slice());
        encode_device_keys(&keys.device, &mut out);
        Ok(self.device_store.store(self.reset_keys_item(reset), out).await?)
    }

    pub async fn erase_reset_keys(&self, reset: ResetId) -> Result<(), SyncError> {
        Ok(self.device_store.delete(self.reset_keys_item(reset)).await?)
    }

    fn device_keys_item(&self) -> DeviceItem {
        DeviceItem::DeviceKeys {
            origin: self.origin.clone(),
            account: self.account,
            device_row: self.device_row.clone(),
        }
    }

    fn account_keys_item(&self, av: Version) -> DeviceItem {
        DeviceItem::AccountKeys {
            origin: self.origin.clone(),
            account: self.account,
            av,
        }
    }

    fn reset_keys_item(&self, reset: ResetId) -> DeviceItem {
        DeviceItem::ResetKeys {
            origin: self.origin.clone(),
            account: self.account,
            reset,
        }
    }

    // None while this device holds no keys of the account it can use: before genesis or approval, or locked.
    pub async fn own_account(&self, txn: &mut dyn StateTxn) -> Result<Option<OwnAccount>, SyncError> {
        let Some(pin) = self.pin(txn, self.account).await? else {
            return Ok(None);
        };
        if pin.alert {
            return Ok(None);
        }
        let Some(device) = self.device_keys().await?.current else {
            return Ok(None);
        };
        let Some(certificate) = self.own_certificate(txn, pin.av).await? else {
            return Ok(None);
        };
        if certificate.ik != pin.ik {
            return Ok(None);
        }
        certificate.verify(&self.origin)?;
        if !self.certifies(txn, &certificate, &device).await? {
            return Ok(None);
        }
        let Some(keys) = self.account_keys(pin.av).await? else {
            return Ok(None);
        };
        keys.check_against(&certificate.ask, &certificate.aek)?;
        Ok(Some(OwnAccount {
            av: pin.av,
            ik: pin.ik,
            public: AccountPublicKeys {
                ask: certificate.ask,
                aek: certificate.aek,
            },
            keys,
            device,
        }))
    }

    // The own account's certificate at `av` as the personal scope holds it, unverified.
    pub(crate) async fn own_certificate(
        &self,
        txn: &mut dyn StateTxn,
        av: Version,
    ) -> Result<Option<AccountCertificate>, SyncError> {
        let id = KeyRecordId::Account {
            account: self.account,
            av,
        };
        let held = self
            .applied_object(txn, ScopeName::Personal, KeyKind::Account, &id.to_wire())
            .await?;
        Ok(held.and_then(|object| match object.body {
            KeyBody::Account(body) => Some(body.certificate(self.account, av)),
            _ => None,
        }))
    }

    // Whether the personal scope holds a device certificate for `device` at the certificate's `av`, under its ASK and
    // naming the keys the device holds.
    pub(crate) async fn certifies(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
        device: &DeviceKeys,
    ) -> Result<bool, SyncError> {
        let id = KeyRecordId::Device {
            account: self.account,
            key_device: device.key_device,
            av: certificate.av,
        };
        let Some(object) = self
            .applied_object(txn, ScopeName::Personal, KeyKind::Device, &id.to_wire())
            .await?
        else {
            return Ok(false);
        };
        let KeyBody::Device(body) = object.body else {
            return Ok(false);
        };
        let device_certificate = body.certificate(self.account, device.key_device, certificate.av);
        if device_certificate.verify(&self.origin, &certificate.ask).is_err() {
            return Ok(false);
        }
        Ok(device_certificate.dek == device.dek.public()? && device_certificate.dsk == device.dsk.public()?)
    }

    // The DSK of the device keys in force, which every call from an approved device proves with.
    pub async fn dpop_key(&self) -> Result<DpopKey, SyncError> {
        let device = self.device_keys().await?.current.ok_or(SyncError::NotAllowed {
            what: "prove a call without device keys",
        })?;
        Ok(DpopKey(Arc::new(device.dsk.clone())))
    }

    pub fn account_objects(&self, plan: &AccountObjectsPlan<'_>) -> Result<Vec<KeyObject>, SyncError> {
        let account = self.account;
        let certificate = AccountCertificate::sign(
            &self.origin,
            account,
            plan.av,
            plan.kind,
            plan.ik,
            plan.keys.public()?,
            plan.endorsing_ik,
        )?;
        let blob = plan.recovery.seal_blob(&self.origin, account, plan.av, plan.keys)?;
        let mut objects = vec![
            KeyObject {
                id: KeyRecordId::Account { account, av: plan.av },
                body: KeyBody::Account(AccountBody::of(&certificate)),
            },
            KeyObject {
                id: KeyRecordId::Recovery { account, av: plan.av },
                body: KeyBody::Recovery(blob),
            },
        ];
        for device in plan.devices {
            let device_certificate = DeviceCertificate::sign(
                &self.origin,
                account,
                plan.av,
                device.key_device,
                device.dek,
                device.dsk,
                &plan.keys.ask,
            )?;
            objects.push(KeyObject {
                id: KeyRecordId::Device {
                    account,
                    key_device: device.key_device,
                    av: plan.av,
                },
                body: KeyBody::Device(DeviceBody::of(&device_certificate)),
            });
            if let Some(wrapper) = plan.wrapper {
                let target = device_target(account, WrapPurpose::Account, plan.av, device.key_device);
                let wrap = Wrap::seal_account(
                    &self.origin,
                    target,
                    &device.dek,
                    plan.keys,
                    Wrapper {
                        account,
                        av: plan.av,
                        key_device: wrapper.key_device,
                    },
                    &wrapper.dsk,
                )?;
                objects.push(KeyObject {
                    id: KeyRecordId::Wrap(target),
                    body: KeyBody::Wrap(WrapBody::of(&wrap)),
                });
            }
        }
        Ok(objects)
    }

    // The IKs the account had before `certificate`, oldest first, as far down as each step keeps the IK or is a replace
    // the older IK endorsed. A step nothing endorsed ends it, so a certificate the server made up never joins.
    async fn endorsed_chain(
        &self,
        txn: &mut dyn StateTxn,
        certificate: &AccountCertificate,
    ) -> Result<Vec<Replaced>, SyncError> {
        let mut chain = Vec::new();
        let mut above = certificate.clone();
        while let Some(av) = above.av.previous() {
            let Some(older) = self.own_certificate(txn, av).await? else {
                break;
            };
            if older.verify(&self.origin).is_err() {
                break;
            }
            if older.ik != above.ik {
                match above.ik_change(&self.origin, &older.ik) {
                    Ok(IkChange::Endorsed) => chain.push(Replaced {
                        ik: older.ik,
                        av: above.av,
                    }),
                    _ => break,
                }
            }
            above = older;
        }
        chain.reverse();
        Ok(chain)
    }

    // An account change set this device pushed, once applied: its objects held as applied, the own pin at its `av`
    // with every IK the account had before it in `replaced`, and the personal and history versions it brings made
    // current. Each version must be the account's own, signed under the new ASK and above the one held.
    pub async fn adopt_account_change_set(
        &self,
        txn: &mut dyn StateTxn,
        objects: &[KeyObject],
    ) -> Result<(), SyncError> {
        let certificate = objects
            .iter()
            .find_map(|object| match (&object.id, &object.body) {
                (KeyRecordId::Account { account, av }, KeyBody::Account(body)) if *account == self.account => {
                    Some(body.certificate(*account, *av))
                }
                _ => None,
            })
            .ok_or(SyncError::Malformed {
                what: "account change set without its certificate",
            })?;
        certificate.verify(&self.origin)?;
        let mut versions = Vec::new();
        for object in objects {
            let Some(record) = object.version_record() else {
                continue;
            };
            if record.key.purpose == KeyPurpose::Team
                || record.signer != self.account
                || record.key.owner != self.account.0
                || record.signer_av != certificate.av
            {
                return Err(KeysError::Signature.into());
            }
            record.verify(&self.origin, &certificate.ask)?;
            if let Some(held) = self.personal_row(txn, record.key.purpose).await? {
                if held.state == KeyVersionState::Ended {
                    return Err(SyncError::Locked {
                        cause: LockCause::AccountEnded,
                    });
                }
                // A recovery may pass versions a stopped device never took; it never goes back.
                if record.key.version <= held.version {
                    return Err(KeysError::Stale {
                        held: held.version.get(),
                        offered: record.key.version.get(),
                    }
                    .into());
                }
            }
            versions.push(record);
        }
        for object in objects {
            self.hold_object(txn, ScopeName::Personal, object, true).await?;
        }
        let held = self.pin(txn, self.account).await?;
        let mut replaced = held.as_ref().map(|pin| pin.replaced.clone()).unwrap_or_default();
        replaced = merge_replaced(&replaced, &self.endorsed_chain(txn, &certificate).await?);
        if let Some(pin) = &held
            && pin.ik != certificate.ik
            && !seen_replaced(&replaced, &pin.ik)
        {
            replaced.push(Replaced {
                ik: pin.ik,
                av: certificate.av,
            });
        }
        let how = match &held {
            Some(pin) if pin.ik == certificate.ik => pin.how,
            // This device derived the IK from the recovery key itself.
            _ => PinHow::Compared,
        };
        txn.put(Row::KeyPin(KeyPinRow {
            account: self.account,
            ik: certificate.ik,
            av: held
                .as_ref()
                .filter(|pin| pin.ik == certificate.ik)
                .map_or(certificate.av, |pin| pin.av.max(certificate.av)),
            how,
            alert: false,
            replaced,
        }))
        .await?;
        for record in versions {
            txn.put(Row::KeyVersion(KeyVersionRow {
                scope: ScopeName::Personal,
                purpose: record.key.purpose,
                version: record.key.version,
                record: record.digest(&self.origin)?,
                holders: Vec::new(),
                state: KeyVersionState::Ok,
                stopped_cause: None,
                epoch: None,
            }))
            .await?;
        }
        Ok(())
    }
}

fn item_body<'a>(bytes: &'a [u8], len: usize, what: &'static str) -> Result<&'a [u8], SyncError> {
    match bytes.split_first() {
        Some((&ITEM_FORMAT, body)) if body.len() == len => Ok(body),
        _ => Err(SyncError::Malformed { what }),
    }
}

fn encode_device_keys(device: &DeviceKeys, out: &mut Vec<u8>) {
    out.extend_from_slice(device.key_device.0.as_bytes());
    out.extend_from_slice(device.dsk.expose());
    out.extend_from_slice(device.dek.expose());
}

fn decode_device_keys(bytes: &[u8]) -> Result<DeviceKeys, SyncError> {
    if bytes.len() != DEVICE_KEYS_LEN {
        return Err(SyncError::Malformed {
            what: "device keys item",
        });
    }
    let id = Uuid::from_slice(&bytes[..16]).map_err(|_| SyncError::Malformed {
        what: "device keys item",
    })?;
    Ok(DeviceKeys {
        key_device: KeyDeviceId(id),
        dsk: Ed25519Seed::from_slice(&bytes[16..48])?,
        dek: X25519Secret::from_slice(&bytes[48..80])?,
    })
}

fn encode_held_device_keys(keys: &HeldDeviceKeys, out: &mut Vec<u8>) {
    for slot in [&keys.current, &keys.pending] {
        match slot {
            Some(device) => {
                out.push(1);
                encode_device_keys(device, out);
            }
            None => out.push(0),
        }
    }
}

fn decode_signing_out(bytes: &[u8]) -> Result<SigningOut, SyncError> {
    let malformed = || SyncError::Malformed {
        what: "device keys item",
    };
    let rest = bytes.get(1..).ok_or_else(malformed)?;
    let count = u16::from_be_bytes(
        rest.get(..2)
            .ok_or_else(malformed)?
            .try_into()
            .map_err(|_| malformed())?,
    );
    let mut at = 2;
    let mut resets = Vec::with_capacity(usize::from(count));
    for _ in 0..count {
        let id = rest.get(at..at + 16).ok_or_else(malformed)?;
        resets.push(ResetId(Uuid::from_slice(id).map_err(|_| malformed())?));
        at += 16;
    }
    let tail = rest.get(at..).ok_or_else(malformed)?;
    let mut keys = Zeroizing::new(Vec::with_capacity(1 + tail.len()));
    keys.push(ITEM_FORMAT);
    keys.extend_from_slice(tail);
    Ok(SigningOut {
        keys: decode_held_device_keys(&keys)?,
        resets,
    })
}

fn decode_held_device_keys(bytes: &[u8]) -> Result<HeldDeviceKeys, SyncError> {
    let malformed = || SyncError::Malformed {
        what: "device keys item",
    };
    let Some((&ITEM_FORMAT, mut rest)) = bytes.split_first() else {
        return Err(malformed());
    };
    let mut slots = [None, None];
    for slot in &mut slots {
        let Some((&present, after)) = rest.split_first() else {
            return Err(malformed());
        };
        rest = after;
        match present {
            0 => {}
            1 if rest.len() >= DEVICE_KEYS_LEN => {
                *slot = Some(decode_device_keys(&rest[..DEVICE_KEYS_LEN])?);
                rest = &rest[DEVICE_KEYS_LEN..];
            }
            _ => return Err(malformed()),
        }
    }
    if !rest.is_empty() {
        return Err(malformed());
    }
    let [current, pending] = slots;
    Ok(HeldDeviceKeys { current, pending })
}
