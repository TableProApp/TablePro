/// The language an engine's editor takes. Every variant but `Redis` and
/// `Mongo` is a dialect of SQL. Redis's commands and MongoDB's shell share
/// none of their rules: theirs live in `sql_syntax::redis` and
/// `sql_syntax::mongo`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SqlGrammar {
    PostgreSql,
    MySql,
    Sqlite,
    MsSql,
    ClickHouse,
    DuckDb,
    /// Cassandra and ScyllaDB.
    Cql,
    Redis,
    Mongo,
}

impl SqlGrammar {
    /// The grammars that are SQL.
    pub const SQL: [SqlGrammar; 7] = [
        SqlGrammar::PostgreSql,
        SqlGrammar::MySql,
        SqlGrammar::Sqlite,
        SqlGrammar::MsSql,
        SqlGrammar::ClickHouse,
        SqlGrammar::DuckDb,
        SqlGrammar::Cql,
    ];
}

impl SqlGrammar {
    /// The sqlparser dialect this grammar parses with. Kept crate
    /// private: no public signature names a sqlparser type, so the
    /// parser stays replaceable.
    /// `None` for a language that is not SQL.
    pub(crate) fn parser_dialect(self) -> Option<&'static dyn sqlparser::dialect::Dialect> {
        use sqlparser::dialect::{
            ClickHouseDialect, DuckDbDialect, GenericDialect, MsSqlDialect, MySqlDialect, PostgreSqlDialect,
            SQLiteDialect,
        };

        static POSTGRES: PostgreSqlDialect = PostgreSqlDialect {};
        static MYSQL: MySqlDialect = MySqlDialect {};
        static SQLITE: SQLiteDialect = SQLiteDialect {};
        static MSSQL: MsSqlDialect = MsSqlDialect {};
        static CLICKHOUSE: ClickHouseDialect = ClickHouseDialect {};
        static DUCKDB: DuckDbDialect = DuckDbDialect {};
        // sqlparser has no CQL dialect. CQL's expressions are a subset of
        // what the generic one reads, and its types are parsed by the
        // driver's own dialect.
        static GENERIC: GenericDialect = GenericDialect {};

        match self {
            Self::PostgreSql => Some(&POSTGRES),
            Self::MySql => Some(&MYSQL),
            Self::Sqlite => Some(&SQLITE),
            Self::MsSql => Some(&MSSQL),
            Self::ClickHouse => Some(&CLICKHOUSE),
            Self::DuckDb => Some(&DUCKDB),
            Self::Cql => Some(&GENERIC),
            Self::Redis | Self::Mongo => None,
        }
    }

    pub fn is_sql(self) -> bool {
        !matches!(self, Self::Redis | Self::Mongo)
    }
}
