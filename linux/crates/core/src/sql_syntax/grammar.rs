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

impl SqlGrammar {
    /// The sqlparser dialect this grammar parses with. Kept crate
    /// private: no public signature names a sqlparser type, so the
    /// parser stays replaceable.
    pub(crate) fn parser_dialect(self) -> &'static dyn sqlparser::dialect::Dialect {
        use sqlparser::dialect::{ClickHouseDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect};

        static POSTGRES: PostgreSqlDialect = PostgreSqlDialect {};
        static MYSQL: MySqlDialect = MySqlDialect {};
        static SQLITE: SQLiteDialect = SQLiteDialect {};
        static MSSQL: MsSqlDialect = MsSqlDialect {};
        static CLICKHOUSE: ClickHouseDialect = ClickHouseDialect {};

        match self {
            Self::PostgreSql => &POSTGRES,
            Self::MySql => &MYSQL,
            Self::Sqlite => &SQLITE,
            Self::MsSql => &MSSQL,
            Self::ClickHouse => &CLICKHOUSE,
        }
    }
}
