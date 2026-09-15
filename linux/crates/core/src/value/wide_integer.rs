use std::fmt;
use std::str::FromStr;

use num_bigint::BigInt;
use thiserror::Error;

use crate::column::IntegerKind;

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

/// Built once: ten `BigInt` pairs constructed per call would dominate a
/// bulk insert's validation.
fn bounds(kind: IntegerKind) -> &'static (BigInt, BigInt) {
    use std::sync::OnceLock;

    static BOUNDS: OnceLock<[(BigInt, BigInt); 10]> = OnceLock::new();
    let table = BOUNDS.get_or_init(|| {
        [
            (BigInt::from(i8::MIN), BigInt::from(i8::MAX)),
            (BigInt::from(0), BigInt::from(u8::MAX)),
            (BigInt::from(i16::MIN), BigInt::from(i16::MAX)),
            (BigInt::from(0), BigInt::from(u16::MAX)),
            (BigInt::from(i32::MIN), BigInt::from(i32::MAX)),
            (BigInt::from(0), BigInt::from(u32::MAX)),
            (BigInt::from(i64::MIN), BigInt::from(i64::MAX)),
            (BigInt::from(0), BigInt::from(u64::MAX)),
            (BigInt::from(i128::MIN), BigInt::from(i128::MAX)),
            (BigInt::from(0), BigInt::from(u128::MAX)),
        ]
    });
    let index = match kind {
        IntegerKind::I8 => 0,
        IntegerKind::U8 => 1,
        IntegerKind::I16 => 2,
        IntegerKind::U16 => 3,
        IntegerKind::I32 => 4,
        IntegerKind::U32 => 5,
        IntegerKind::I64 => 6,
        IntegerKind::U64 => 7,
        IntegerKind::I128 => 8,
        IntegerKind::U128 => 9,
    };
    &table[index]
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

    #[test]
    fn wide_integer_fits_every_integer_kind() {
        let cases: [(IntegerKind, &str, &str); 10] = [
            (IntegerKind::I8, "-128", "127"),
            (IntegerKind::U8, "0", "255"),
            (IntegerKind::I16, "-32768", "32767"),
            (IntegerKind::U16, "0", "65535"),
            (IntegerKind::I32, "-2147483648", "2147483647"),
            (IntegerKind::U32, "0", "4294967295"),
            (IntegerKind::I64, "-9223372036854775808", "9223372036854775807"),
            (IntegerKind::U64, "0", "18446744073709551615"),
            (
                IntegerKind::I128,
                "-170141183460469231731687303715884105728",
                "170141183460469231731687303715884105727",
            ),
            (IntegerKind::U128, "0", "340282366920938463463374607431768211455"),
        ];

        for (kind, low, high) in cases {
            assert!(wide(low).fits(kind), "{kind:?} rejected its own minimum {low}");
            assert!(wide(high).fits(kind), "{kind:?} rejected its own maximum {high}");

            let below = format!("{}", wide(low).0 - 1);
            let above = format!("{}", wide(high).0 + 1);
            assert!(!wide(&below).fits(kind), "{kind:?} accepted {below}");
            assert!(!wide(&above).fits(kind), "{kind:?} accepted {above}");
        }
    }

    #[test]
    fn an_unsigned_kind_rejects_a_negative_value() {
        for kind in IntegerKind::ALL.into_iter().filter(|kind| !kind.is_signed()) {
            assert!(!wide("-1").fits(kind), "{kind:?} accepted -1");
        }
    }
}
