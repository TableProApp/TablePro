/// What a foreign key does to the referencing rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ReferentialAction {
    /// The SQL default. Generated DDL omits the clause entirely.
    #[default]
    NoAction,
    Restrict,
    Cascade,
    SetNull,
    SetDefault,
}

impl ReferentialAction {
    pub const ALL: [ReferentialAction; 5] = [
        ReferentialAction::NoAction,
        ReferentialAction::Restrict,
        ReferentialAction::Cascade,
        ReferentialAction::SetNull,
        ReferentialAction::SetDefault,
    ];

    pub fn as_sql(self) -> &'static str {
        match self {
            Self::NoAction => "NO ACTION",
            Self::Restrict => "RESTRICT",
            Self::Cascade => "CASCADE",
            Self::SetNull => "SET NULL",
            Self::SetDefault => "SET DEFAULT",
        }
    }

    /// `NO ACTION` is the default, so generated DDL leaves it out.
    pub fn is_default(self) -> bool {
        matches!(self, Self::NoAction)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn as_sql_is_the_standard_spelling() {
        assert_eq!(ReferentialAction::NoAction.as_sql(), "NO ACTION");
        assert_eq!(ReferentialAction::SetNull.as_sql(), "SET NULL");
        assert_eq!(ReferentialAction::SetDefault.as_sql(), "SET DEFAULT");
        assert_eq!(ReferentialAction::default(), ReferentialAction::NoAction);
        assert!(ReferentialAction::NoAction.is_default());
        assert!(ReferentialAction::ALL.iter().filter(|a| a.is_default()).count() == 1);
    }
}
