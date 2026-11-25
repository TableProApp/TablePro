use zeroize::Zeroizing;

use crate::KeysError;

// Crockford's alphabet, bits taken most significant first (RFC 4648 section 6 order).
pub const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";

pub fn encode(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(5) * 8);
    let mut buffer: u16 = 0;
    let mut bits = 0_u32;
    for byte in bytes {
        buffer = (buffer << 8) | u16::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            text.push(symbol(buffer >> bits));
            buffer &= (1 << bits) - 1;
        }
    }
    if bits > 0 {
        text.push(symbol(buffer << (5 - bits)));
    }
    text
}

fn symbol(value: u16) -> char {
    char::from(ALPHABET[usize::from(value & 0x1f)])
}

fn value(symbol: u8) -> Option<u16> {
    ALPHABET
        .iter()
        .position(|candidate| *candidate == symbol)
        .and_then(|index| u16::try_from(index).ok())
}

// Upper-case symbols only. A symbol count no byte length encodes to, or non-zero final bits,
// is refused.
// Wiped on drop, failures included, since it decodes the recovery key.
pub fn decode(text: &str) -> Result<Zeroizing<Vec<u8>>, KeysError> {
    let symbols = text.as_bytes();
    let total_bits = symbols.len() * 5;
    if total_bits % 8 >= 5 {
        return Err(KeysError::encoding("base32 symbol count encodes no byte length"));
    }
    let mut bytes = Zeroizing::new(Vec::with_capacity(total_bits / 8));
    let mut buffer: u16 = 0;
    let mut bits = 0_u32;
    for symbol in symbols {
        let value = value(*symbol).ok_or(KeysError::encoding("not a base32 symbol"))?;
        buffer = (buffer << 5) | value;
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            bytes.push(u8::try_from(buffer >> bits).map_err(|_| KeysError::encoding("base32"))?);
            buffer &= (1 << bits) - 1;
        }
    }
    if buffer != 0 {
        return Err(KeysError::encoding("non-zero final base32 bits"));
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{decode, encode};

    #[test]
    fn known_answers() {
        assert_eq!(encode(&[]), "");
        assert_eq!(encode(&[0xff]), "ZW");
        assert_eq!(encode(&[0, 0, 0, 0, 0]), "00000000");
        assert_eq!(encode(&[0xff; 5]), "ZZZZZZZZ");
        assert_eq!(decode("ZW").unwrap().as_slice(), [0xff]);
    }

    #[test]
    fn strict_decoding() {
        assert!(decode("ZZ").is_err(), "non-zero final bits");
        assert!(decode("Z").is_err(), "one symbol is no byte");
        assert!(decode("ZZZ").is_err(), "three symbols encode no byte length");
        assert!(decode("zw").is_err(), "lower case");
        assert!(decode("U0").is_err(), "U is not in the alphabet");
        assert!(decode("O0").is_err(), "O is read as 0 only by the recovery key reader");
    }

    proptest! {
        #[test]
        fn round_trips(bytes in proptest::collection::vec(any::<u8>(), 0..80)) {
            let decoded = decode(&encode(&bytes)).unwrap();
            prop_assert_eq!(decoded.as_slice(), bytes.as_slice());
        }

        #[test]
        fn whatever_decodes_encodes_back(text in "[0-9A-Z]{0,40}") {
            if let Ok(bytes) = decode(&text) {
                prop_assert_eq!(encode(&bytes), text);
            }
        }
    }
}
