use std::fmt;
use std::str::FromStr;

use num_bigint::BigInt;
use thiserror::Error;

use crate::column::{IntegerKind, IntegerWidth};

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

    /// Whether the value fits the column it is headed for. The insert
    /// path checks this before binding, so an out-of-range value fails
    /// with the column named rather than as a driver error.
    pub fn fits(&self, kind: IntegerKind) -> bool {
        let (low, high) = bounds(kind);
        &self.0 >= low && &self.0 <= high
    }
}

/// Built once: fourteen `BigInt` pairs constructed per call would
/// dominate a bulk insert's validation.
fn bounds(kind: IntegerKind) -> &'static (BigInt, BigInt) {
    use std::sync::OnceLock;

    static BOUNDS: OnceLock<[[(BigInt, BigInt); 2]; 7]> = OnceLock::new();
    let table = BOUNDS.get_or_init(|| IntegerWidth::ALL.map(|width| [false, true].map(|signed| range(width, signed))));
    let width = match kind.width {
        IntegerWidth::W8 => 0,
        IntegerWidth::W16 => 1,
        IntegerWidth::W24 => 2,
        IntegerWidth::W32 => 3,
        IntegerWidth::W64 => 4,
        IntegerWidth::W128 => 5,
        IntegerWidth::W256 => 6,
    };
    &table[width][usize::from(kind.signed)]
}

fn range(width: IntegerWidth, signed: bool) -> (BigInt, BigInt) {
    let bits = width.bits();
    if signed {
        let half = BigInt::from(1) << (bits - 1);
        (-half.clone(), half - 1)
    } else {
        (BigInt::from(0), (BigInt::from(1) << bits) - 1)
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

#[cfg(test)]
mod fits_tests {
    use super::*;

    fn wide(text: &str) -> WideInteger {
        text.parse().expect("a valid integer")
    }

    fn kind(width: IntegerWidth, signed: bool) -> IntegerKind {
        IntegerKind { width, signed }
    }

    #[test]
    fn wide_integer_fits_integer_kind() {
        let cases = [
            (kind(IntegerWidth::W8, true), "-128", "127"),
            (kind(IntegerWidth::W8, false), "0", "255"),
            (kind(IntegerWidth::W16, true), "-32768", "32767"),
            (kind(IntegerWidth::W16, false), "0", "65535"),
            (kind(IntegerWidth::W24, true), "-8388608", "8388607"),
            (kind(IntegerWidth::W24, false), "0", "16777215"),
            (kind(IntegerWidth::W32, true), "-2147483648", "2147483647"),
            (kind(IntegerWidth::W32, false), "0", "4294967295"),
            (
                kind(IntegerWidth::W64, true),
                "-9223372036854775808",
                "9223372036854775807",
            ),
            (kind(IntegerWidth::W64, false), "0", "18446744073709551615"),
            (
                kind(IntegerWidth::W128, true),
                "-170141183460469231731687303715884105728",
                "170141183460469231731687303715884105727",
            ),
            (
                kind(IntegerWidth::W128, false),
                "0",
                "340282366920938463463374607431768211455",
            ),
            (
                kind(IntegerWidth::W256, true),
                "-57896044618658097711785492504343953926634992332820282019728792003956564819968",
                "57896044618658097711785492504343953926634992332820282019728792003956564819967",
            ),
            (
                kind(IntegerWidth::W256, false),
                "0",
                "115792089237316195423570985008687907853269984665640564039457584007913129639935",
            ),
        ];

        for (kind, low, high) in cases {
            assert!(wide(low).fits(kind), "{kind} rejected its own minimum {low}");
            assert!(wide(high).fits(kind), "{kind} rejected its own maximum {high}");

            let below = format!("{}", wide(low).0 - 1);
            let above = format!("{}", wide(high).0 + 1);
            assert!(!wide(&below).fits(kind), "{kind} accepted {below}");
            assert!(!wide(&above).fits(kind), "{kind} accepted {above}");
        }
    }

    #[test]
    fn an_unsigned_kind_rejects_a_negative_value() {
        for width in IntegerWidth::ALL {
            let unsigned = kind(width, false);
            assert!(!wide("-1").fits(unsigned), "{unsigned} accepted -1");
        }
    }
}
