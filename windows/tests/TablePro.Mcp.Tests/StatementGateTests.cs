using TablePro.Core.Connections;
using TablePro.Core.Sql;
using TablePro.Mcp.Tools;

namespace TablePro.Mcp.Tests;

public sealed class StatementGateTests
{
    private static readonly SqlDialect Postgres = SqlDialects.For(DatabaseEngine.PostgreSql);
    private static readonly SqlDialect MySql = SqlDialects.For(DatabaseEngine.MySql);
    private static readonly SqlDialect SqlServer = SqlDialects.For(DatabaseEngine.SqlServer);

    [Theory]
    [InlineData("SELECT * FROM users")]
    [InlineData("  select id from users where email like '%delete%';  ")]
    [InlineData("WITH t AS (SELECT 1 AS n) SELECT n FROM t")]
    [InlineData("SELECT replace(name, 'a', 'b') FROM users")]
    [InlineData("SELECT u.\"delete\", u.created FROM users u")]
    [InlineData("EXPLAIN SELECT 1")]
    [InlineData("SELECT 1 -- DROP TABLE users")]
    [InlineData("SHOW search_path")]
    public void ReadsPass(string sql)
    {
        var gated = McpStatementGate.Analyze(sql, Postgres, 100 * 1024);

        Assert.True(gated.IsRead, gated.Kind.ToString());
    }

    [Theory]
    [InlineData("DELETE FROM users WHERE id = 1")]
    [InlineData("WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone")]
    [InlineData("EXPLAIN ANALYZE DELETE FROM users")]
    [InlineData("SELECT * INTO backup FROM users")]
    [InlineData("CREATE TABLE t (id int)")]
    [InlineData("SET ROLE admin")]
    [InlineData("BEGIN")]
    [InlineData("CALL refresh_all()")]
    [InlineData("DO $$ BEGIN DELETE FROM users; END $$")]
    [InlineData("VACUUM users")]
    public void WritesAreNotReads(string sql)
    {
        var gated = McpStatementGate.Analyze(sql, Postgres, 100 * 1024);

        Assert.False(gated.IsRead);
    }

    [Theory]
    [InlineData("SELECT 1; DROP TABLE users")]
    [InlineData("SELECT 1; SELECT 2")]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("SELECT 'open")]
    [InlineData("SELECT 1 /* open")]
    public void MalformedOrMultipleStatementsAreRefused(string sql)
    {
        var ex = Assert.Throws<McpToolException>(() => McpStatementGate.Analyze(sql, Postgres, 100 * 1024));

        Assert.Equal(McpToolErrorCode.InvalidArgument, ex.Code);
    }

    [Fact]
    public void TrailingSemicolonIsDropped()
    {
        Assert.Equal("SELECT 1", McpStatementGate.Analyze("  SELECT 1;  ", Postgres, 1024).Sql);
    }

    [Fact]
    public void StatementThatTheServerCouldSplitIsRefused()
    {
        Assert.Throws<McpToolException>(() => McpStatementGate.Analyze(@"SELECT 'a\'; DELETE FROM orders; -- '", MySql, 1024));
        Assert.Throws<McpToolException>(() => McpStatementGate.Analyze(@"SELECT 'a\'; DELETE FROM orders; -- '", Postgres, 1024));
        Assert.Throws<McpToolException>(() => McpStatementGate.Analyze("SELECT 1 /*!50000 ; DELETE FROM orders */", MySql, 1024));
        Assert.True(McpStatementGate.Analyze(@"SELECT 'C:\'", Postgres, 1024).IsRead);
        Assert.True(McpStatementGate.Analyze(@"SELECT 'it\'s'", MySql, 1024).IsRead);
    }

    [Fact]
    public void SqlServerBatchIsOneUnitAndItsHiddenWritesCount()
    {
        Assert.True(McpStatementGate.Analyze("SELECT @@VERSION", SqlServer, 1024).IsRead);
        Assert.False(McpStatementGate.Analyze("SELECT 1 DROP TABLE users", SqlServer, 1024).IsRead);
        Assert.False(McpStatementGate.Analyze("SELECT 1 EXEC sp_who", SqlServer, 1024).IsRead);
        Assert.Throws<McpToolException>(() => McpStatementGate.Analyze("SELECT 1\nGO\nSELECT 2", SqlServer, 1024));
    }

    [Fact]
    public void OversizedQueryIsRefused()
    {
        var ex = Assert.Throws<McpToolException>(() => McpStatementGate.Analyze("SELECT '" + new string('x', 200) + "'", Postgres, 100));

        Assert.Contains("limit is 100", ex.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("DROP TABLE users", true)]
    [InlineData("TRUNCATE users", true)]
    [InlineData("DELETE FROM users", true)]
    [InlineData("UPDATE users SET age = 1", true)]
    [InlineData("ALTER TABLE users DROP COLUMN age", true)]
    [InlineData("DELETE FROM users WHERE id = 1", false)]
    [InlineData("INSERT INTO users (id) VALUES (1)", false)]
    public void DestructiveStatementsAreMarked(string sql, bool destructive)
    {
        Assert.Equal(destructive, McpStatementGate.Analyze(sql, Postgres, 1024).IsDestructive);
    }
}
