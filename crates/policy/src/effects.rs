use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub(crate) struct Effects(u16);

impl Effects {
    pub(crate) const EMPTY: Self = Self(0);
    pub(crate) const READS: Self = Self(1 << 0);
    pub(crate) const WRITES_ROWS: Self = Self(1 << 1);
    pub(crate) const WRITES_SCHEMA: Self = Self(1 << 2);
    pub(crate) const ADMIN: Self = Self(1 << 3);
    pub(crate) const TRANSACTION_CONTROL: Self = Self(1 << 4);
    pub(crate) const SESSION_STATE: Self = Self(1 << 5);
    pub(crate) const HOST_OR_FILE_ACCESS: Self = Self(1 << 6);
    pub(crate) const UNKNOWN: Self = Self(1 << 7);

    pub(crate) const fn union(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    pub(crate) const fn contains(self, other: Self) -> bool {
        self.0 & other.0 == other.0
    }

    pub(crate) const fn writes(self) -> bool {
        let write_effects = Self::WRITES_ROWS
            .union(Self::WRITES_SCHEMA)
            .union(Self::ADMIN)
            .union(Self::UNKNOWN);
        self.0 & write_effects.0 != 0
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        audit::AuditOperationClass,
        classify::{StatementClass, classify},
    };

    use super::Effects;

    #[test]
    fn effects_match_legacy_write_facts_without_changing_legacy_classes() {
        for (sql, driver) in [
            ("SELECT * FROM users", "postgres"),
            ("SELECT * INTO backup FROM users", "postgres"),
            ("INSERT INTO users(id) VALUES (1)", "postgres"),
            ("UPDATE users SET id = 2 WHERE id = 1", "postgres"),
            ("DELETE FROM users WHERE id = 1", "postgres"),
            ("CREATE TABLE users(id INTEGER)", "postgres"),
            ("TRUNCATE TABLE users", "postgres"),
            ("COPY users TO PROGRAM 'echo unsafe'", "postgres"),
            (
                "MERGE INTO users USING staged ON users.id = staged.id WHEN MATCHED THEN DELETE",
                "postgres",
            ),
            ("SET work_mem = '64MB'", "postgres"),
            ("BEGIN", "postgres"),
            ("SELECT read_text('/etc/passwd')", "duckdb"),
        ] {
            let analysis = classify(sql, driver);
            assert_eq!(analysis.effects.writes(), analysis.writes(), "SQL: {sql}");
        }

        let truncate = classify("TRUNCATE TABLE users", "postgres");
        assert_eq!(truncate.class, StatementClass::Ddl);
        assert!(truncate.effects.contains(Effects::WRITES_ROWS));
        assert!(!truncate.effects.contains(Effects::WRITES_SCHEMA));
    }

    #[test]
    fn mixed_write_scripts_get_an_order_independent_class() {
        let delete_then_insert = classify(
            "DELETE FROM users WHERE id = 1; INSERT INTO users(id) VALUES (2)",
            "postgres",
        );
        let insert_then_delete = classify(
            "INSERT INTO users(id) VALUES (2); DELETE FROM users WHERE id = 1",
            "postgres",
        );

        assert_eq!(delete_then_insert.effects, insert_then_delete.effects);
        assert_eq!(delete_then_insert.class, StatementClass::Other);
        assert_eq!(insert_then_delete.class, StatementClass::Other);
        assert_eq!(
            AuditOperationClass::from_statement(delete_then_insert.class, delete_then_insert.writes()),
            AuditOperationClass::from_statement(insert_then_delete.class, insert_then_delete.writes())
        );
        assert_eq!(
            AuditOperationClass::from_statement(delete_then_insert.class, delete_then_insert.writes()),
            AuditOperationClass::UnknownWrite
        );
        assert!(delete_then_insert.effects.contains(Effects::WRITES_ROWS));

        for sql in [
            "DELETE FROM users WHERE id = 1; INSERT INTO users(id) VALUES (2); UPDATE users SET id = 3",
            "INSERT INTO users(id) VALUES (2); UPDATE users SET id = 3; DELETE FROM users WHERE id = 1",
            "UPDATE users SET id = 3; DELETE FROM users WHERE id = 1; INSERT INTO users(id) VALUES (2)",
        ] {
            assert_eq!(classify(sql, "postgres").class, StatementClass::Other, "SQL: {sql}");
        }

        for sql in [
            "SELECT 1; DELETE FROM users WHERE id = 1",
            "DELETE FROM users WHERE id = 1; SELECT 1",
        ] {
            assert_eq!(classify(sql, "postgres").class, StatementClass::Delete, "SQL: {sql}");
        }
    }

    #[test]
    fn effects_keep_security_and_session_facts_separate() {
        let copy = classify("COPY users TO PROGRAM 'echo unsafe'", "postgres");
        assert!(copy.effects.contains(Effects::ADMIN));
        assert!(copy.effects.contains(Effects::HOST_OR_FILE_ACCESS));

        let begin = classify("BEGIN", "postgres");
        assert!(begin.effects.contains(Effects::TRANSACTION_CONTROL));

        let set = classify("SET work_mem = '64MB'", "postgres");
        assert!(set.effects.contains(Effects::SESSION_STATE));

        let file_read = classify("SELECT read_text('/etc/passwd')", "duckdb");
        assert!(file_read.effects.contains(Effects::READS));
        assert!(file_read.effects.contains(Effects::HOST_OR_FILE_ACCESS));
        assert!(!file_read.effects.writes());

        let malformed = classify("SELECCT * FROM users", "postgres");
        assert!(malformed.effects.contains(Effects::UNKNOWN));
    }

    #[test]
    fn effects_expose_side_effects_that_legacy_facts_do_not_record() {
        let mysql_lock = classify("SELECT GET_LOCK('bookie', 1)", "mysql");
        assert_eq!(mysql_lock.class, StatementClass::Select);
        assert!(!mysql_lock.writes());
        assert!(mysql_lock.effects.contains(Effects::READS));
        assert!(mysql_lock.effects.contains(Effects::SESSION_STATE));
        assert!(mysql_lock.effects.contains(Effects::ADMIN));

        let duckdb_export = classify("SELECT write_csv('users', '/tmp/users.csv')", "duckdb");
        assert_eq!(duckdb_export.class, StatementClass::Select);
        assert!(!duckdb_export.writes());
        assert!(duckdb_export.effects.contains(Effects::HOST_OR_FILE_ACCESS));
        assert!(duckdb_export.effects.contains(Effects::ADMIN));
    }

    #[test]
    fn effects_include_reads_used_to_build_or_mutate_rows() {
        let create_table = classify("CREATE TABLE copy AS SELECT * FROM users", "postgres");
        assert!(create_table.effects.contains(Effects::READS));
        assert!(create_table.effects.contains(Effects::WRITES_SCHEMA));

        let insert = classify("INSERT INTO copy SELECT * FROM users", "postgres");
        assert!(insert.effects.contains(Effects::READS));
        assert!(insert.effects.contains(Effects::WRITES_ROWS));
    }

    #[test]
    fn statement_facts_round_trip_the_canonical_effect_set() {
        let facts = classify("SELECT read_text('/etc/passwd')", "duckdb");
        let encoded = serde_json::to_value(&facts);
        assert!(encoded.is_ok());
        let Ok(encoded) = encoded else {
            return;
        };
        let decoded: Result<crate::classify::StatementFacts, _> = serde_json::from_value(encoded);
        assert!(decoded.is_ok());
        let Ok(decoded) = decoded else {
            return;
        };

        assert_eq!(decoded, facts);
        assert!(decoded.effects.contains(Effects::HOST_OR_FILE_ACCESS));
    }
}
