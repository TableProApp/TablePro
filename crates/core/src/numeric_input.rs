#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum FloatInputError {
    #[error("invalid floating-point number")]
    Invalid,
    #[error("number exceeds the floating-point range")]
    Overflow,
    #[error("nonzero number is below the floating-point range")]
    Underflow,
}

pub fn parse_float_input(text: &str) -> Result<f64, FloatInputError> {
    let text = text.trim();
    let value = text.parse::<f64>().map_err(|_| FloatInputError::Invalid)?;
    if !value.is_finite() && text.chars().any(|character| character.is_ascii_digit()) {
        return Err(FloatInputError::Overflow);
    }
    let mantissa = text.split(['e', 'E']).next().unwrap_or(text);
    if value == 0.0 && mantissa.chars().any(|character| matches!(character, '1'..='9')) {
        return Err(FloatInputError::Underflow);
    }
    Ok(value)
}

pub fn is_numeric_input(text: &str) -> bool {
    match parse_float_input(text) {
        Ok(value) => value.is_finite(),
        Err(FloatInputError::Invalid) => false,
        Err(FloatInputError::Overflow | FloatInputError::Underflow) => true,
    }
}

pub fn sqlite_declared_type_has_numeric_affinity(data_type: &str) -> bool {
    if data_type.trim().eq_ignore_ascii_case("ANY") {
        // SQLite gives ANY different affinity in STRICT tables, and the
        // current column metadata does not report whether the table is STRICT.
        return false;
    }
    let data_type = data_type.to_ascii_uppercase();
    !data_type.is_empty()
        && !["INT", "CHAR", "CLOB", "TEXT", "BLOB", "REAL", "FLOA", "DOUB"]
            .iter()
            .any(|marker| data_type.contains(marker))
}

pub fn sqlite_affinity_decimal(text: &str) -> Option<rust_decimal::Decimal> {
    let text = text.trim();
    let decimal = if text.contains(['e', 'E']) {
        rust_decimal::Decimal::from_scientific(text).ok()?
    } else {
        rust_decimal::Decimal::from_str_exact(text).ok()?
    };
    let float = text.parse::<f64>().ok()?;
    if !float.is_finite() || rust_decimal::Decimal::from_str_exact(&float.to_string()).ok()? != decimal {
        return None;
    }
    Some(decimal)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_contract_float_input_distinguishes_zero_subnormal_and_explicit_infinity() {
        for text in ["0", "0e400", "0e-400"] {
            assert_eq!(parse_float_input(text).unwrap(), 0.0);
        }
        assert_eq!(parse_float_input("-0.0").unwrap().to_bits(), (-0.0_f64).to_bits());
        assert_eq!(parse_float_input("5e-324").unwrap().to_bits(), 1);
        assert!(parse_float_input("inf").unwrap().is_infinite());
        assert!(parse_float_input("NaN").unwrap().is_nan());
        assert_eq!(parse_float_input("1e400"), Err(FloatInputError::Overflow));
        assert_eq!(parse_float_input("1e-400"), Err(FloatInputError::Underflow));
        assert!(is_numeric_input("1e400"));
        assert!(is_numeric_input("1e-400"));
        assert!(!is_numeric_input("not numeric"));
        assert!(!is_numeric_input("NaN"));
        assert_eq!(sqlite_affinity_decimal("42.50").unwrap().to_string(), "42.50");
        assert!(sqlite_affinity_decimal("1e3").is_some());
        assert!(sqlite_affinity_decimal("9223372036854775808").is_none());
        assert!(sqlite_affinity_decimal("1e999").is_none());
        assert!(sqlite_affinity_decimal("1e-400").is_none());
        assert!(sqlite_affinity_decimal("0.123456789012345678901234567890123").is_none());
    }

    #[test]
    fn sqlite_declared_types_follow_native_affinity_precedence() {
        for data_type in ["ENUM", "BOOLEAN", "DATE", "STRING", "NUMERIC", "DECIMAL"] {
            assert!(sqlite_declared_type_has_numeric_affinity(data_type), "{data_type}");
        }
        for data_type in [
            "INTEGER",
            "VARCHAR(20)",
            "CLOB",
            "TEXT",
            "BLOB",
            "REAL",
            "DOUBLE",
            "ANY",
        ] {
            assert!(!sqlite_declared_type_has_numeric_affinity(data_type), "{data_type}");
        }
        assert!(!sqlite_declared_type_has_numeric_affinity(""));
    }
}
