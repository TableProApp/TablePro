/// The language an engine's editor takes. Every variant but `Redis` is a
/// dialect of SQL; Redis's commands share none of their rules, and their
/// own live in `sql_syntax::redis`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SqlGrammar {
    PostgreSql,
    MySql,
    Sqlite,
    MsSql,
    ClickHouse,
    Redis,
}

impl SqlGrammar {
    /// The grammars that are SQL.
    pub const SQL: [SqlGrammar; 5] = [
        SqlGrammar::PostgreSql,
        SqlGrammar::MySql,
        SqlGrammar::Sqlite,
        SqlGrammar::MsSql,
        SqlGrammar::ClickHouse,
    ];
}

impl SqlGrammar {
    /// The sqlparser dialect this grammar parses with. Kept crate
    /// private: no public signature names a sqlparser type, so the
    /// parser stays replaceable.
    /// `None` for a language that is not SQL.
    pub(crate) fn parser_dialect(self) -> Option<&'static dyn sqlparser::dialect::Dialect> {
        use sqlparser::dialect::{ClickHouseDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};

        static POSTGRES: PostgreSqlDialect = PostgreSqlDialect {};
        static MYSQL: MySqlDialect = MySqlDialect {};
        static SQLITE: SQLiteDialect = SQLiteDialect {};
        static MSSQL: MsSqlDialect = MsSqlDialect {};
        static CLICKHOUSE: ClickHouseDialect = ClickHouseDialect {};

        match self {
            Self::PostgreSql => Some(&POSTGRES),
            Self::MySql => Some(&MYSQL),
            Self::Sqlite => Some(&SQLITE),
            Self::MsSql => Some(&MSSQL),
            Self::ClickHouse => Some(&CLICKHOUSE),
            Self::Redis => None,
        }
    }

    pub fn is_sql(self) -> bool {
        self != Self::Redis
    }
}
