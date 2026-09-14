use std::fmt;
use std::str::FromStr;

use num_bigint::BigInt;
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct WideInteger(BigInt);

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum WideIntegerParseError {
    #[error("the integer is empty")]
    Empty,
    #[error("the integer is longer than {max} characters")]
    TooLong { max: usize },
    #[error("the integer is not a plain decimal number")]
    InvalidSyntax,
}

impl WideInteger {
    pub const MAX_TEXT_LEN: usize = 78;

    pub fn from_i128(value: i128) -> Self {
        Self(BigInt::from(value))
    }

    pub fn from_u128(value: u128) -> Self {
        Self(BigInt::from(value))
    }

    pub fn to_i128(&self) -> Option<i128> {
        i128::try_from(&self.0).ok()
    }

    pub fn to_u128(&self) -> Option<u128> {
        u128::try_from(&self.0).ok()
    }
}

impl FromStr for WideInteger {
    type Err = WideIntegerParseError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        if text.is_empty() {
            return Err(WideIntegerParseError::Empty);
        }
        if text.len() > Self::MAX_TEXT_LEN {
            return Err(WideIntegerParseError::TooLong {
                max: Self::MAX_TEXT_LEN,
            });
        }
        let digits = text.strip_prefix('-').unwrap_or(text);
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return Err(WideIntegerParseError::InvalidSyntax);
        }
        BigInt::from_str(text)
            .map(Self)
            .map_err(|_| WideIntegerParseError::InvalidSyntax)
    }
}

impl fmt::Display for WideInteger {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const UINT256_MAX: &str = "115792089237316195423570985008687907853269984665640564039457584007913129639935";
    const INT256_MIN: &str = "-57896044618658097711785492504343953926634992332820282019728792003956564819968";

    #[test]
    fn wide_integer_grammar() {
        for rejected in ["+1", "1_000", "--1", "-", " 1", "1e3"] {
            assert_eq!(
                rejected.parse::<WideInteger>(),
                Err(WideIntegerParseError::InvalidSyntax),
                "{rejected:?}"
            );
        }
        assert_eq!("".parse::<WideInteger>(), Err(WideIntegerParseError::Empty));
        assert_eq!(
            "1".repeat(79).parse::<WideInteger>(),
            Err(WideIntegerParseError::TooLong { max: 78 })
        );
        assert_eq!("007".parse::<WideInteger>().unwrap().to_string(), "7");
        assert_eq!("-0".parse::<WideInteger>().unwrap().to_string(), "0");
        assert_eq!(UINT256_MAX.parse::<WideInteger>().unwrap().to_string(), UINT256_MAX);
        assert_eq!(INT256_MIN.parse::<WideInteger>().unwrap().to_string(), INT256_MIN);
    }

    #[test]
    fn converts_to_and_from_128_bit_integers() {
        assert_eq!(WideInteger::from_i128(i128::MIN).to_i128(), Some(i128::MIN));
        assert_eq!(WideInteger::from_u128(u128::MAX).to_u128(), Some(u128::MAX));
        assert_eq!(WideInteger::from_u128(u128::MAX).to_i128(), None);
        assert_eq!(WideInteger::from_i128(-1).to_u128(), None);
    }
}
