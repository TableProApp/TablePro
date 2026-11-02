use crate::statement::BoundParam;

/// What a dialect produced for one value: the SQL that names it, and
/// the parameter it stands for.
///
/// `param` is `None` for an engine with no parameters, where the value
/// is already a literal inside `sql`.
#[derive(Debug, Clone, PartialEq)]
pub struct Placeholder {
    pub sql: String,
    pub param: Option<BoundParam>,
}

impl Placeholder {
    pub fn bound(sql: impl Into<String>, param: BoundParam) -> Self {
        Self {
            sql: sql.into(),
            param: Some(param),
        }
    }

    /// For an engine that inlines the literal instead of binding it.
    pub fn inline(sql: impl Into<String>) -> Self {
        Self {
            sql: sql.into(),
            param: None,
        }
    }
}
