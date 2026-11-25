// The approval change set (0056, Approving a device, steps 6 and 7): A certifies N's key device under ASK at the
// account's current `av` and wraps the account keys and its trust plaintext to N's DEK, both wraps signed by its DSK.
// N takes them only under the DSK and the IK its comparison covered.

use tablepro_keys::KeysError;
use tablepro_keys::body::{DeviceBody, KeyBody, KeyObject, WrapBody};
use tablepro_keys::cert::{AccountCertificate, DeviceCertificate};
use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, Version, WrapPurpose};
use tablepro_keys::keys::{AccountKeys, DeviceKeys, Ed25519Public};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::sas::SasDevice;
use tablepro_keys::trust::{RECORD_LIMIT, TrustPlaintext};
use tablepro_keys::wrap::{Wrap, Wrapper, device_target};

use crate::api::error::SyncError;
use crate::api::transport::RejectedCode;
use crate::keys::OwnAccount;

pub(crate) fn device_object(certificate: &DeviceCertificate) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Device {
            account: certificate.account,
            key_device: certificate.key_device,
            av: certificate.av,
        },
        body: KeyBody::Device(DeviceBody::of(certificate)),
    }
}

pub(crate) fn wrap_object(wrap: &Wrap) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Wrap(wrap.target),
        body: KeyBody::Wrap(WrapBody::of(wrap)),
    }
}

// A, at its own current `av`. A trust plaintext that still passes the record limit once every droppable first-use
// pin is left out fails the approval with `too_large`; no alert, comparison or replaced IK is dropped.
pub(crate) fn build(
    origin: &Origin,
    account: AccountId,
    own: &OwnAccount,
    n: &SasDevice,
    trust: &TrustPlaintext,
) -> Result<Vec<KeyObject>, SyncError> {
    let fitted = trust.fit_record(RECORD_LIMIT, own.av)?.ok_or(SyncError::Rejected {
        code: RejectedCode::TooLarge,
    })?;
    let certificate = DeviceCertificate::sign(origin, account, own.av, n.key_device, n.dek, n.dsk, &own.keys.ask)?;
    let wrapper = Wrapper {
        account,
        av: own.av,
        key_device: own.device.key_device,
    };
    let account_wrap = Wrap::seal_account(
        origin,
        device_target(account, WrapPurpose::Account, own.av, n.key_device),
        &n.dek,
        &own.keys,
        wrapper,
        &own.device.dsk,
    )?;
    let trust_wrap = Wrap::seal_trust(
        origin,
        device_target(account, WrapPurpose::Trust, own.av, n.key_device),
        &n.dek,
        &fitted,
        wrapper,
        &own.device.dsk,
    )?;
    Ok(vec![
        device_object(&certificate),
        wrap_object(&account_wrap),
        wrap_object(&trust_wrap),
    ])
}

// The objects of one approval of N's key device at one `av`, as N found them.
pub(crate) struct Arrived<'a> {
    pub certificate: &'a AccountCertificate,
    pub device: &'a DeviceCertificate,
    pub account_wrap: &'a Wrap,
    pub trust_wrap: &'a Wrap,
}

// The account keys print redacted.
#[derive(Debug)]
pub(crate) struct Opened {
    pub av: Version,
    pub keys: AccountKeys,
    pub trust: TrustPlaintext,
}

// N, with the new device keys it asked with and the approver's key device and the IK its words covered.
pub(crate) fn open(
    origin: &Origin,
    account: AccountId,
    n: &DeviceKeys,
    approver: &SasDevice,
    compared_ik: &Ed25519Public,
    arrived: &Arrived<'_>,
) -> Result<Opened, KeysError> {
    let certificate = arrived.certificate;
    let av = certificate.av;
    if certificate.account != account {
        return Err(KeysError::Mismatch {
            what: "the certificate is another account's",
        });
    }
    certificate.verify(origin)?;
    // A replace or a reset changed IK, which the words covered: the session ends and N asks again.
    if certificate.ik != *compared_ik {
        return Err(KeysError::Session);
    }
    let dek = n.dek.public()?;
    let dsk = n.dsk.public()?;
    let device = arrived.device;
    if device.account != account || device.av != av || device.key_device != n.key_device {
        return Err(KeysError::Mismatch {
            what: "the device certificate is not this key device's at the approval's av",
        });
    }
    device.verify(origin, &certificate.ask)?;
    if device.dek != dek || device.dsk != dsk {
        return Err(KeysError::Mismatch {
            what: "the device certificate names other keys than this device's",
        });
    }
    check_wrap(
        arrived.account_wrap,
        account,
        WrapPurpose::Account,
        av,
        n.key_device,
        approver,
    )?;
    check_wrap(
        arrived.trust_wrap,
        account,
        WrapPurpose::Trust,
        av,
        n.key_device,
        approver,
    )?;
    let public = tablepro_keys::keys::AccountPublicKeys {
        ask: certificate.ask,
        aek: certificate.aek,
    };
    let keys = arrived
        .account_wrap
        .open_account(origin, &n.dek, &dek, &approver.dsk, &public)?;
    let trust = arrived.trust_wrap.open_trust(origin, &n.dek, &dek, &approver.dsk)?;
    Ok(Opened { av, keys, trust })
}

// Both wraps go to N's key device at the approval's `av` and name the approver's key device as their writer, whose
// DSK the comparison covered. Any other writer is `keys.not_compared`, as a signature by another key is.
fn check_wrap(
    wrap: &Wrap,
    account: AccountId,
    purpose: WrapPurpose,
    av: Version,
    key_device: KeyDeviceId,
    approver: &SasDevice,
) -> Result<(), KeysError> {
    if wrap.target != device_target(account, purpose, av, key_device) {
        return Err(KeysError::Mismatch {
            what: "the wrap is not to this key device at the approval's av",
        });
    }
    if wrap.wrapper.account != account || wrap.wrapper.av != av || wrap.wrapper.key_device != approver.key_device {
        return Err(KeysError::NotCompared);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use tablepro_keys::cert::CertKind;
    use tablepro_keys::encoding::KeyPurpose;
    use tablepro_keys::keys::Ed25519Seed;
    use tablepro_keys::trust::{PinHow, TrustPin, TrustVersion};
    use uuid::Uuid;

    use super::*;

    struct World {
        origin: Origin,
        account: AccountId,
        ik: Ed25519Seed,
        own: OwnAccount,
        certificate: AccountCertificate,
        n: DeviceKeys,
    }

    fn sas(keys: &DeviceKeys) -> SasDevice {
        SasDevice {
            key_device: keys.key_device,
            dek: keys.dek.public().unwrap(),
            dsk: keys.dsk.public().unwrap(),
        }
    }

    fn world() -> World {
        let origin = Origin::parse("https://sync.example.com").unwrap();
        let account = AccountId(Uuid::from_u128(5));
        let ik = Ed25519Seed::generate().unwrap();
        let keys = AccountKeys::generate().unwrap();
        let av = Version::new(2).unwrap();
        let certificate = AccountCertificate::sign(
            &origin,
            account,
            av,
            CertKind::GenesisOrRotation,
            &ik,
            keys.public().unwrap(),
            None,
        )
        .unwrap();
        let own = OwnAccount {
            av,
            ik: ik.public().unwrap(),
            public: keys.public().unwrap(),
            keys,
            device: DeviceKeys::generate().unwrap(),
        };
        World {
            origin,
            account,
            ik,
            own,
            certificate,
            n: DeviceKeys::generate().unwrap(),
        }
    }

    fn trust(world: &World) -> TrustPlaintext {
        TrustPlaintext {
            pins: vec![TrustPin {
                account: world.account,
                ik: world.own.ik,
                av: world.own.av,
                how: PinHow::FirstUse,
                alert: false,
                replaced: Vec::new(),
            }],
            versions: vec![TrustVersion {
                owner: world.account.0,
                purpose: KeyPurpose::Personal,
                version: Version::new(2).unwrap(),
                record: [7; 32],
            }],
        }
    }

    fn parts(objects: &[KeyObject]) -> (DeviceCertificate, Wrap, Wrap) {
        let device = match (&objects[0].id, &objects[0].body) {
            (
                KeyRecordId::Device {
                    account,
                    key_device,
                    av,
                },
                KeyBody::Device(body),
            ) => body.certificate(*account, *key_device, *av),
            _ => panic!("not a device certificate"),
        };
        (device, objects[1].wrap().unwrap(), objects[2].wrap().unwrap())
    }

    fn opened(world: &World, objects: &[KeyObject], approver: &SasDevice) -> Result<Opened, KeysError> {
        let (device, account_wrap, trust_wrap) = parts(objects);
        open(
            &world.origin,
            world.account,
            &world.n,
            approver,
            &world.own.ik,
            &Arrived {
                certificate: &world.certificate,
                device: &device,
                account_wrap: &account_wrap,
                trust_wrap: &trust_wrap,
            },
        )
    }

    #[test]
    fn n_opens_what_a_built_under_the_compared_dsk_and_ik() {
        let world = world();
        let objects = build(&world.origin, world.account, &world.own, &sas(&world.n), &trust(&world)).unwrap();

        let opened = opened(&world, &objects, &sas(&world.own.device)).unwrap();

        assert_eq!(opened.av, world.own.av);
        assert_eq!(opened.trust, trust(&world));
        assert_eq!(opened.keys.ask.expose(), world.own.keys.ask.expose());
    }

    #[test]
    fn wraps_under_a_dsk_n_did_not_compare_are_keys_not_compared() {
        let world = world();
        let objects = build(&world.origin, world.account, &world.own, &sas(&world.n), &trust(&world)).unwrap();
        let mut other = sas(&world.own.device);
        other.dsk = Ed25519Seed::generate().unwrap().public().unwrap();

        let error = opened(&world, &objects, &other).unwrap_err();

        assert_eq!(error.code(), "keys.not_compared");
    }

    #[test]
    fn wraps_signed_by_the_account_key_are_keys_not_compared() {
        let world = world();
        let mut own = world.own.clone();
        own.device.dsk = Ed25519Seed::from_bytes(*world.own.keys.ask.expose());
        let objects = build(&world.origin, world.account, &own, &sas(&world.n), &trust(&world)).unwrap();

        let error = opened(&world, &objects, &sas(&world.own.device)).unwrap_err();

        assert_eq!(error.code(), "keys.not_compared");
    }

    #[test]
    fn a_certificate_under_another_ik_is_keys_session_or_keys_signature() {
        let mut world = world();
        let objects = build(&world.origin, world.account, &world.own, &sas(&world.n), &trust(&world)).unwrap();
        let other_ik = Ed25519Seed::generate().unwrap();
        let replaced = AccountCertificate::sign(
            &world.origin,
            world.account,
            world.own.av,
            CertKind::GenesisOrRotation,
            &other_ik,
            world.own.public,
            None,
        )
        .unwrap();
        let mut forged = replaced.clone();
        forged.ik = world.ik.public().unwrap();

        world.certificate = replaced;
        let after_replace = opened(&world, &objects, &sas(&world.own.device)).unwrap_err();
        world.certificate = forged;
        let forged = opened(&world, &objects, &sas(&world.own.device)).unwrap_err();

        assert_eq!(after_replace.code(), "keys.session");
        assert_eq!(forged.code(), "keys.signature");
    }

    #[test]
    fn account_keys_that_do_not_match_the_certificate_are_keys_mismatch() {
        let world = world();
        let mut objects = build(&world.origin, world.account, &world.own, &sas(&world.n), &trust(&world)).unwrap();
        let wrap = Wrap::seal_account(
            &world.origin,
            device_target(world.account, WrapPurpose::Account, world.own.av, world.n.key_device),
            &world.n.dek.public().unwrap(),
            &AccountKeys::generate().unwrap(),
            Wrapper {
                account: world.account,
                av: world.own.av,
                key_device: world.own.device.key_device,
            },
            &world.own.device.dsk,
        )
        .unwrap();
        objects[1] = wrap_object(&wrap);

        let error = opened(&world, &objects, &sas(&world.own.device)).unwrap_err();

        assert_eq!(error.code(), "keys.mismatch");
    }

    #[test]
    fn a_device_certificate_for_other_keys_is_keys_mismatch() {
        let world = world();
        let other = DeviceKeys::generate().unwrap();
        let mut n = sas(&world.n);
        n.dek = other.dek.public().unwrap();
        let objects = build(&world.origin, world.account, &world.own, &n, &trust(&world)).unwrap();

        let error = opened(&world, &objects, &sas(&world.own.device)).unwrap_err();

        assert_eq!(error.code(), "keys.mismatch");
    }

    #[test]
    fn a_trust_plaintext_whose_kept_pins_pass_the_record_limit_is_too_large() {
        let world = world();
        let mut trust = trust(&world);
        let ik = Ed25519Seed::generate().unwrap().public().unwrap();
        for index in 0..12_000_u128 {
            trust.pins.push(TrustPin {
                account: AccountId(Uuid::from_u128(1_000 + index)),
                ik,
                av: Version::FIRST,
                how: PinHow::Compared,
                alert: false,
                replaced: Vec::new(),
            });
        }

        let error = build(&world.origin, world.account, &world.own, &sas(&world.n), &trust).unwrap_err();

        assert_eq!(
            error,
            SyncError::Rejected {
                code: RejectedCode::TooLarge
            }
        );
    }
}
