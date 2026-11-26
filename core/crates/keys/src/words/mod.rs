mod eff_large;

use eff_large::EFF_LARGE;

pub const WORD_COUNT: u16 = 7776;

// SHA-256 of eff_large_wordlist.txt as the EFF publishes it, CC BY 3.0 US:
// https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt
pub const EFF_LARGE_SHA256: &str = "addd35536511597a02fa0a9ff1e5284677b8883b83e986e43f15a3db996b903e";

// `digit[j] = floor(x / 7776^j) mod 7776`, with x the digest read as a big-endian integer.
pub fn word_indexes(digest: &[u8; 32], count: usize) -> Vec<u16> {
    let mut x = *digest;
    let mut digits = Vec::with_capacity(count);
    for _ in 0..count {
        let mut remainder: u32 = 0;
        for byte in &mut x {
            let current = (remainder << 8) | u32::from(*byte);
            // current < 7776 * 256, so the quotient fits a byte.
            *byte = u8::try_from(current / u32::from(WORD_COUNT)).unwrap_or(u8::MAX);
            remainder = current % u32::from(WORD_COUNT);
        }
        digits.push(u16::try_from(remainder).unwrap_or(0));
    }
    digits
}

pub fn word(index: u16) -> &'static str {
    EFF_LARGE[usize::from(index % WORD_COUNT)]
}

// Words 0 to count-1 of a digest (ADR 0056, Encoding).
pub fn words(digest: &[u8; 32], count: usize) -> Vec<&'static str> {
    word_indexes(digest, count).into_iter().map(word).collect()
}

#[cfg(test)]
mod tests {
    use aws_lc_rs::digest::{SHA256, digest};

    use super::{EFF_LARGE, EFF_LARGE_SHA256, word, word_indexes, words};

    const LIST: &str = include_str!("eff_large_wordlist.txt");

    #[test]
    fn the_list_is_the_pinned_file() {
        assert_eq!(hex::encode(digest(&SHA256, LIST.as_bytes())), EFF_LARGE_SHA256);
    }

    #[test]
    fn the_table_is_the_list_in_dice_order() {
        let mut lines = LIST.lines();
        for (index, expected) in EFF_LARGE.iter().enumerate() {
            let mut dice = String::new();
            let mut rest = index;
            for _ in 0..5 {
                dice.insert(0, char::from(b'1' + u8::try_from(rest % 6).unwrap()));
                rest /= 6;
            }
            assert_eq!(lines.next().unwrap(), format!("{dice}\t{expected}"));
        }
        assert_eq!(lines.next(), None);
        assert_eq!(word(0), "abacus");
        assert_eq!(word(7775), "zoom");
    }

    #[test]
    fn digits_are_base_7776_from_the_least_significant() {
        assert_eq!(word_indexes(&[0; 32], 3), vec![0, 0, 0]);
        let mut digest = [0_u8; 32];
        digest[30] = 0x1e;
        digest[31] = 0x5f;
        assert_eq!(word_indexes(&digest, 2), vec![7775, 0]);
        digest[31] = 0x60;
        assert_eq!(word_indexes(&digest, 2), vec![0, 1]);
        assert_eq!(words(&[0xff; 32], 6).len(), 6);
    }
}
