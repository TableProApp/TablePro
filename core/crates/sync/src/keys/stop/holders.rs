// Whether an account's certificate at one `av` is still the holder a device accepted under an earlier IK (0054,
// `key_versions.holders`): its IK is the accepted one, or one reachable from it through verified replace
// endorsements, with no reset between. A reset's new IK is another holder, even when it names the same account.

use std::collections::BTreeMap;

use tablepro_keys::cert::{AccountCertificate, CertKind};
use tablepro_keys::encoding::{Origin, Version};
use tablepro_keys::keys::Ed25519Public;

use crate::api::state::KeyPinRow;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Chain {
    Matches,
    Breaks,
    // A certificate on the way, or one under the accepted IK, has not arrived.
    Missing,
}

pub(crate) fn same_holder(
    origin: &Origin,
    accepted: &Ed25519Public,
    certificates: &BTreeMap<Version, AccountCertificate>,
    at: Version,
) -> Chain {
    if !certificates.contains_key(&at) {
        return Chain::Missing;
    }
    // From the earliest certificate under the accepted IK, so a reset anywhere after it breaks the chain. With none
    // held, the chain cannot be judged yet.
    let Some((&from, first)) = certificates
        .range(..=at)
        .find(|(_, certificate)| certificate.ik == *accepted)
    else {
        return Chain::Missing;
    };
    if first.verify(origin).is_err() {
        return Chain::Breaks;
    }
    let mut previous = first;
    for number in from.get() + 1..=at.get() {
        let Some(certificate) = Version::new(number).ok().and_then(|av| certificates.get(&av)) else {
            return Chain::Missing;
        };
        let reset = matches!(certificate.kind, CertKind::ResetKeepingKeys | CertKind::ResetEmpty);
        if reset || certificate.ik_change(origin, &previous.ik).is_err() {
            return Chain::Breaks;
        }
        previous = certificate;
    }
    Chain::Matches
}

// The newest `av` the device knows for an account: its pin's, or a certificate it holds, whichever is higher. The
// certificates are the ones that verify under their own IK, an unendorsed one included, so a wrap signed under an
// older `av` after a reset never advances. One under an IK the pin saw replaced never counts as the newest (0056,
// Rollback): an old recovery key cannot raise the bar.
pub(crate) fn newest_known(certificates: &BTreeMap<Version, AccountCertificate>, pin: &KeyPinRow) -> Version {
    newest_current(certificates, pin).map_or(pin.av, |held| held.max(pin.av))
}

pub(crate) fn newest_current(certificates: &BTreeMap<Version, AccountCertificate>, pin: &KeyPinRow) -> Option<Version> {
    certificates
        .iter()
        .rev()
        .find(|(_, certificate)| !pin.replaced.contains(&certificate.ik))
        .map(|(av, _)| *av)
}
