// The key objects a team's change sets carry (0056, Teams; 0051, Change sets): a version record with its ring and its
// wraps, a confirming wrap, and a member's certificate copied into the team.

use tablepro_keys::KeysError;
use tablepro_keys::body::{AccountBody, KeyBody, KeyObject, VersionBody, WrapBody};
use tablepro_keys::cert::AccountCertificate;
use tablepro_keys::encoding::{AccountId, KeyDeviceId, KeyPurpose, Origin, TeamId, Version};
use tablepro_keys::keys::{AccountKeys, ScopeKey};
use tablepro_keys::record_id::KeyRecordId;
use tablepro_keys::scope_key::{KeyRef, Ring, Start, VersionRecord};
use tablepro_keys::wrap::{Wrap, Wrapper, scope_key_target};

// This account at its current `av`, signing from this key device.
pub(crate) struct Signer<'a> {
    pub(crate) account: AccountId,
    pub(crate) av: Version,
    pub(crate) keys: &'a AccountKeys,
    pub(crate) key_device: KeyDeviceId,
}

impl Signer<'_> {
    fn wrapper(&self) -> Wrapper {
        Wrapper {
            account: self.account,
            av: self.av,
            key_device: self.key_device,
        }
    }
}

pub(crate) fn team_key(team: TeamId, version: Version) -> KeyRef {
    KeyRef {
        owner: team.0,
        purpose: KeyPurpose::Team,
        version,
    }
}

pub(crate) fn member_object(certificate: &AccountCertificate) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Member {
            account: certificate.account,
            av: certificate.av,
        },
        body: KeyBody::Member(AccountBody::of(certificate)),
    }
}

fn wrap_object(wrap: &Wrap) -> KeyObject {
    KeyObject {
        id: KeyRecordId::Wrap(wrap.target),
        body: KeyBody::Wrap(WrapBody::of(wrap)),
    }
}

// The wrap of `key` to a recipient at the `av` its certificate names, signed by the signer's ASK.
pub(crate) fn wrap_to(
    origin: &Origin,
    key: KeyRef,
    scope_key: &ScopeKey,
    recipient: &AccountCertificate,
    signer: &Signer<'_>,
) -> Result<KeyObject, KeysError> {
    let target = scope_key_target(key, recipient.account, recipient.av);
    let wrap = Wrap::seal_scope_key(
        origin,
        target,
        &recipient.aek,
        scope_key,
        signer.wrapper(),
        &signer.keys.ask,
    )?;
    Ok(wrap_object(&wrap))
}

pub(crate) struct NewVersion<'a> {
    pub(crate) team: TeamId,
    pub(crate) version: Version,
    pub(crate) start: Start,
    pub(crate) scope_key: &'a ScopeKey,
    // The version below, sealed in the ring: required with `start` 0, and with `start` 1 only when the signer still
    // holds it.
    pub(crate) previous: Option<&'a ScopeKey>,
    pub(crate) recipients: &'a [AccountCertificate],
}

// A team creation's or rotation's version objects: the version record, its ring, then a wrap to each recipient.
pub(crate) fn version_objects(
    origin: &Origin,
    plan: &NewVersion<'_>,
    signer: &Signer<'_>,
) -> Result<(VersionRecord, Vec<KeyObject>), KeysError> {
    let key = team_key(plan.team, plan.version);
    let record = VersionRecord::sign(
        origin,
        key,
        plan.start,
        plan.scope_key,
        signer.account,
        signer.av,
        &signer.keys.ask,
    )?;
    let mut objects = vec![KeyObject {
        id: KeyRecordId::Version(key),
        body: KeyBody::Version(VersionBody::of(&record)),
    }];
    match (plan.start, plan.previous) {
        (_, Some(previous)) => objects.push(KeyObject {
            id: KeyRecordId::Ring(key),
            body: KeyBody::Ring(Ring::seal(origin, key, plan.scope_key, previous)?),
        }),
        (Start::Next, None) => return Err(KeysError::Ring),
        (Start::Over, None) => {}
    }
    for recipient in plan.recipients {
        objects.push(wrap_to(origin, key, plan.scope_key, recipient, signer)?);
    }
    Ok((record, objects))
}

#[cfg(test)]
mod tests {
    use tablepro_keys::body::KeyObject;
    use tablepro_keys::cert::{AccountCertificate, CertKind};
    use tablepro_keys::encoding::{AccountId, KeyDeviceId, Origin, TeamId, Version};
    use tablepro_keys::keys::{AccountKeys, Ed25519Seed, ScopeKey};
    use tablepro_keys::scope_key::Start;
    use uuid::Uuid;

    use super::{NewVersion, Signer, version_objects};

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    fn certificate(account: AccountId, keys: &AccountKeys) -> AccountCertificate {
        AccountCertificate::sign(
            &origin(),
            account,
            Version::FIRST,
            CertKind::GenesisOrRotation,
            &Ed25519Seed::generate().unwrap(),
            keys.public().unwrap(),
            None,
        )
        .unwrap()
    }

    #[test]
    fn a_rotation_carries_its_record_its_ring_and_one_wrap_per_recipient_and_round_trips() {
        let team = TeamId(Uuid::from_u128(1));
        let me = AccountId(Uuid::from_u128(2));
        let keys = AccountKeys::generate().unwrap();
        let other = AccountKeys::generate().unwrap();
        let recipients = [
            certificate(me, &keys),
            certificate(AccountId(Uuid::from_u128(3)), &other),
        ];
        let signer = Signer {
            account: me,
            av: Version::FIRST,
            keys: &keys,
            key_device: KeyDeviceId(Uuid::from_u128(4)),
        };
        let (old, new) = (ScopeKey::generate().unwrap(), ScopeKey::generate().unwrap());
        let plan = NewVersion {
            team,
            version: Version::new(2).unwrap(),
            start: Start::Next,
            scope_key: &new,
            previous: Some(&old),
            recipients: &recipients,
        };

        let (record, objects) = version_objects(&origin(), &plan, &signer).unwrap();

        let kinds: Vec<&str> = objects.iter().map(|object| object.id.kind().name()).collect();
        assert_eq!(kinds, ["key.version", "key.ring", "key.wrap", "key.wrap"]);
        record.verify(&origin(), &keys.public().unwrap().ask).unwrap();
        for object in &objects {
            let parsed = KeyObject::parse(
                object.id.kind().name(),
                &object.id.to_wire(),
                object.fields_json().as_bytes(),
            )
            .unwrap();
            assert_eq!(&parsed, object);
        }
    }

    #[test]
    fn a_next_version_without_the_key_below_has_no_ring_to_seal() {
        let keys = AccountKeys::generate().unwrap();
        let signer = Signer {
            account: AccountId(Uuid::from_u128(2)),
            av: Version::FIRST,
            keys: &keys,
            key_device: KeyDeviceId(Uuid::from_u128(4)),
        };
        let key = ScopeKey::generate().unwrap();
        let plan = NewVersion {
            team: TeamId(Uuid::from_u128(1)),
            version: Version::new(2).unwrap(),
            start: Start::Next,
            scope_key: &key,
            previous: None,
            recipients: &[],
        };

        assert_eq!(
            version_objects(&origin(), &plan, &signer).unwrap_err().code(),
            "keys.ring"
        );
    }
}
