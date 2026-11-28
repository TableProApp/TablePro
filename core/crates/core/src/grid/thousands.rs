use icu_decimal::DecimalFormatter;
use icu_decimal::input::Decimal;
use icu_locale_core::Locale;

/// Groups a count's digits the way a locale does: 1,000 in English, 1.000
/// in German. The digits stay ASCII whatever digits the locale writes by
/// default, as the grid's numbers do. The app reads the locale name; this
/// does the grouping.
pub struct Thousands {
    formatter: Option<DecimalFormatter>,
}

impl Thousands {
    /// `name` is a POSIX locale name, as LC_NUMERIC holds it: `de_DE.UTF-8`.
    /// The C locale, and a name ICU does not know, group as the root locale
    /// does.
    pub fn for_posix_locale(name: &str) -> Self {
        let language = name.split(['.', '@']).next().unwrap_or_default().replace('_', "-");
        let locale =
            Locale::try_from_str(&format!("{language}-u-nu-latn")).or_else(|_| Locale::try_from_str("und-u-nu-latn"));
        // A locale ICU cannot build a formatter for groups as no locale does.
        let formatter = locale
            .ok()
            .and_then(|locale| DecimalFormatter::try_new((&locale).into(), Default::default()).ok());
        Self { formatter }
    }

    pub fn format(&self, n: u64) -> String {
        match &self.formatter {
            Some(formatter) => formatter.format_to_string(&Decimal::from(n)),
            None => n.to_string(),
        }
    }

    /// `plain`, a decimal number written with a `.` and no grouping, grouped
    /// and with the locale's decimal separator. Every fraction digit stays,
    /// trailing zeros included, so cents read as cents.
    pub fn format_decimal(&self, plain: &str) -> String {
        let parsed = Decimal::try_from_str(plain);
        match (&self.formatter, parsed) {
            (Some(formatter), Ok(decimal)) => formatter.format_to_string(&decimal),
            _ => plain.to_owned(),
        }
    }
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

    #[test]
    fn a_decimal_keeps_its_fraction_digits_and_the_locale_separator() {
        let english = Thousands::for_posix_locale("en_US.UTF-8");
        let italian = Thousands::for_posix_locale("it_IT.UTF-8");

        assert_eq!(english.format_decimal("1234567.50"), "1,234,567.50");
        assert_eq!(english.format_decimal("-0.025"), "-0.025");
        assert_eq!(italian.format_decimal("12345.5"), "12.345,5");
        assert_eq!(
            italian.format_decimal("1234.5"),
            "1234,5",
            "four digits stay together in Italian"
        );
        assert_eq!(english.format_decimal("not a number"), "not a number");
    }
}
