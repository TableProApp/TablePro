// When a signer is one of a team version's holders (0056, Teams, Holders; 0054, `key_versions`): the holder pair's
// account, with its IK or one that IK reaches through endorsed replaces. An IK after an unendorsed change, as a reset
// makes, is another holder.

use tablepro_keys::cert::{AccountCertificate, IkChange};
use tablepro_keys::encoding::Origin;

use crate::api::state::Holder;

// `certificates` are the account's certificates the team holds, each verified under its own IK, ascending by `av`
// with one per `av`. The walk runs from the last certificate under the holder's IK up to the signer's, and needs every
// `av` between them: a missing one could be the unendorsed change that breaks the chain.
pub(crate) fn matches(
    origin: &Origin,
    holder: &Holder,
    signer: &AccountCertificate,
    certificates: &[AccountCertificate],
) -> bool {
    if holder.account != signer.account {
        return false;
    }
    if holder.ik == signer.ik {
        return true;
    }
    let Some(end) = certificates.iter().position(|certificate| certificate == signer) else {
        return false;
    };
    let Some(start) = certificates[..end]
        .iter()
        .rposition(|certificate| certificate.ik == holder.ik)
    else {
        return false;
    };
    certificates[start..=end].windows(2).all(|pair| match pair {
        [previous, next] => {
            next.account == holder.account
                && next.av.get() == previous.av.get() + 1
                && (next.ik == previous.ik || next.ik_change(origin, &previous.ik) == Ok(IkChange::Endorsed))
        }
        _ => false,
    })
}

#[cfg(test)]
mod tests {
    use tablepro_keys::cert::{AccountCertificate, CertKind};
    use tablepro_keys::encoding::{AccountId, Origin, Version};
    use tablepro_keys::keys::{AccountKeys, Ed25519Seed};
    use uuid::Uuid;

    use super::matches;
    use crate::api::state::Holder;

    fn origin() -> Origin {
        Origin::parse("https://sync.example.com").unwrap()
    }

    fn account() -> AccountId {
        AccountId(Uuid::from_u128(0x019a_6b2e_8f3c_7d41_b2a5_6c0e_9f14_d7b8))
    }

    fn seed(byte: u8) -> Ed25519Seed {
        Ed25519Seed::from_bytes([byte; 32])
    }

    fn certificate(av: u32, kind: CertKind, ik: &Ed25519Seed, previous: Option<&Ed25519Seed>) -> AccountCertificate {
        let keys = AccountKeys::generate().unwrap();
        AccountCertificate::sign(
            &origin(),
            account(),
            Version::new(av).unwrap(),
            kind,
            ik,
            keys.public().unwrap(),
            previous,
        )
        .unwrap()
    }

    fn holder(ik: &Ed25519Seed) -> Holder {
        Holder {
            account: account(),
            ik: ik.public().unwrap(),
        }
    }

    #[test]
    fn the_same_ik_matches_at_any_av_and_another_account_never_does() {
        let ik = seed(1);
        let later = certificate(5, CertKind::GenesisOrRotation, &ik, None);
        let other = Holder {
            account: AccountId(Uuid::from_u128(7)),
            ik: ik.public().unwrap(),
        };

        assert!(matches(&origin(), &holder(&ik), &later, &[]));
        assert!(!matches(&origin(), &other, &later, &[]));
    }

    #[test]
    fn endorsed_replaces_at_consecutive_avs_reach_the_signer() {
        let (first, second, third) = (seed(1), seed(2), seed(3));
        let chain = [
            certificate(1, CertKind::GenesisOrRotation, &first, None),
            certificate(2, CertKind::GenesisOrRotation, &first, None),
            certificate(3, CertKind::Replace, &second, Some(&first)),
            certificate(4, CertKind::Replace, &third, Some(&second)),
        ];

        assert!(matches(&origin(), &holder(&first), &chain[3], &chain));
        assert!(matches(&origin(), &holder(&second), &chain[3], &chain));
    }

    #[test]
    fn a_reset_breaks_the_chain_even_when_an_old_ik_endorses_past_it() {
        let (first, reset, attacker) = (seed(1), seed(2), seed(3));
        let chain = [
            certificate(1, CertKind::GenesisOrRotation, &first, None),
            certificate(2, CertKind::ResetKeepingKeys, &reset, None),
            certificate(3, CertKind::Replace, &attacker, Some(&first)),
        ];

        assert!(!matches(&origin(), &holder(&first), &chain[1], &chain));
        assert!(!matches(&origin(), &holder(&first), &chain[2], &chain));
    }

    #[test]
    fn a_missing_av_between_the_holder_and_the_signer_matches_nothing() {
        let (first, second) = (seed(1), seed(2));
        let chain = [
            certificate(1, CertKind::GenesisOrRotation, &first, None),
            certificate(3, CertKind::Replace, &second, Some(&first)),
        ];

        assert!(!matches(&origin(), &holder(&first), &chain[1], &chain));
    }

    #[test]
    fn an_endorsement_by_another_ik_is_no_replace() {
        let (first, second, stranger) = (seed(1), seed(2), seed(9));
        let chain = [
            certificate(1, CertKind::GenesisOrRotation, &first, None),
            certificate(2, CertKind::Replace, &second, Some(&stranger)),
        ];

        assert!(!matches(&origin(), &holder(&first), &chain[1], &chain));
    }

    #[test]
    fn a_signer_the_list_does_not_hold_matches_only_by_its_own_ik() {
        let (first, second) = (seed(1), seed(2));
        let chain = [certificate(1, CertKind::GenesisOrRotation, &first, None)];
        let outside = certificate(2, CertKind::Replace, &second, Some(&first));

        assert!(!matches(&origin(), &holder(&first), &outside, &chain));
    }
}
