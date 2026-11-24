use std::collections::{HashMap, HashSet};

use jsonwebtoken::DecodingKey;

use crate::entitlement_keys::{KeyError, keyed};

// (kid, RFC 8037 `x`) of the license keys, current then next, from the public halves of the two KMS keys (core ADR
// 0044, Key custody). Until they are made, a release build trusts no company server.
const RELEASE_KEYS: &[(&str, &str)] = &[];
// kids no build trusts any more, shipped with updates.
const REVOKED_KIDS: &[&str] = &[];

// Kept apart from the entitlement keys: a license key never signs an entitlement, nor one the other.
#[derive(Clone)]
pub struct LicenseKeys {
    keys: HashMap<String, DecodingKey>,
    revoked: HashSet<String>,
}

impl LicenseKeys {
    pub fn release() -> Self {
        Self {
            keys: RELEASE_KEYS.iter().filter_map(|(_, x)| keyed(x).ok()).collect(),
            revoked: REVOKED_KIDS.iter().map(|kid| (*kid).to_owned()).collect(),
        }
    }

    // A development build's or a test's keys, with the release build's revocations.
    pub fn from_public_keys<'a>(xs: impl IntoIterator<Item = &'a str>) -> Result<Self, KeyError> {
        Ok(Self {
            keys: xs.into_iter().map(keyed).collect::<Result<_, _>>()?,
            revoked: REVOKED_KIDS.iter().map(|kid| (*kid).to_owned()).collect(),
        })
    }

    #[cfg(test)]
    pub(crate) fn revoking(mut self, kid: &str) -> Self {
        self.revoked.insert(kid.to_owned());
        self
    }

    pub(crate) fn get(&self, kid: &str) -> Option<&DecodingKey> {
        self.keys.get(kid)
    }

    pub(crate) fn is_revoked(&self, kid: &str) -> bool {
        self.revoked.contains(kid)
    }

    pub fn kids(&self) -> impl Iterator<Item = &str> {
        self.keys.keys().map(String::as_str)
    }
}

impl Default for LicenseKeys {
    fn default() -> Self {
        Self::release()
    }
}

impl std::fmt::Debug for LicenseKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LicenseKeys")
            .field("kids", &self.keys.keys().collect::<Vec<_>>())
            .field("revoked", &self.revoked)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::entitlement_keys::thumbprint;

    #[test]
    fn each_release_kid_is_the_rfc_7638_thumbprint_of_its_key_and_none_is_revoked() {
        let keys = LicenseKeys::release();

        assert!(RELEASE_KEYS.len() <= 2, "a build carries the current and the next key");
        for (kid, x) in RELEASE_KEYS {
            assert_eq!(thumbprint(x), *kid, "{x}");
            assert!(!REVOKED_KIDS.contains(kid), "{kid}");
            assert!(keys.get(kid).is_some(), "{kid}");
        }
        assert_eq!(keys.kids().count(), RELEASE_KEYS.len());
    }

    #[test]
    fn a_test_key_is_kept_by_its_thumbprint() {
        let keys = LicenseKeys::from_public_keys([crate::fakes::PUBLIC_X]).expect("the RFC 8037 key");

        assert!(keys.get(crate::fakes::KID).is_some());
        assert!(!keys.is_revoked(crate::fakes::KID));
        assert!(keys.clone().revoking(crate::fakes::KID).is_revoked(crate::fakes::KID));
        assert!(LicenseKeys::from_public_keys(["not a key"]).is_err());
    }
}
