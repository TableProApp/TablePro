use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;

use crate::KeysError;

// Canonical base64url without padding (RFC 4648 section 5). The engine refuses padding,
// characters outside the alphabet and non-zero pad bits.
pub fn encode(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn decode(text: &str) -> Result<Vec<u8>, KeysError> {
    URL_SAFE_NO_PAD
        .decode(text)
        .map_err(|_| KeysError::encoding("not canonical base64url"))
}

pub fn decode_exact<const N: usize>(text: &str) -> Result<[u8; N], KeysError> {
    let bytes = decode(text)?;
    <[u8; N]>::try_from(bytes.as_slice()).map_err(|_| KeysError::encoding("wrong byte length"))
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{decode, decode_exact, encode};

    #[test]
    fn non_canonical_forms_are_refused() {
        assert_eq!(decode("AQ").unwrap(), vec![1]);
        assert!(decode("AR").is_err(), "non-zero pad bits");
        assert!(decode("AQ==").is_err(), "padding");
        assert!(decode("A").is_err(), "a lone symbol");
        assert!(decode("A+").is_err(), "the standard alphabet");
        assert!(decode("A/").is_err());
        assert!(decode(" AQ").is_err());
        assert!(decode_exact::<2>("AQ").is_err());
        assert_eq!(decode_exact::<1>("AQ").unwrap(), [1]);
    }

    proptest! {
        #[test]
        fn encoding_round_trips(bytes in proptest::collection::vec(any::<u8>(), 0..200)) {
            prop_assert_eq!(decode(&encode(&bytes)).unwrap(), bytes);
        }

        #[test]
        fn whatever_decodes_encodes_back_to_the_same_text(text in "[A-Za-z0-9_-]{0,64}") {
            if let Ok(bytes) = decode(&text) {
                prop_assert_eq!(encode(&bytes), text);
            }
        }
    }
}
