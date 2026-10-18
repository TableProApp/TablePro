//! The type modifiers PostgreSQL stores in `atttypmod`, decoded the way
//! `format_type` reads them.

/// varchar(n) and character(n) store n plus the 4-byte varlena header.
pub(crate) fn character_length(typmod: i32) -> Option<u32> {
    u32::try_from(typmod.checked_sub(4)?).ok()
}

/// numeric(p, s) stores `((p << 16) | s) + 4`, the scale as an 11-bit
/// signed field since PostgreSQL 15 allowed it to be negative. A negative
/// scale rounds to the left of the point, which the app's decimal kind
/// cannot express, so it reads as no declared scale.
pub(crate) fn numeric_precision_scale(typmod: i32) -> (Option<u32>, Option<u32>) {
    let Some(packed) = typmod.checked_sub(4).filter(|packed| *packed >= 0) else {
        return (None, None);
    };
    let precision = u32::try_from((packed >> 16) & 0xFFFF).ok();
    let scale = ((packed & 0x7FF) ^ 1024) - 1024;
    (precision, u32::try_from(scale).ok())
}

/// time(p) and timestamp(p) store p itself.
pub(crate) fn fractional_digits(typmod: i32) -> Option<u8> {
    u8::try_from(typmod).ok()
}

/// bit(n) and varbit(n) store n itself.
pub(crate) fn bit_length(typmod: i32) -> Option<u32> {
    u32::try_from(typmod).ok().filter(|length| *length > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn numeric(precision: i32, scale: i32) -> i32 {
        ((precision << 16) | (scale & 0x7FF)) + 4
    }

    #[test]
    fn pg_numeric_typmod_decodes() {
        assert_eq!(numeric_precision_scale(numeric(10, 2)), (Some(10), Some(2)));
        assert_eq!(numeric_precision_scale(numeric(38, 0)), (Some(38), Some(0)));
        assert_eq!(numeric_precision_scale(numeric(5, -2)), (Some(5), None));
        assert_eq!(numeric_precision_scale(-1), (None, None));
    }

    #[test]
    fn character_bit_and_time_modifiers() {
        assert_eq!(character_length(14), Some(10));
        assert_eq!(character_length(-1), None);
        assert_eq!(bit_length(8), Some(8));
        assert_eq!(bit_length(-1), None);
        assert_eq!(fractional_digits(3), Some(3));
        assert_eq!(fractional_digits(-1), None);
    }
}
