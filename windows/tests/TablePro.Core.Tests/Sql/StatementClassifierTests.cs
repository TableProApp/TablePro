using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class StatementClassifierTests
{
    [Theory]
    [InlineData("SELECT 1")]
    [InlineData("  select * from t where a = 1")]
    [InlineData("-- why\n/* note */ SELECT 1")]
    [InlineData("WITH c AS (SELECT 1) SELECT * FROM c")]
    [InlineData("WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT n FROM r")]
    [InlineData("VALUES (1), (2)")]
    [InlineData("TABLE t")]
    [InlineData("SHOW TABLES")]
    [InlineData("DESCRIBE t")]
    [InlineData("DESC t")]
    [InlineData("EXPLAIN SELECT * FROM t")]
    [InlineData("EXPLAIN (FORMAT TEXT) SELECT * FROM t")]
    [InlineData("PRAGMA table_info(t)")]
    [InlineData("(SELECT 1) UNION (SELECT 2)")]
    [InlineData("SELECT 'DELETE FROM t' AS s")]
    [InlineData("SELECT \"update\" FROM t")]
    [InlineData("SELECT updated_at, inserted FROM t")]
    [InlineData("SELECT * FROM t WHERE id IN (SELECT id FROM u)")]
    [InlineData("SELECT 1;")]
    [InlineData("SELECT 1; SELECT 2")]
    [InlineData("SELECT replace(a, 'x', 'y') FROM t")]
    [InlineData("ANALYZE FORMAT=JSON SELECT * FROM t")]
    [InlineData("ANALYZE SELECT * FROM t")]
    public void ReadsAreRead(string sql) => Assert.Equal(StatementKind.Read, Classify(sql));

    [Theory]
    [InlineData("INSERT INTO t VALUES (1)")]
    [InlineData("update t set a = 1")]
    [InlineData("DELETE FROM t")]
    [InlineData("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE")]
    [InlineData("REPLACE INTO t VALUES (1)")]
    [InlineData("UPSERT INTO t VALUES (1)")]
    [InlineData("TRUNCATE t")]
    [InlineData("COPY t FROM '/tmp/f.csv'")]
    [InlineData("VACUUM")]
    [InlineData("ANALYZE t")]
    [InlineData("ANALYZE")]
    [InlineData("ANALYZE;")]
    [InlineData("ANALYZE TABLE t")]
    [InlineData("ANALYZE (VERBOSE) t")]
    [InlineData("ANALYZE FORMAT=JSON DELETE FROM t")]
    [InlineData("WITH c AS (SELECT 1) INSERT INTO t SELECT * FROM c")]
    [InlineData("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d")]
    [InlineData("WITH u AS (UPDATE t SET a = 1 RETURNING *) SELECT count(*) FROM u")]
    [InlineData("SELECT * INTO backup FROM t")]
    [InlineData("SELECT a INTO OUTFILE '/tmp/x' FROM t")]
    [InlineData("WITH c AS (SELECT 1 AS a) SELECT a INTO t2 FROM c")]
    [InlineData("EXPLAIN ANALYZE DELETE FROM t")]
    [InlineData("EXPLAIN ANALYZE INSERT INTO t VALUES (1)")]
    [InlineData("SELECT 1; DELETE FROM t")]
    [InlineData("SELECT 1;\nUPDATE t SET a = 2;")]
    public void WritesAreWrites(string sql) => Assert.Equal(StatementKind.Write, Classify(sql));

    [Theory]
    [InlineData("CREATE TABLE t (a int)")]
    [InlineData("create index i on t (a)")]
    [InlineData("ALTER TABLE t ADD b int")]
    [InlineData("DROP TABLE t")]
    [InlineData("RENAME TABLE a TO b")]
    [InlineData("COMMENT ON TABLE t IS 'x'")]
    [InlineData("GRANT SELECT ON t TO u")]
    [InlineData("REVOKE ALL ON t FROM u")]
    [InlineData("ATTACH 'x.db' AS x")]
    [InlineData("DETACH x")]
    [InlineData("SELECT 1; DROP TABLE t")]
    public void SchemaChangesAreDdl(string sql) => Assert.Equal(StatementKind.Ddl, Classify(sql));

    [Theory]
    [InlineData("BEGIN")]
    [InlineData("START TRANSACTION")]
    [InlineData("COMMIT")]
    [InlineData("ROLLBACK")]
    [InlineData("SAVEPOINT s1")]
    [InlineData("RELEASE SAVEPOINT s1")]
    [InlineData("END")]
    [InlineData("BEGIN; SELECT 1; COMMIT")]
    public void TransactionControlIsTransaction(string sql) => Assert.Equal(StatementKind.Transaction, Classify(sql));

    [Theory]
    [InlineData("USE app")]
    [InlineData("SET search_path = app")]
    [InlineData("RESET ALL")]
    [InlineData("LISTEN ch")]
    [InlineData("UNLISTEN ch")]
    [InlineData("DISCARD ALL")]
    public void SessionStatementsAreSession(string sql) => Assert.Equal(StatementKind.Session, Classify(sql));

    [Theory]
    [InlineData("")]
    [InlineData("   \n")]
    [InlineData("-- only a comment")]
    [InlineData(";")]
    [InlineData("CALL p()")]
    [InlineData("DO $$ BEGIN END $$")]
    [InlineData("'just a string'")]
    [InlineData("42")]
    public void AnythingElseIsUnknown(string sql) => Assert.Equal(StatementKind.Unknown, Classify(sql));

    [Fact]
    public void SqlServerStatementsClassify()
    {
        var sqlServer = SqlServerDialect.Instance;

        Assert.Equal(StatementKind.Session, StatementClassifier.Classify("DECLARE @x int", sqlServer));
        Assert.Equal(StatementKind.Session, StatementClassifier.Classify("PRINT 'hi'", sqlServer));
        Assert.Equal(StatementKind.Unknown, StatementClassifier.Classify("EXEC sp_who", sqlServer));
        Assert.Equal(StatementKind.Unknown, StatementClassifier.Classify("@x", sqlServer));
        Assert.Equal(StatementKind.Read, StatementClassifier.Classify("SELECT [delete] FROM [update]", sqlServer));
    }

    [Theory]
    [InlineData("SELECT 1\nDROP TABLE t", StatementKind.Ddl)]
    [InlineData("SELECT 1\nDELETE FROM t", StatementKind.Write)]
    [InlineData("SELECT 1\nTRUNCATE TABLE t", StatementKind.Write)]
    [InlineData("SELECT 1\nEXEC sp_drop_everything", StatementKind.Unknown)]
    [InlineData("WITH c AS (SELECT 1 AS a) SELECT a FROM c\nCREATE TABLE t (a int)", StatementKind.Ddl)]
    [InlineData("BEGIN TRAN; DELETE FROM t; COMMIT", StatementKind.Write)]
    [InlineData("SELECT 1 SELECT 2", StatementKind.Read)]
    public void SqlServerBatchIsClassifiedByItsMostDangerousStatement(string sql, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(sql, SqlServerDialect.Instance));

    [Fact]
    public void WriteHiddenInsideAStringOrCommentIsIgnored()
    {
        Assert.Equal(StatementKind.Read, Classify("SELECT 1 /* ; DELETE FROM t */"));
        Assert.Equal(StatementKind.Read, Classify("SELECT 1 -- ; DROP TABLE t"));
        Assert.Equal(StatementKind.Read, Classify("SELECT $$; DELETE FROM t$$"));
    }

    [Fact]
    public void MySqlHashCommentIsIgnored() =>
        Assert.Equal(StatementKind.Read, StatementClassifier.Classify("SELECT 1 # ; DELETE FROM t", MySqlDialect.Instance));

    [Fact]
    public void RejectsNullSql() =>
        Assert.Throws<ArgumentNullException>(() => StatementClassifier.Classify(null!, PostgreSqlDialect.Instance));

    [Theory]
    [InlineData(StatementKind.Read, false)]
    [InlineData(StatementKind.Write, true)]
    [InlineData(StatementKind.Ddl, true)]
    [InlineData(StatementKind.Transaction, false)]
    [InlineData(StatementKind.Session, false)]
    [InlineData(StatementKind.Unknown, true)]
    public void SafeModeTreatsWritesDdlAndUnknownAsWrites(StatementKind kind, bool expected) =>
        Assert.Equal(expected, kind.IsWrite());

    private static StatementKind Classify(string sql) => StatementClassifier.Classify(sql, PostgreSqlDialect.Instance);
}
