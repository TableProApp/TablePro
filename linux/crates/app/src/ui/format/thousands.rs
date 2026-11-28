use gtk4::glib;

pub(crate) use tablepro_core::grid::Thousands;

// A cache, not state: every window formats with the process's locale, read
// once, and nothing writes to it after.
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

/// `plain` decimal text as the user's locale writes numbers.
pub(crate) fn format_decimal(plain: &str) -> String {
    USER.with(|thousands| thousands.format_decimal(plain))
}
