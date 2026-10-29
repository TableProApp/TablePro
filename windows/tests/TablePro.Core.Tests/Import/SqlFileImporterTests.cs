using System.Runtime.CompilerServices;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;
using TablePro.Core.Import;
using TablePro.Core.Results;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Import;

public sealed class SqlFileImporterTests
{
    /// <summary>Runs nothing; a statement containing FAIL fails, and every call is recorded with its options.</summary>
    private sealed class FakeChannel : IQueryChannel
    {
        public List<string> Executed { get; } = [];

        public List<int> BatchSizes { get; } = [];

        public async IAsyncEnumerable<StatementResult> ExecuteAsync(IReadOnlyList<string> statements, ExecuteOptions options, [EnumeratorCancellation] CancellationToken cancellationToken)
        {
            await Task.Yield();
            BatchSizes.Add(statements.Count);
            foreach (var sql in statements)
            {
                Executed.Add(sql);
                var failed = sql.Contains("FAIL", StringComparison.Ordinal);
                yield return new StatementResult(sql, [], 1, TimeSpan.Zero, failed ? "syntax error near FAIL" : null);
                if (failed && options.StopOnError)
                {
                    yield break;
                }
            }
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    private static Task<SqlImportResult> Import(FakeChannel channel, string script, SqlImportOptions options, DatabaseEngine engine = DatabaseEngine.Sqlite, SqlDialect? dialect = null) =>
        SqlFileImporter.ImportAsync(channel, new StringReader(script), dialect ?? SqliteDialect.Instance, engine, options, null, script.Length, null, TestContext.Current.CancellationToken);

    [Fact]
    public async Task RunsEveryStatementInsideOneTransactionWithForeignKeysOff()
    {
        var channel = new FakeChannel();
        var result = await Import(channel, "CREATE TABLE a (id INTEGER);\nINSERT INTO a VALUES (1);\nINSERT INTO a VALUES (2);", new SqlImportOptions());

        Assert.Equal(3, result.Executed);
        Assert.Equal(0, result.Skipped);
        Assert.Equal("PRAGMA foreign_keys = OFF", channel.Executed[0]);
        Assert.Equal("BEGIN", channel.Executed[1]);
        Assert.Equal("COMMIT", channel.Executed[^2]);
        Assert.Equal("PRAGMA foreign_keys = ON", channel.Executed[^1]);
    }

    [Fact]
    public async Task StopAndRollbackRollsBackAndNamesTheLine()
    {
        var channel = new FakeChannel();
        var error = await Assert.ThrowsAsync<SqlImportException>(() =>
            Import(channel, "INSERT INTO a VALUES (1);\n\nINSERT FAIL;\nINSERT INTO a VALUES (3);", new SqlImportOptions(DisableForeignKeyChecks: false)));

        Assert.Equal(3, error.Failure!.Line);
        Assert.Equal(1, error.Executed);
        Assert.Contains("Line 3: syntax error near FAIL", error.Message, StringComparison.Ordinal);
        Assert.Equal("ROLLBACK", channel.Executed[^1]);
        Assert.DoesNotContain(channel.Executed, s => s.Contains("(3)", StringComparison.Ordinal));
    }

    [Fact]
    public async Task StopAndCommitKeepsWhatRan()
    {
        var channel = new FakeChannel();
        await Assert.ThrowsAsync<SqlImportException>(() =>
            Import(channel, "INSERT INTO a VALUES (1);\nINSERT FAIL;", new SqlImportOptions(SqlImportErrorHandling.StopAndCommit, DisableForeignKeyChecks: false)));
        Assert.Equal("COMMIT", channel.Executed[^1]);
    }

    [Fact]
    public async Task SkipAndContinueRecordsFailuresAndUsesNoTransaction()
    {
        var channel = new FakeChannel();
        var result = await Import(channel, "INSERT INTO a VALUES (1);\nFAIL one;\nINSERT INTO a VALUES (2);\nFAIL two;", new SqlImportOptions(SqlImportErrorHandling.SkipAndContinue, DisableForeignKeyChecks: false));

        Assert.Equal(2, result.Executed);
        Assert.Equal(2, result.Skipped);
        Assert.Equal([2, 4], result.Errors.Select(e => e.Line));
        Assert.DoesNotContain("BEGIN", channel.Executed);
        Assert.DoesNotContain("COMMIT", channel.Executed);
    }

    [Fact]
    public async Task SendsStatementsInBatches()
    {
        var channel = new FakeChannel();
        var script = string.Concat(Enumerable.Range(0, 7).Select(i => $"INSERT INTO a VALUES ({i});\n"));
        await Import(channel, script, new SqlImportOptions(WrapInTransaction: false, DisableForeignKeyChecks: false, BatchSize: 3));
        Assert.Equal([3, 3, 1], channel.BatchSizes);
    }

    [Fact]
    public async Task TheDumpsOwnTransactionIsAbsorbedByTheImports()
    {
        // sqlite3 .dump writes BEGIN TRANSACTION and COMMIT, which would nest inside the import's own transaction.
        var channel = new FakeChannel();
        var result = await Import(channel, "BEGIN TRANSACTION;\nCREATE TABLE a (id INTEGER);\nCOMMIT;", new SqlImportOptions(DisableForeignKeyChecks: false));

        Assert.Equal(1, result.Executed);
        Assert.Equal(3, channel.Executed.Count);
        Assert.Equal("BEGIN", channel.Executed[0]);
        Assert.StartsWith("CREATE TABLE a", channel.Executed[1], StringComparison.Ordinal);
        Assert.Equal("COMMIT", channel.Executed[2]);
    }

    [Fact]
    public async Task EnginesWithoutTransactionsRunStatementsAlone()
    {
        var channel = new FakeChannel();
        await Import(channel, "INSERT INTO a VALUES (1);", new SqlImportOptions(), DatabaseEngine.ClickHouse, ClickHouseDialect.Instance);
        Assert.Single(channel.Executed);
    }

    [Theory]
    [InlineData("BEGIN", true)]
    [InlineData("begin transaction;", true)]
    [InlineData("START TRANSACTION", true)]
    [InlineData("BEGIN IMMEDIATE TRANSACTION", true)]
    [InlineData("COMMIT;", true)]
    [InlineData("END TRANSACTION", true)]
    [InlineData("BEGIN DBMS_OUTPUT.PUT_LINE('x'); END;", false)]
    [InlineData("ROLLBACK TO SAVEPOINT a", false)]
    [InlineData("COMMENT ON TABLE a IS 'x'", false)]
    public void RecognizesStandaloneTransactionStatements(string sql, bool expected) => Assert.Equal(expected, SqlFileImporter.IsTransactionControl(sql));

    [Fact]
    public async Task SplitsAcrossChunksWithoutLosingOrCuttingStatements()
    {
        var script = "INSERT INTO a VALUES ('first; still first');\n-- comment\nINSERT INTO a VALUES ('second');\nINSERT INTO a VALUES ('a much longer third statement');\n";
        var statements = new List<(string Sql, int Line)>();
        await foreach (var statement in SqlFileImporter.ReadStatementsAsync(new StringReader(script), SqliteDialect.Instance, 16, TestContext.Current.CancellationToken))
        {
            statements.Add(statement);
        }

        Assert.Equal(3, statements.Count);
        Assert.Contains("first; still first", statements[0].Sql, StringComparison.Ordinal);
        Assert.Contains("'second'", statements[1].Sql, StringComparison.Ordinal);
        Assert.Contains("third", statements[2].Sql, StringComparison.Ordinal);
        Assert.Equal(1, statements[0].Line);
        Assert.Equal(4, statements[2].Line);
    }

    [Fact]
    public async Task MySqlDelimiterSurvivesAChunkBoundary()
    {
        var script = "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$\nCREATE PROCEDURE q() BEGIN SELECT 3; END$$\nDELIMITER ;\nSELECT 4;\n";
        var statements = new List<string>();
        await foreach (var statement in SqlFileImporter.ReadStatementsAsync(new StringReader(script), MySqlDialect.Instance, 24, TestContext.Current.CancellationToken))
        {
            statements.Add(statement.Sql);
        }

        Assert.Equal(3, statements.Count);
        Assert.Contains("SELECT 1; SELECT 2;", statements[0], StringComparison.Ordinal);
        Assert.Contains("SELECT 3;", statements[1], StringComparison.Ordinal);
        Assert.Contains("SELECT 4", statements[2], StringComparison.Ordinal);
    }

    [Fact]
    public async Task ASqlServerBatchEndedByGoWithACountRunsThatManyTimes()
    {
        var statements = new List<string>();
        await foreach (var statement in SqlFileImporter.ReadStatementsAsync(new StringReader("INSERT INTO t VALUES (1)\nGO 3\nSELECT 2\n"), SqlServerDialect.Instance, 8, TestContext.Current.CancellationToken))
        {
            statements.Add(statement.Sql);
        }

        Assert.Equal(["INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (1)", "INSERT INTO t VALUES (1)", "SELECT 2"], statements);
    }

    [Fact]
    public void StatementsPerEngine()
    {
        Assert.Equal("SET FOREIGN_KEY_CHECKS=0", SqlImportStatements.For(DatabaseEngine.MySql).ForeignKeysOff);
        Assert.Contains("session_replication_role = replica", SqlImportStatements.For(DatabaseEngine.PostgreSql).ForeignKeysOff, StringComparison.Ordinal);
        Assert.Equal("BEGIN TRANSACTION", SqlImportStatements.For(DatabaseEngine.SqlServer).Begin);
        Assert.Null(SqlImportStatements.For(DatabaseEngine.Oracle).Begin);
        Assert.True(SqlImportStatements.For(DatabaseEngine.Oracle).SupportsTransactions);
        Assert.False(SqlImportStatements.For(DatabaseEngine.MongoDb).SupportsTransactions);
    }

    [Fact]
    public async Task ReadsAGzipFile()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tablepro-import-{Guid.NewGuid():N}.sql.gz");
        try
        {
            await using (var file = File.Create(path))
            await using (var gzip = new System.IO.Compression.GZipStream(file, System.IO.Compression.CompressionLevel.Fastest))
            await using (var writer = new StreamWriter(gzip))
            {
                await writer.WriteAsync("INSERT INTO a VALUES (1);\nINSERT INTO a VALUES (2);\n");
            }

            var channel = new FakeChannel();
            var progress = new List<SqlImportProgress>();
            var result = await SqlFileImporter.ImportFileAsync(channel, path, SqliteDialect.Instance, DatabaseEngine.Sqlite, new SqlImportOptions(WrapInTransaction: false, DisableForeignKeyChecks: false), new SyncProgress(progress), TestContext.Current.CancellationToken);

            Assert.Equal(2, result.Executed);
            Assert.NotEmpty(progress);
            Assert.Equal(2, progress[^1].Executed);
            Assert.True(progress[^1].TotalBytes > 0);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task ReadsAFileInTheChosenEncoding()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tablepro-import-{Guid.NewGuid():N}.sql");
        try
        {
            var windows1252 = SqlImportEncoding.Find("Windows-1252")!;
            await File.WriteAllBytesAsync(path, windows1252.GetEncoding().GetBytes("INSERT INTO a VALUES ('\x20ac \x201cquoted\x201d');\n"), TestContext.Current.CancellationToken);

            var channel = new FakeChannel();
            await SqlFileImporter.ImportFileAsync(channel, path, SqliteDialect.Instance, DatabaseEngine.Sqlite, new SqlImportOptions(WrapInTransaction: false, DisableForeignKeyChecks: false, Encoding: windows1252), null, TestContext.Current.CancellationToken);

            Assert.Equal("INSERT INTO a VALUES ('\x20ac \x201cquoted\x201d')", channel.Executed.Single().Trim());
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Theory]
    [InlineData("-- MySQL dump\n/*!40101 SET NAMES latin1 */;\nCREATE TABLE a (b int);", "Windows-1252")]
    [InlineData("/*!40101 SET NAMES utf8mb4 */;", "UTF-8")]
    [InlineData("SET NAMES sjis;", "Shift_JIS")]
    [InlineData("SET character_set_client = gbk;", "GB18030")]
    public void ReadsTheEncodingAMySqlDumpDeclares(string head, string expected) =>
        Assert.Equal(expected, SqlDumpEncoding.Declared(head, MySqlDialect.Instance)?.Id);

    [Theory]
    [InlineData("SET statement_timeout = 0;\nSET client_encoding = 'WIN1252';", "Windows-1252")]
    [InlineData("SET client_encoding TO 'LATIN1';", "Latin1")]
    [InlineData("SET client_encoding = 'EUC_KR';", "EUC-KR")]
    public void ReadsTheEncodingAPostgreSqlDumpDeclares(string head, string expected) =>
        Assert.Equal(expected, SqlDumpEncoding.Declared(head, PostgreSqlDialect.Instance)?.Id);

    [Theory]
    [InlineData("CREATE TABLE a (b int);")]
    [InlineData("SET NAMES klingon;")]
    [InlineData("INSERT INTO a VALUES ('SET NAMES latin1');")]
    public void ADumpWithoutAKnownDeclarationKeepsTheChoice(string head) =>
        Assert.Null(SqlDumpEncoding.Declared(head, MySqlDialect.Instance));

    [Fact]
    public void EveryOfferedEncodingCanBeRead() =>
        Assert.All(SqlImportEncoding.All, e => Assert.NotNull(e.GetEncoding()));

    private sealed class SyncProgress(List<SqlImportProgress> reports) : IProgress<SqlImportProgress>
    {
        public void Report(SqlImportProgress value) => reports.Add(value);
    }
}
