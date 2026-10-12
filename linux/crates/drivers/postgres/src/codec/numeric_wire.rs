//! NUMERIC in its binary form, which neither postgres-types nor
//! postgres-protocol reads: a count of base-10000 digits, the weight of
//! the first one, a sign, the declared scale, then the digits.

use tablepro_core::value::{DecimalParseError, SqlDecimal};

use super::WireError;

const SIGN_POSITIVE: u16 = 0x0000;
const SIGN_NEGATIVE: u16 = 0x4000;
const SIGN_NAN: u16 = 0xC000;
const SIGN_POSITIVE_INFINITY: u16 = 0xD000;
const SIGN_NEGATIVE_INFINITY: u16 = 0xF000;
const HEADER_LEN: usize = 8;

/// A NUMERIC read back at the exact digits the server holds, its
/// declared scale and trailing zeros included.
pub(crate) fn numeric_from_sql(bytes: &[u8]) -> Result<SqlDecimal, WireError> {
    let header: [u8; HEADER_LEN] = bytes
        .get(..HEADER_LEN)
        .and_then(|header| header.try_into().ok())
        .ok_or(WireError::Malformed)?;
    let digit_count = usize::from(u16::from_be_bytes([header[0], header[1]]));
    let weight = i32::from(i16::from_be_bytes([header[2], header[3]]));
    let sign = u16::from_be_bytes([header[4], header[5]]);
    let scale = u16::from_be_bytes([header[6], header[7]]);
    match sign {
        SIGN_POSITIVE | SIGN_NEGATIVE => {}
        SIGN_NAN => return Ok(SqlDecimal::nan()),
        SIGN_POSITIVE_INFINITY => return Ok(SqlDecimal::infinity(false)),
        SIGN_NEGATIVE_INFINITY => return Ok(SqlDecimal::infinity(true)),
        _ => return Err(WireError::Malformed),
    }
    if bytes.len() != HEADER_LEN + digit_count * 2 {
        return Err(WireError::Malformed);
    }
    let digits: Vec<u16> = bytes[HEADER_LEN..]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_be_bytes(*pair))
        .collect();
    if digits.iter().any(|digit| *digit >= 10_000) {
        return Err(WireError::Malformed);
    }
    let coefficient = coefficient(&digits, weight, usize::from(scale));
    SqlDecimal::from_parts(sign == SIGN_NEGATIVE, &coefficient, u32::from(scale)).map_err(|error| match error {
        DecimalParseError::TooManyDigits { .. } | DecimalParseError::ExponentOutOfRange => WireError::OutOfRange,
        DecimalParseError::Empty | DecimalParseError::InvalidSyntax => WireError::Malformed,
    })
}

/// The decimal digits of the value with the point removed, `scale` of
/// them after it.
fn coefficient(digits: &[u16], weight: i32, scale: usize) -> String {
    let digit_at = |position: i32| -> u16 {
        usize::try_from(position)
            .ok()
            .and_then(|at| digits.get(at).copied())
            .unwrap_or(0)
    };
    let mut text = String::new();
    for position in 0..=weight.max(-1) {
        text.push_str(&format!("{:04}", digit_at(position)));
    }
    let mut fraction = String::with_capacity(scale + 4);
    let mut position = weight + 1;
    while fraction.len() < scale {
        let digit = if position < 0 { 0 } else { digit_at(position) };
        fraction.push_str(&format!("{digit:04}"));
        position += 1;
    }
    fraction.truncate(scale);
    text.push_str(&fraction);
    if text.is_empty() {
        text.push('0');
    }
    text
}

#[cfg(test)]
pub(crate) fn numeric_bytes(weight: i16, sign: u16, scale: u16, digits: &[u16]) -> Vec<u8> {
    let mut bytes = Vec::new();
    let count = u16::try_from(digits.len()).unwrap_or(0);
    bytes.extend_from_slice(&count.to_be_bytes());
    bytes.extend_from_slice(&weight.to_be_bytes());
    bytes.extend_from_slice(&sign.to_be_bytes());
    bytes.extend_from_slice(&scale.to_be_bytes());
    for digit in digits {
        bytes.extend_from_slice(&digit.to_be_bytes());
    }
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(weight: i16, sign: u16, scale: u16, digits: &[u16]) -> String {
        numeric_from_sql(&numeric_bytes(weight, sign, scale, digits))
            .expect("a well-formed numeric")
            .to_string()
    }

    #[test]
    fn numeric_wire_round_trips() {
        assert_eq!(read(1, SIGN_POSITIVE, 5, &[1, 2345, 6789, 0]), "12345.67890");
        assert_eq!(read(-2, SIGN_POSITIVE, 8, &[1234]), "0.00001234");
        assert_eq!(read(0, SIGN_NEGATIVE, 2, &[42, 5000]), "-42.50");
        assert_eq!(read(0, SIGN_POSITIVE, 0, &[]), "0");
        assert_eq!(read(1, SIGN_POSITIVE, 0, &[7]), "70000");
        assert_eq!(
            read(
                7,
                SIGN_POSITIVE,
                9,
                &[12, 3456, 7890, 1234, 5678, 9012, 3456, 7890, 1234, 5678, 9000],
            ),
            "123456789012345678901234567890.123456789"
        );
    }

    #[test]
    fn a_thousand_digit_numeric_survives() {
        let digits = vec![9999u16; 250];
        let text = read(249, SIGN_POSITIVE, 0, &digits);

        assert_eq!(text.len(), 1000);
        assert!(text.bytes().all(|digit| digit == b'9'));
    }

    #[test]
    fn numeric_carries_nan_and_the_infinities_as_decimals() {
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, SIGN_NAN, 0, &[])),
            Ok(SqlDecimal::nan())
        );
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, SIGN_POSITIVE_INFINITY, 0, &[])),
            Ok(SqlDecimal::infinity(false))
        );
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, SIGN_NEGATIVE_INFINITY, 0, &[])),
            Ok(SqlDecimal::infinity(true))
        );
    }

    #[test]
    fn numeric_wire_malformed_is_undecodable_not_panic() {
        assert_eq!(numeric_from_sql(&[0, 1, 0, 0]), Err(WireError::Malformed));
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, SIGN_POSITIVE, 0, &[1])[..9]),
            Err(WireError::Malformed)
        );
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, 0x1234, 0, &[1])),
            Err(WireError::Malformed)
        );
        assert_eq!(
            numeric_from_sql(&numeric_bytes(0, SIGN_POSITIVE, 0, &[10_000])),
            Err(WireError::Malformed)
        );
        assert_eq!(
            numeric_from_sql(&numeric_bytes(i16::MIN, SIGN_POSITIVE, u16::MAX, &[1])),
            Err(WireError::OutOfRange)
        );
    }
}
