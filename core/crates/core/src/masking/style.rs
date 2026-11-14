// How a masked value is shown. The codes are the macOS app's stored names and the share link's `masked` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MaskingStyle {
    Full,
    LastFour,
    Email,
    Hash,
    Null,
}

impl MaskingStyle {
    pub const ALL: [Self; 5] = [Self::Full, Self::LastFour, Self::Email, Self::Hash, Self::Null];

    pub fn code(self) -> &'static str {
        match self {
            Self::Full => "full",
            Self::LastFour => "lastFour",
            Self::Email => "email",
            Self::Hash => "hash",
            Self::Null => "null",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|style| style.code() == code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_are_the_macos_names_and_read_back() {
        let codes: Vec<&str> = MaskingStyle::ALL.iter().map(|style| style.code()).collect();

        assert_eq!(codes, ["full", "lastFour", "email", "hash", "null"]);
        for style in MaskingStyle::ALL {
            assert_eq!(MaskingStyle::from_code(style.code()), Some(style));
        }
        assert_eq!(MaskingStyle::from_code("Full"), None);
    }
}
