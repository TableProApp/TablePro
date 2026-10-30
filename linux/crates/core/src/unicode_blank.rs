//! Characters that show as nothing, which a reader cannot tell apart
//! from a space or from no character at all.

/// Unicode's Default_Ignorable_Code_Point: U+200B, U+FEFF and the rest a
/// renderer draws as nothing.
pub fn is_default_ignorable(c: char) -> bool {
    matches!(
        u32::from(c),
        0x00AD
            | 0x034F
            | 0x061C
            | 0x115F..=0x1160
            | 0x17B4..=0x17B5
            | 0x180B..=0x180F
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x206F
            | 0x3164
            | 0xFE00..=0xFE0F
            | 0xFEFF
            | 0xFFA0
            | 0xFFF0..=0xFFF8
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0000..=0xE0FFF
    )
}

/// White space, or a character that shows as nothing.
pub fn is_blank(c: char) -> bool {
    c.is_whitespace() || is_default_ignorable(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invisible_characters_are_blank_and_letters_are_not() {
        for c in [
            '\u{feff}', '\u{200b}', '\u{00ad}', '\u{2060}', '\u{a0}', ' ', '\u{3000}',
        ] {
            assert!(is_blank(c), "{:04x}", u32::from(c));
        }
        for c in ['a', 'é', '-', '_', '\u{4e00}'] {
            assert!(!is_blank(c), "{c}");
        }
        assert!(!is_default_ignorable('\u{a0}'));
    }
}
