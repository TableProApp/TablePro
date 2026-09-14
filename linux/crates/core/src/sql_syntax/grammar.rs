#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SqlGrammar {
    PostgreSql,
    MySql,
    Sqlite,
    MsSql,
    ClickHouse,
}

impl SqlGrammar {
    pub const ALL: [SqlGrammar; 5] = [
        SqlGrammar::PostgreSql,
        SqlGrammar::MySql,
        SqlGrammar::Sqlite,
        SqlGrammar::MsSql,
        SqlGrammar::ClickHouse,
    ];
}
