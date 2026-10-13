#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

#[test]
fn a_name_with_a_control_character_is_quoted_exactly_and_never_changed_into_another_name() {
    use tablepro_core::sql_dialect::quote_ident;
    for (driver, expected) in [
        ("postgres", "\"a\nb\""),
        ("sqlite", "\"a\nb\""),
        ("mysql", "`a\nb`"),
        ("mssql", "[a\nb]"),
        ("clickhouse", "`a\nb`"),
    ] {
        assert_eq!(quote_ident(driver, "a\nb"), expected, "{driver}");
        assert_ne!(quote_ident(driver, "a\nb"), quote_ident(driver, "ab"), "{driver}");
    }
    assert_eq!(quote_ident("postgres", "a\tb"), "\"a\tb\"");
    assert_eq!(quote_ident("postgres", "say \"hi\"\n"), "\"say \"\"hi\"\"\n\"");
}
