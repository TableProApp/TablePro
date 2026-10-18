#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PoolMode {
    Session,
    Transaction,
    Statement,
}

impl PoolMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Transaction => "transaction",
            Self::Statement => "statement",
        }
    }
}
