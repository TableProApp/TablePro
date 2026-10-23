#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SqlGrammar {
    PostgreSql,
    MySql,
    Sqlite,
    MsSql,
    ClickHouse,
    /// Cassandra and ScyllaDB.
    Cql,
}

impl SqlGrammar {
    pub const ALL: [SqlGrammar; 6] = [
        SqlGrammar::PostgreSql,
        SqlGrammar::MySql,
        SqlGrammar::Sqlite,
        SqlGrammar::MsSql,
        SqlGrammar::ClickHouse,
        SqlGrammar::Cql,
    ];
}

impl SqlGrammar {
    /// The sqlparser dialect this grammar parses with. Kept crate
    /// private: no public signature names a sqlparser type, so the
    /// parser stays replaceable.
    pub(crate) fn parser_dialect(self) -> &'static dyn sqlparser::dialect::Dialect {
        use sqlparser::dialect::{
            ClickHouseDialect, GenericDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect, SQLiteDialect,
        };

        static POSTGRES: PostgreSqlDialect = PostgreSqlDialect {};
        static MYSQL: MySqlDialect = MySqlDialect {};
        static SQLITE: SQLiteDialect = SQLiteDialect {};
        static MSSQL: MsSqlDialect = MsSqlDialect {};
        static CLICKHOUSE: ClickHouseDialect = ClickHouseDialect {};
        // sqlparser has no CQL dialect. CQL's expressions are a subset of
        // what the generic one reads, and its types are parsed by the
        // driver's own dialect.
        static GENERIC: GenericDialect = GenericDialect {};

        match self {
            Self::PostgreSql => &POSTGRES,
            Self::MySql => &MYSQL,
            Self::Sqlite => &SQLITE,
            Self::MsSql => &MSSQL,
            Self::ClickHouse => &CLICKHOUSE,
            Self::Cql => &GENERIC,
        }
    }
}
