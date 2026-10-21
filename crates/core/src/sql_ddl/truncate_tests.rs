use super::build_truncate_table;

#[test]
fn truncate_table_uses_each_engines_spelling() {
    assert_eq!(
        build_truncate_table("postgres", Some("auth"), "users").unwrap(),
        "TRUNCATE TABLE \"auth\".\"users\""
    );
    assert_eq!(
        build_truncate_table("mysql", None, "users").unwrap(),
        "TRUNCATE TABLE `users`"
    );
}

#[test]
fn truncate_table_refuses_sqlite_unsupported_engines_and_empty_names() {
    assert!(build_truncate_table("sqlite", None, "users").is_err());
    assert!(build_truncate_table("redis", None, "users").is_err());
    assert!(build_truncate_table("postgres", None, "").is_err());
}
