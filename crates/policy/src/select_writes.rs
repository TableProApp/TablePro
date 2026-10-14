use sqlparser::ast::{Select, SelectItem, TableFactor};

use crate::classify::{classify_query, expr_writes};

pub(crate) fn select_writes(select: &Select) -> bool {
    select.into.is_some()
        || select.from.iter().any(|t| {
            std::iter::once(&t.relation)
                .chain(t.joins.iter().map(|j| &j.relation))
                .any(|factor| matches!(factor, TableFactor::Derived { subquery, .. } if classify_query(subquery).class.is_write()))
        })
        || select.projection.iter().any(|item| match item {
            SelectItem::ExprWithAlias { expr, .. } | SelectItem::UnnamedExpr(expr) => expr_writes(expr),
            _ => false,
        })
}

#[cfg(test)]
mod tests {
    use crate::classify::{StatementClass, classify};

    #[test]
    fn select_into_creates_a_table_and_is_a_write() {
        for (sql, driver) in [
            ("SELECT * INTO backup FROM accounts", "postgres"),
            ("SELECT id INTO TEMP scratch FROM accounts", "postgres"),
            ("SELECT * INTO backup FROM accounts", "mssql"),
        ] {
            let facts = classify(sql, driver);
            assert!(facts.writes(), "{sql} must be classified as a write");
            assert_ne!(facts.class, StatementClass::Select, "{sql}");
        }
        assert!(!classify("SELECT * FROM accounts", "postgres").writes());
    }

    #[test]
    fn locking_reads_are_writes_because_a_read_only_session_refuses_them() {
        for sql in [
            "SELECT * FROM users WHERE id = 1 FOR UPDATE",
            "SELECT * FROM users FOR SHARE",
            "SELECT * FROM users FOR NO KEY UPDATE SKIP LOCKED",
            "WITH u AS (SELECT * FROM users FOR UPDATE) SELECT * FROM u",
            "SELECT * FROM (SELECT id FROM users FOR UPDATE) AS s",
        ] {
            assert!(classify(sql, "postgres").writes(), "{sql}");
        }
    }
}
