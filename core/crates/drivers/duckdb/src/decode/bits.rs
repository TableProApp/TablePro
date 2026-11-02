use tablepro_core::value::BitString;

/// A BIT as DuckDB stores it: a byte that says how many bits of the next
/// byte are padding, then the bits, first bit highest.
pub(crate) fn bit_string(stored: &[u8]) -> Option<BitString> {
    let (&padding, data) = stored.split_first()?;
    if padding > 7 || (data.is_empty() && padding != 0) {
        return None;
    }
    let padding = u32::from(padding);
    let bit_len = u32::try_from(data.len()).ok()?.checked_mul(8)?.checked_sub(padding)?;
    let mut packed = vec![0u8; usize::try_from(bit_len.div_ceil(8)).ok()?];
    for index in 0..bit_len {
        let source = index + padding;
        let byte = data.get(usize::try_from(source / 8).ok()?)?;
        if byte & (0x80 >> (source % 8)) != 0 {
            let target = packed.get_mut(usize::try_from(index / 8).ok()?)?;
            *target |= 0x80 >> (index % 8);
        }
    }
    BitString::from_bytes(bit_len, packed).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn padding_bits_are_dropped_from_the_front() {
        // '10101': three bits of padding, then 10101.
        let bits = bit_string(&[3, 0b1111_0101]).unwrap();

        assert_eq!(bits.to_string(), "10101");
        assert_eq!(bits.bit_len(), 5);
    }

    #[test]
    fn a_bit_string_can_span_bytes() {
        let bits = bit_string(&[6, 0b1111_1110, 0b1010_1010]).unwrap();

        assert_eq!(bits.to_string(), "1010101010");
    }

    #[test]
    fn a_malformed_bit_string_is_refused() {
        assert_eq!(bit_string(&[]), None);
        assert_eq!(bit_string(&[9, 0]), None);
    }
}
