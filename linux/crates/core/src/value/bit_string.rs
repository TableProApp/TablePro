use std::fmt;

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BitString {
    bit_len: u32,
    bytes: Box<[u8]>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum BitStringError {
    #[error("{bit_len} bits need {expected} bytes, got {actual}")]
    LengthMismatch {
        bit_len: u32,
        expected: usize,
        actual: usize,
    },
}

impl BitString {
    pub fn from_bytes(bit_len: u32, bytes: Vec<u8>) -> Result<Self, BitStringError> {
        let expected = byte_len(bit_len);
        if bytes.len() != expected {
            return Err(BitStringError::LengthMismatch {
                bit_len,
                expected,
                actual: bytes.len(),
            });
        }
        let mut bytes = bytes.into_boxed_slice();
        let padding = (8 - bit_len % 8) % 8;
        if let Some(last) = bytes.last_mut() {
            *last &= 0xffu8 << padding;
        }
        Ok(Self { bit_len, bytes })
    }

    pub fn from_u64(bits: u64, bit_len: u32) -> Self {
        let mut bytes = vec![0u8; byte_len(bit_len)].into_boxed_slice();
        for position in 0..bit_len {
            let shift = bit_len - 1 - position;
            let bit = if shift < 64 { (bits >> shift) & 1 } else { 0 };
            if bit == 1
                && let Some(byte) = bytes.get_mut((position / 8) as usize)
            {
                *byte |= 0x80 >> (position % 8);
            }
        }
        Self { bit_len, bytes }
    }

    pub fn to_u64(&self) -> Option<u64> {
        if self.bit_len > 64 {
            return None;
        }
        Some((0..self.bit_len).fold(0u64, |value, position| (value << 1) | u64::from(self.bit(position))))
    }

    pub fn bit_len(&self) -> u32 {
        self.bit_len
    }

    fn bit(&self, position: u32) -> u8 {
        self.bytes
            .get((position / 8) as usize)
            .map_or(0, |byte| (byte >> (7 - position % 8)) & 1)
    }
}

impl fmt::Display for BitString {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for position in 0..self.bit_len {
            f.write_str(if self.bit(position) == 1 { "1" } else { "0" })?;
        }
        Ok(())
    }
}

fn byte_len(bit_len: u32) -> usize {
    bit_len.div_ceil(8) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bit_string_length_mismatch() {
        assert_eq!(
            BitString::from_bytes(10, vec![0xff]),
            Err(BitStringError::LengthMismatch {
                bit_len: 10,
                expected: 2,
                actual: 1
            })
        );
        let masked = BitString::from_bytes(10, vec![0xff, 0xff]).unwrap();
        assert_eq!(masked.to_string(), "1111111111");
        assert_eq!(masked, BitString::from_bytes(10, vec![0xff, 0xc0]).unwrap());
    }

    #[test]
    fn converts_between_integers_and_text() {
        let bits = BitString::from_u64(0b0101, 4);
        assert_eq!(bits.to_string(), "0101");
        assert_eq!(bits.to_u64(), Some(5));
        assert_eq!(BitString::from_u64(u64::MAX, 64).to_u64(), Some(u64::MAX));
        assert_eq!(BitString::from_u64(1, 65).to_u64(), None);
    }
}
