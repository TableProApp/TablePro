use zeroize::Zeroizing;

use crate::KeysError;

const STEPS: [usize; 7] = [64, 128, 256, 512, 1024, 2048, 4096];
const TOP: usize = 4096;

// P(n): the smallest step at least n + 1, and past 4,096 the next multiple of 4,096.
pub fn padded_len(n: usize) -> Result<usize, KeysError> {
    let needed = n
        .checked_add(1)
        .ok_or(KeysError::encoding("plaintext too long to pad"))?;
    if let Some(step) = STEPS.iter().find(|step| **step >= needed) {
        return Ok(*step);
    }
    needed
        .div_ceil(TOP)
        .checked_mul(TOP)
        .ok_or(KeysError::encoding("plaintext too long to pad"))
}

pub fn on_scale(len: usize) -> bool {
    STEPS.contains(&len) || (len > TOP && len.is_multiple_of(TOP))
}

// ISO/IEC 7816-4 padding: 0x80, then zeros up to P(n).
pub fn pad(plaintext: &[u8]) -> Result<Zeroizing<Vec<u8>>, KeysError> {
    let len = padded_len(plaintext.len())?;
    let mut padded = Zeroizing::new(Vec::with_capacity(len));
    padded.extend_from_slice(plaintext);
    padded.push(0x80);
    padded.resize(len, 0);
    Ok(padded)
}

// Read only after the AEAD opened (RFC 9180 section 9.7.6).
pub fn unpad(padded: &[u8]) -> Result<&[u8], KeysError> {
    if !on_scale(padded.len()) {
        return Err(KeysError::encoding("padded length is off the scale"));
    }
    let end = padded
        .iter()
        .rposition(|byte| *byte != 0)
        .ok_or(KeysError::encoding("padding has no 0x80"))?;
    if padded[end] != 0x80 {
        return Err(KeysError::encoding("padding has no 0x80, or a non-zero byte after it"));
    }
    Ok(&padded[..end])
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::{pad, padded_len, unpad};

    #[test]
    fn the_scale() {
        for (n, expected) in [
            (0, 64),
            (63, 64),
            (64, 128),
            (127, 128),
            (128, 256),
            (255, 256),
            (256, 512),
            (511, 512),
            (512, 1024),
            (1023, 1024),
            (1024, 2048),
            (2047, 2048),
            (2048, 4096),
            (4095, 4096),
            (4096, 8192),
            (8191, 8192),
            (8192, 12_288),
        ] {
            assert_eq!(padded_len(n).unwrap(), expected, "n = {n}");
        }
        assert!(padded_len(usize::MAX).is_err());
    }

    #[test]
    fn refusals() {
        assert!(unpad(&[0; 64]).is_err(), "no 0x80");
        let mut padded = vec![0_u8; 64];
        padded[10] = 0x80;
        padded[20] = 1;
        assert!(unpad(&padded).is_err(), "a non-zero byte after 0x80");
        let mut off_scale = vec![0_u8; 65];
        off_scale[0] = 0x80;
        assert!(unpad(&off_scale).is_err());
        let mut not_multiple = vec![0_u8; 4096 + 64];
        not_multiple[0] = 0x80;
        assert!(unpad(&not_multiple).is_err());
        assert!(unpad(&[]).is_err());
    }

    proptest! {
        #[test]
        fn round_trips(plaintext in proptest::collection::vec(any::<u8>(), 0..9000)) {
            let padded = pad(&plaintext).unwrap();
            prop_assert_eq!(padded.len(), padded_len(plaintext.len()).unwrap());
            prop_assert_eq!(unpad(&padded).unwrap(), plaintext.as_slice());
        }
    }
}
