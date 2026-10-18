use super::SqlTypeExpr;

/// The server's own spelling of a column's type, from its catalogue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogType {
    /// The type as declared, modifiers included, for DDL: PostgreSQL
    /// `format_type(atttypid, atttypmod)`, MySQL COLUMN_TYPE.
    pub declaration: SqlTypeExpr,
    /// The type a bound text parameter is cast to. It drops the
    /// modifiers, because a cast to `varchar(10)` truncates silently.
    pub cast_target: SqlTypeExpr,
}
