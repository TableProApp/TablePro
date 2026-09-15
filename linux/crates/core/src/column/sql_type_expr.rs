/// A SQL type as the server spells it.
///
/// The inner text is pasted into DDL verbatim, so it may only come from
/// the server's own catalogue or from text a `SqlDialect` has already
/// parsed. `from_catalog_text` carries that provenance in its name and is
/// banned outside the driver crates by `disallowed-methods`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SqlTypeExpr(Box<str>);

impl SqlTypeExpr {
    /// Only for text the server itself produced, such as
    /// `format_type()` output or an `information_schema` column.
    pub fn from_catalog_text(text: impl Into<Box<str>>) -> Self {
        Self(text.into())
    }

    pub fn as_sql(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for SqlTypeExpr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// A SQL expression as the server spells it, with the same provenance
/// rule as `SqlTypeExpr`.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SqlExpression(Box<str>);

impl SqlExpression {
    pub fn from_catalog_text(text: impl Into<Box<str>>) -> Self {
        Self(text.into())
    }

    pub fn as_sql(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for SqlExpression {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
