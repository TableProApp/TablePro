//! Successful-statement catalog notifications. This does not authorize execution.
use sqlparser::{ast::Statement, parser::Parser};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CatalogEffect {
    None,
    Ddl,
    Begin,
    Commit { chain: bool },
    Rollback { chain: bool },
}

pub fn catalog_effect(sql: &str, driver_id: &str) -> CatalogEffect {
    let dialect = super::classify::dialect_for(driver_id);
    let Ok(statements) = Parser::parse_sql(dialect.as_ref(), sql) else {
        return CatalogEffect::None;
    };
    match statements.as_slice() {
        [Statement::StartTransaction { .. }] => CatalogEffect::Begin,
        [Statement::Commit { chain, .. }] => CatalogEffect::Commit { chain: *chain },
        [Statement::Rollback { chain, savepoint: None }] => CatalogEffect::Rollback { chain: *chain },
        [_] if super::classify(sql, driver_id).contains_ddl() => CatalogEffect::Ddl,
        _ => CatalogEffect::None,
    }
}

#[cfg(test)]
mod tests {
    use super::{CatalogEffect, catalog_effect};

    #[test]
    fn recognizes_single_transaction_boundaries_with_comments_and_chain_state() {
        assert_eq!(catalog_effect("/* start */ BEGIN", "postgres"), CatalogEffect::Begin);
        assert_eq!(
            catalog_effect("COMMIT", "postgres"),
            CatalogEffect::Commit { chain: false }
        );
        assert_eq!(
            catalog_effect("COMMIT AND CHAIN", "postgres"),
            CatalogEffect::Commit { chain: true }
        );
        assert_eq!(
            catalog_effect("ROLLBACK", "postgres"),
            CatalogEffect::Rollback { chain: false }
        );
        assert_eq!(
            catalog_effect("ROLLBACK AND CHAIN", "postgres"),
            CatalogEffect::Rollback { chain: true }
        );
    }

    #[test]
    fn recognizes_only_successful_single_statement_ddl() {
        assert_eq!(
            catalog_effect("CREATE TABLE items (id INT)", "postgres"),
            CatalogEffect::Ddl
        );
        assert_eq!(catalog_effect("DROP TABLE items", "mysql"), CatalogEffect::Ddl);
        assert_eq!(
            catalog_effect("ROLLBACK TO SAVEPOINT before_ddl", "postgres"),
            CatalogEffect::None
        );
        assert_eq!(
            catalog_effect("SELECT 'DROP TABLE items'", "postgres"),
            CatalogEffect::None
        );
        assert_eq!(
            catalog_effect("CREATE TABLE a (id INT); CREATE TABLE b (id INT)", "postgres"),
            CatalogEffect::None
        );
        assert_eq!(catalog_effect("not sql", "postgres"), CatalogEffect::None);
    }
}
