#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_policy::{StatementClass, classify};

#[test]
fn a_redis_select_switches_databases_and_is_not_a_read() {
    for command in [
        "SELECT 2",
        "select 0",
        "SELECT 15;",
        "SELECT \"2\"",
        "SELECT '2'",
        "SELECT db",
        "FLUSHDB",
        "GET key",
    ] {
        let facts = classify(command, "redis");
        assert_eq!(facts.class, StatementClass::Unparseable, "{command}");
        assert!(facts.writes(), "{command}");
    }
}

#[test]
fn the_apps_own_redis_value_reads_stay_reads() {
    let facts = classify("SELECT \"Value\" FROM \"db3\" WHERE \"Key\" = ?", "redis");
    assert_eq!(facts.class, StatementClass::Select);
    assert!(!facts.writes());
    assert_eq!(classify("SELECT 2", "postgres").class, StatementClass::Select);
}
