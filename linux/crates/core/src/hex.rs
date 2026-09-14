const DIGITS: &[u8; 16] = b"0123456789abcdef";

pub fn encode_lower(bytes: &[u8]) -> String {
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    encoded
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
}
