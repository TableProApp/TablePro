#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use tablepro_policy::{StatementClass, classify};

#[test]
fn a_rename_table_statement_is_ddl_naming_the_old_table() {
    for driver in ["clickhouse", "mysql"] {
        let facts = classify("RENAME TABLE `db`.`old` TO `db`.`new`", driver);
        assert_eq!(facts.class, StatementClass::Ddl, "{driver}");
        assert!(facts.contains_ddl(), "{driver}");
        assert_eq!(facts.tables, ["`db`.`old`"], "{driver}");
    }
}
