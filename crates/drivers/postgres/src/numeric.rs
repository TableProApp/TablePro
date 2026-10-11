use tablepro_core::Value;

pub(crate) fn decode_binary(bytes: &[u8]) -> Option<Value> {
    let header = bytes.get(..8)?;
    let count = usize::from(u16::from_be_bytes([header[0], header[1]]));
    let weight = i32::from(i16::from_be_bytes([header[2], header[3]]));
    let sign = u16::from_be_bytes([header[4], header[5]]);
    let scale = usize::from(u16::from_be_bytes([header[6], header[7]]));
    if bytes.len() != 8 + count * 2 || scale > 0x3fff {
        return None;
    }
    if count == 0 {
        match sign {
            0xc000 => return Some(Value::Text("NaN".into())),
            0xd000 => return Some(Value::Text("Infinity".into())),
            0xf000 => return Some(Value::Text("-Infinity".into())),
            _ => {}
        }
    }
    if !matches!(sign, 0 | 0x4000) {
        return None;
    }
    let digits = bytes[8..]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_be_bytes([pair[0], pair[1]]))
        .collect::<Vec<_>>();
    if !valid_digits(&digits, weight, scale) {
        return None;
    }
    decode_text(&render_digits(&digits, weight, scale, sign == 0x4000))
}

fn valid_digits(digits: &[u16], weight: i32, scale: usize) -> bool {
    let fractional_groups = scale.div_ceil(4) as i32;
    digits.iter().enumerate().all(|(index, &digit)| {
        let exponent = weight - index as i32;
        if digit >= 10_000 || (exponent < -fractional_groups && digit != 0) {
            return false;
        }
        let partial = scale % 4;
        exponent != -fractional_groups || partial == 0 || digit % 10_u16.pow((4 - partial) as u32) == 0
    })
}

fn digit_at(digits: &[u16], weight: i32, exponent: i32) -> u16 {
    usize::try_from(weight - exponent)
        .ok()
        .and_then(|index| digits.get(index))
        .copied()
        .unwrap_or(0)
}

fn render_digits(digits: &[u16], weight: i32, scale: usize, negative: bool) -> String {
    let mut integer = String::new();
    for exponent in (0..=weight).rev() {
        integer.push_str(&format!("{:04}", digit_at(digits, weight, exponent)));
    }
    let integer = integer.trim_start_matches('0');
    let mut result = String::new();
    if negative && digits.iter().any(|digit| *digit != 0) {
        result.push('-');
    }
    result.push_str(if integer.is_empty() { "0" } else { integer });
    if scale > 0 {
        result.push('.');
        let end = result.len() + scale;
        for index in 1..=scale.div_ceil(4) {
            result.push_str(&format!("{:04}", digit_at(digits, weight, -(index as i32))));
        }
        result.truncate(end);
    }
    result
}

pub(crate) fn decode_text(text: &str) -> Option<Value> {
    if matches!(text, "NaN" | "Infinity" | "-Infinity") {
        return Some(Value::Text(text.into()));
    }
    let unsigned = text.strip_prefix('-').unwrap_or(text);
    let (integer, fraction) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    if integer.is_empty()
        || !integer.bytes().all(|byte| byte.is_ascii_digit())
        || !fraction.bytes().all(|byte| byte.is_ascii_digit())
        || (unsigned.contains('.') && fraction.is_empty())
    {
        return None;
    }
    match rust_decimal::Decimal::from_str_exact(text) {
        Ok(value) if value.to_string() == text => Some(Value::Decimal(value)),
        _ => Some(Value::Text(text.into())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wire(weight: i16, sign: u16, scale: u16, digits: &[u16]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for word in [digits.len() as u16, weight as u16, sign, scale] {
            bytes.extend_from_slice(&word.to_be_bytes());
        }
        for digit in digits {
            bytes.extend_from_slice(&digit.to_be_bytes());
        }
        bytes
    }

    #[test]
    fn value_contract_numeric_preserves_base_groups_sign_scale_and_specials() {
        for (bytes, expected) in [
            (wire(1, 0, 4, &[1, 2, 30]), "10002.0030"),
            (wire(-2, 0x4000, 8, &[12]), "-0.00000012"),
            (wire(-1, 0, 1, &[1000]), "0.1"),
            (wire(3, 0, 0, &[1]), "1000000000000"),
            (wire(0, 0, 8, &[]), "0.00000000"),
            (wire(0, 0xc000, 0, &[]), "NaN"),
            (wire(0, 0xd000, 0, &[]), "Infinity"),
            (wire(0, 0xf000, 0, &[]), "-Infinity"),
        ] {
            match decode_binary(&bytes) {
                Some(Value::Decimal(value)) => assert_eq!(value.to_string(), expected),
                Some(Value::Text(text)) if matches!(expected, "NaN" | "Infinity" | "-Infinity") => {
                    assert_eq!(text, expected);
                }
                other => panic!("{expected}: unexpected decoded value {other:?}"),
            }
        }
        let value = "0.123456789012345678901234567891";
        assert_eq!(decode_text(value), Some(Value::Text(value.into())));
        let zero = format!("0.{}", "0".repeat(29));
        assert_eq!(decode_text(&zero), Some(Value::Text(zero.clone())));
        for text in ["001.2300", "-0.00"] {
            assert_eq!(decode_text(text), Some(Value::Text(text.into())));
        }
    }

    #[test]
    fn value_contract_malformed_numeric_payloads_are_refused_without_rounding_or_panicking() {
        for bytes in [
            wire(0, 0, 0, &[10_000]),
            wire(0, 1, 0, &[1]),
            wire(0, 0, 0x4000, &[1]),
            wire(-1, 0, 1, &[1234]),
            wire(-2, 0, 4, &[1]),
            wire(0, 0, 0, &[1, 1]),
            wire(0, 0xc000, 0, &[1]),
        ] {
            assert_eq!(decode_binary(&bytes), None, "{bytes:?}");
        }
        let valid = wire(0, 0, 0, &[1]);
        for length in 0..valid.len() {
            assert_eq!(decode_binary(&valid[..length]), None);
        }
        let mut extra = valid;
        extra.push(0);
        assert_eq!(decode_binary(&extra), None);
        for text in ["", "-", "1.", "1.2.3", "1e400", "abc"] {
            assert_eq!(decode_text(text), None);
        }
    }

    #[test]
    fn value_contract_numeric_wire_extremes_have_bounded_exact_output() {
        let large = format!("9999{}", "0".repeat(32767 * 4));
        assert_eq!(decode_binary(&wire(i16::MAX, 0, 0, &[9999])), Some(Value::Text(large)));
        let tiny = format!("0.{}1", "0".repeat(16382));
        assert_eq!(decode_binary(&wire(-4096, 0, 16383, &[10])), Some(Value::Text(tiny)));
        assert_eq!(decode_binary(&wire(i16::MIN, 0, 16383, &[1])), None);
    }
}
