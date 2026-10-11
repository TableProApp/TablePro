use crate::sql_syntax::SqlGrammar;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct LexicalSettings {
    pub backslash_escapes: bool,
}

impl LexicalSettings {
    pub fn default_for(grammar: SqlGrammar) -> Self {
        let backslash_escapes = match grammar {
            SqlGrammar::MySql | SqlGrammar::ClickHouse => true,
            SqlGrammar::PostgreSql | SqlGrammar::Sqlite | SqlGrammar::MsSql => false,
        };
        Self { backslash_escapes }
    }
}
