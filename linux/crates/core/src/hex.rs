const DIGITS: &[u8; 16] = b"0123456789abcdef";

pub fn encode_lower(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    encoded
}

/// Hex digits of either case back into bytes. `None` for an odd count
/// or anything that is not a hex digit.
pub fn decode(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    text.as_bytes()
        .chunks(2)
        .map(|pair| {
            let high = char::from(*pair.first()?).to_digit(16)?;
            let low = char::from(*pair.get(1)?).to_digit(16)?;
            u8::try_from((high << 4) | low).ok()
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_encode_lower_golden() {
        assert_eq!(encode_lower(&[]), "");
        assert_eq!(encode_lower(&[0x00, 0x0f, 0xa5, 0xff]), "000fa5ff");
        assert_eq!(encode_lower(b"TablePro"), "5461626c6550726f");
    }

    #[test]
    fn decode_reads_back_what_encode_wrote_in_either_case() {
        let bytes = [0x00, 0x0f, 0xa5, 0xff];
        assert_eq!(decode(&encode_lower(&bytes)), Some(bytes.to_vec()));
        assert_eq!(decode("A5fF"), Some(vec![0xa5, 0xff]));
        assert_eq!(decode(""), Some(Vec::new()));
    }

    #[test]
    fn decode_refuses_an_odd_count_and_other_characters() {
        assert_eq!(decode("abc"), None);
        assert_eq!(decode("zz"), None);
        assert_eq!(decode("+1"), None);
        assert_eq!(decode("é1"), None);
    }
}
