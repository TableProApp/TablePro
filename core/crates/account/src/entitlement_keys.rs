use std::collections::HashMap;

use aws_lc_rs::digest;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use jsonwebtoken::DecodingKey;

// (kid, RFC 8037 `x`) as tablepro-cloud's operations.md, Production entitlement key, publishes them.
// Rotation order is in api.md, Entitlement token.
const RELEASE_KEYS: &[(&str, &str)] = &[(
    "wLT5qcqj3sxp-0NB_21spMxboiyTAW1BwmsXhhgA-XA",
    "0ozC4TYUqinr-4JfyglENxCUuxFf-90uni0M0sCMR9g",
)];

#[derive(Clone)]
pub struct EntitlementKeys {
    keys: HashMap<String, DecodingKey>,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("{x:?} is not an Ed25519 public key in base64url")]
pub struct KeyError {
    x: String,
}

impl EntitlementKeys {
    pub fn release() -> Self {
        let keys = RELEASE_KEYS.iter().filter_map(|(_, x)| keyed(x).ok()).collect();
        Self { keys }
    }

    pub fn from_public_keys<'a>(xs: impl IntoIterator<Item = &'a str>) -> Result<Self, KeyError> {
        let keys = xs.into_iter().map(keyed).collect::<Result<_, _>>()?;
        Ok(Self { keys })
    }

    pub(crate) fn get(&self, kid: &str) -> Option<&DecodingKey> {
        self.keys.get(kid)
    }

    pub fn kids(&self) -> impl Iterator<Item = &str> {
        self.keys.keys().map(String::as_str)
    }
}

impl std::fmt::Debug for EntitlementKeys {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_list().entries(self.keys.keys()).finish()
    }
}

fn keyed(x: &str) -> Result<(String, DecodingKey), KeyError> {
    let error = || KeyError { x: x.to_owned() };
    let raw = URL_SAFE_NO_PAD.decode(x).map_err(|_| error())?;
    if raw.len() != 32 {
        return Err(error());
    }
    let key = DecodingKey::from_ed_components(x).map_err(|_| error())?;
    Ok((thumbprint(x), key))
}

// RFC 7638. A base64url `x` needs no JSON escaping.
fn thumbprint(x: &str) -> String {
    let members = format!(r#"{{"crv":"Ed25519","kty":"OKP","x":"{x}"}}"#);
    URL_SAFE_NO_PAD.encode(digest::digest(&digest::SHA256, members.as_bytes()))
}

#[cfg(test)]
mod tests {
    use super::*;

    const RFC_8037_X: &str = "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo";

    #[test]
    fn the_kid_is_the_rfc_7638_thumbprint() {
        let keys = EntitlementKeys::from_public_keys([RFC_8037_X]).expect("the RFC 8037 key");

        assert_eq!(
            keys.kids().collect::<Vec<_>>(),
            ["kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k"]
        );
    }

    #[test]
    fn what_is_not_a_32_byte_key_is_refused() {
        for x in ["", "not base64!", "AAAA", &format!("{RFC_8037_X}AA")] {
            assert!(EntitlementKeys::from_public_keys([x]).is_err(), "{x:?}");
        }
    }

    #[test]
    fn each_release_kid_is_the_rfc_7638_thumbprint_of_its_key() {
        let keys = EntitlementKeys::release();
        let mut kids: Vec<&str> = keys.kids().collect();
        let mut published: Vec<&str> = RELEASE_KEYS.iter().map(|(kid, _)| *kid).collect();

        assert!(
            !published.is_empty(),
            "a release build would verify no production entitlement"
        );
        for (kid, x) in RELEASE_KEYS {
            assert_eq!(thumbprint(x), *kid, "{x}");
        }
        kids.sort_unstable();
        published.sort_unstable();
        assert_eq!(kids, published);
    }
}
