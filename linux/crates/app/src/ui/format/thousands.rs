use gtk4::glib;
use icu_decimal::DecimalFormatter;
use icu_decimal::input::Decimal;
use icu_locale_core::Locale;

/// Groups a count's digits the way a locale does: 1,000 in English,
/// 1.000 in German. The digits stay ASCII whatever digits the locale
/// writes by default, as the grid's numbers do.
pub(crate) struct Thousands {
    formatter: Option<DecimalFormatter>,
}

impl Thousands {
    /// `name` is a POSIX locale name, as LC_NUMERIC holds it:
    /// `de_DE.UTF-8`. The C locale, and a name ICU does not know, group
    /// as the root locale does.
    pub(crate) fn for_posix_locale(name: &str) -> Self {
        let language = name.split(['.', '@']).next().unwrap_or_default().replace('_', "-");
        let locale =
            Locale::try_from_str(&format!("{language}-u-nu-latn")).or_else(|_| Locale::try_from_str("und-u-nu-latn"));
        let formatter = match locale {
            Ok(locale) => DecimalFormatter::try_new((&locale).into(), Default::default())
                .inspect_err(|error| tracing::debug!(%error, "no number format for the locale"))
                .ok(),
            Err(error) => {
                tracing::debug!(%error, "the root locale did not parse");
                None
            }
        };
        Self { formatter }
    }

    pub(crate) fn format(&self, n: u64) -> String {
        match &self.formatter {
            Some(formatter) => formatter.format_to_string(&Decimal::from(n)),
            None => n.to_string(),
        }
    }
}

// A cache, not state: every window formats with the process's locale,
// read once, and nothing writes to it after.
thread_local! {
    static USER: Thousands = Thousands::for_posix_locale(&numeric_locale());
}

/// What LC_NUMERIC names, or LC_ALL or LANG in its place.
fn numeric_locale() -> String {
    glib::language_names_with_category("LC_NUMERIC")
        .first()
        .map(|name| name.to_string())
        .unwrap_or_default()
}

/// `n` grouped as the user's locale groups digits.
pub(crate) fn format_thousands(n: u64) -> String {
    USER.with(|thousands| thousands.format(n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_thousands_edges() {
        let english = Thousands::for_posix_locale("en_US.UTF-8");

        assert_eq!(english.format(0), "0");
        assert_eq!(english.format(1), "1");
        assert_eq!(english.format(999), "999");
        assert_eq!(english.format(1_000), "1,000");
        assert_eq!(english.format(10_000), "10,000");
        assert_eq!(english.format(1_000_000), "1,000,000");
        assert_eq!(english.format(u64::MAX), "18,446,744,073,709,551,615");
    }

    #[test]
    fn digits_are_grouped_as_the_locale_groups_them() {
        assert_eq!(
            Thousands::for_posix_locale("de_DE.UTF-8").format(1_234_567),
            "1.234.567"
        );
        assert_eq!(Thousands::for_posix_locale("sr_RS@latin").format(1_000), "1.000");
    }

    #[test]
    fn a_locale_with_its_own_digits_keeps_ascii_digits() {
        assert_eq!(
            Thousands::for_posix_locale("bn_BD.UTF-8").format(1_000_007),
            "10,00,007"
        );
    }

    #[test]
    fn the_c_locale_and_an_unknown_name_still_group() {
        assert_eq!(Thousands::for_posix_locale("C").format(1_000), "1,000");
        assert_eq!(Thousands::for_posix_locale("").format(1_000), "1,000");
        assert_eq!(Thousands::for_posix_locale("not a locale").format(1_000), "1,000");
    }
}
