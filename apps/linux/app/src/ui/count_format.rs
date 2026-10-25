pub(super) fn format_thousands(n: u128) -> String {
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

#[cfg(test)]
mod tests {
    use super::format_thousands;

    #[test]
    fn count_grouping_handles_zero_edges_and_large_values() {
        assert_eq!(format_thousands(0), "0");
        assert_eq!(format_thousands(999), "999");
        assert_eq!(format_thousands(1_000), "1,000");
        assert_eq!(format_thousands(215_804), "215,804");
        assert_eq!(
            format_thousands(u128::MAX),
            "340,282,366,920,938,463,463,374,607,431,768,211,455"
        );
    }
}
