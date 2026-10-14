/// A count with thousands separators (1000 → 1,000), so a row count or
/// a page size reads at a glance.
pub(crate) fn format_thousands(n: u64) -> String {
    let s = n.to_string();
    let bytes = s.as_bytes();
    let len = bytes.len();
    let mut out = String::with_capacity(len + len / 3);
    for (i, b) in bytes.iter().enumerate() {
        if i > 0 && (len - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(*b as char);
    }
    out
}

/// The count gettext picks a plural form by. It takes a u32, and a
/// result past that is rare enough for the largest u32 to stand in.
pub(crate) fn plural_count(n: u64) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}
