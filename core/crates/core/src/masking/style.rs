// How a masked value is shown. The codes are the macOS app's stored names and the share link's `masked` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MaskingStyle {
    Full,
    LastFour,
    Email,
    Hash,
    Null,
}

// What a rule's pattern names: a column, or a column's type.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum MaskingTarget {
    #[default]
    Column,
    Type,
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

    // Two styles that differ each show something the other hides, except Null, which shows nothing at all.
    pub fn strictest(first: Option<Self>, second: Option<Self>) -> Option<Self> {
        let Some(first) = first else {
            return second;
        };
        let Some(second) = second else {
            return Some(first);
        };
        Some(match (first, second) {
            _ if first == second => first,
            (Self::Null, _) | (_, Self::Null) => Self::Null,
            _ => Self::Full,
        })
    }

    // A style a rule's own may be swapped for: the same, or one that shows nothing of the value.
    pub fn hides_at_least(self, other: Self) -> bool {
        Self::strictest(Some(self), Some(other)) == Some(self)
    }
}

impl MaskingTarget {
    pub const ALL: [Self; 2] = [Self::Column, Self::Type];

    pub fn code(self) -> &'static str {
        match self {
            Self::Column => "column",
            Self::Type => "type",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|target| target.code() == code)
    }
}

#[cfg(test)]
mod tests {
    use super::MaskingStyle::{Email, Full, Hash, LastFour, Null};
    use super::*;

    #[test]
    fn codes_are_the_macos_names_and_read_back() {
        let codes: Vec<&str> = MaskingStyle::ALL.iter().map(|style| style.code()).collect();

        assert_eq!(codes, ["full", "lastFour", "email", "hash", "null"]);
        for style in MaskingStyle::ALL {
            assert_eq!(MaskingStyle::from_code(style.code()), Some(style));
        }
        assert_eq!(MaskingStyle::from_code("Full"), None);
        assert_eq!(MaskingTarget::from_code("type"), Some(MaskingTarget::Type));
        assert_eq!(MaskingTarget::from_code("table"), None);
    }

    #[test]
    fn the_strictest_of_two_styles_shows_what_neither_hides() {
        assert_eq!(MaskingStyle::strictest(None, None), None);
        assert_eq!(MaskingStyle::strictest(None, Some(Email)), Some(Email));
        assert_eq!(MaskingStyle::strictest(Some(Hash), None), Some(Hash));
        assert_eq!(MaskingStyle::strictest(Some(LastFour), Some(LastFour)), Some(LastFour));
        assert_eq!(MaskingStyle::strictest(Some(LastFour), Some(Email)), Some(Full));
        assert_eq!(MaskingStyle::strictest(Some(Hash), Some(Full)), Some(Full));
        assert_eq!(MaskingStyle::strictest(Some(Null), Some(Full)), Some(Null));
        assert_eq!(MaskingStyle::strictest(Some(Email), Some(Null)), Some(Null));
    }

    #[test]
    fn a_rule_s_style_gives_way_only_to_one_that_hides_as_much() {
        assert!(Email.hides_at_least(Email));
        assert!(Full.hides_at_least(Email));
        assert!(Null.hides_at_least(Email));
        assert!(Null.hides_at_least(Full));
        assert!(!Full.hides_at_least(Null));
        assert!(!LastFour.hides_at_least(Email));
        assert!(!Hash.hides_at_least(Full));
    }
}
