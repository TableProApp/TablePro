using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class SqlScriptTests
{
    private static string[] Texts(string sql, SqlDialect dialect) => [.. SqlScript.Split(sql, dialect).Select(s => s.Text)];

    [Fact]
    public void SplitsAtSemicolonsWithOffsets()
    {
        const string sql = "SELECT 1; SELECT 2;";

        var statements = SqlScript.Split(sql, PostgreSqlDialect.Instance);

        Assert.Equal(2, statements.Length);
        Assert.Equal(new SqlStatement(0, 8, "SELECT 1"), statements[0]);
        Assert.Equal(new SqlStatement(10, 8, "SELECT 2"), statements[1]);
        Assert.All(statements, s => Assert.Equal(s.Text, sql[s.Start..s.End]));
    }

    [Fact]
    public void RejectsNullArguments()
    {
        Assert.Throws<ArgumentNullException>(() => SqlScript.Split(null!, PostgreSqlDialect.Instance));
        Assert.Throws<ArgumentNullException>(() => SqlScript.Split("SELECT 1", null!));
    }

    [Theory]
    [InlineData("SELECT 'a;b'; SELECT 2", "PostgreSQL")]
    [InlineData("SELECT E'a\\';b'; SELECT 2", "PostgreSQL")]
    [InlineData("SELECT 'a\\';b'; SELECT 2", "MySQL")]
    [InlineData("SELECT \"a;b\"; SELECT 2", "MySQL")]
    [InlineData("SELECT N'a;b'; SELECT 2", "SQLite")]
    public void SemicolonInsideAStringDoesNotSplit(string sql, string dialectName)
    {
        var texts = Texts(sql, SqlLexerTests.DialectByName(dialectName));

        Assert.Equal(2, texts.Length);
        Assert.Equal("SELECT 2", texts[1]);
    }

    [Theory]
    [InlineData("SELECT 1 -- x;y\n; SELECT 2", "PostgreSQL")]
    [InlineData("SELECT 1 /* ; */; SELECT 2", "PostgreSQL")]
    [InlineData("SELECT 1 # x;y\n; SELECT 2", "MySQL")]
    [InlineData("SELECT 1 /* /* ; */ ; */; SELECT 2", "DuckDB")]
    public void SemicolonInsideACommentDoesNotSplit(string sql, string dialectName) =>
        Assert.Equal(["SELECT 1", "SELECT 2"], Texts(sql, SqlLexerTests.DialectByName(dialectName)));

    [Theory]
    [InlineData("SELECT \"a;b\" FROM t; SELECT 2", "PostgreSQL")]
    [InlineData("SELECT `a;b` FROM t; SELECT 2", "MySQL")]
    [InlineData("SELECT [a;b] FROM t; SELECT 2", "SQLite")]
    public void SemicolonInsideAQuotedNameDoesNotSplit(string sql, string dialectName)
    {
        var texts = Texts(sql, SqlLexerTests.DialectByName(dialectName));

        Assert.Equal(2, texts.Length);
        Assert.EndsWith(" FROM t", texts[0], StringComparison.Ordinal);
    }

    [Fact]
    public void LeadingAndTrailingTriviaIsTrimmed()
    {
        var texts = Texts("  /* intro */\n  SELECT 1 -- tail\n ;\n", PostgreSqlDialect.Instance);

        Assert.Equal(["SELECT 1"], texts);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   \n\t ")]
    [InlineData(";;;")]
    [InlineData("-- only a comment")]
    [InlineData("/* c */ ; -- d\n;")]
    public void EmptyStatementsAreDropped(string sql) => Assert.Empty(SqlScript.Split(sql, PostgreSqlDialect.Instance));

    [Fact]
    public void EmptyStatementsBetweenRealOnesAreDropped() =>
        Assert.Equal(["SELECT 1", "SELECT 2"], Texts(";; SELECT 1;;; ;SELECT 2;;", PostgreSqlDialect.Instance));

    [Fact]
    public void TrailingTextWithoutSemicolonIsAStatement() =>
        Assert.Equal(["SELECT 1", "SELECT 2\nFROM t"], Texts("SELECT 1;\nSELECT 2\nFROM t  \n", SqliteDialect.Instance));

    [Fact]
    public void SqlServerSplitsAtGoLines()
    {
        const string sql = "SELECT 1\nGO\nSELECT 2\nGO\n";

        var statements = SqlScript.Split(sql, SqlServerDialect.Instance);

        Assert.Equal(["SELECT 1", "SELECT 2"], statements.Select(s => s.Text));
        Assert.Equal(sql.IndexOf("SELECT 2", StringComparison.Ordinal), statements[1].Start);
    }

    [Fact]
    public void SqlServerKeepsSemicolonsInsideABatch() =>
        Assert.Equal(["SELECT 1; SELECT 2;"], Texts("SELECT 1; SELECT 2;", SqlServerDialect.Instance));

    [Theory]
    [InlineData("SELECT 1\nGO 5\nSELECT 2")]
    [InlineData("SELECT 1\nGO -- run it\nSELECT 2")]
    [InlineData("SELECT 1\nGO 3 -- three times\nSELECT 2")]
    [InlineData("SELECT 1\ngo\nSELECT 2")]
    [InlineData("SELECT 1\n   Go   \nSELECT 2")]
    [InlineData("SELECT 1\r\nGO\r\nSELECT 2")]
    [InlineData("GO\nSELECT 1\nGO\nGO\nSELECT 2\nGO")]
    public void GoSeparatorVariants(string sql) =>
        Assert.Equal(["SELECT 1", "SELECT 2"], Texts(sql, SqlServerDialect.Instance));

    [Theory]
    [InlineData("SELECT '\nGO\n' AS x")]
    [InlineData("SELECT 1\n/*\nGO\n*/\nSELECT 2")]
    [InlineData("SELECT 1 GO")]
    [InlineData("SELECT 1\nGO x\nSELECT 2")]
    [InlineData("SELECT 1\nGOTO done\nSELECT 2")]
    [InlineData("SELECT [\nGO\n] FROM t")]
    public void GoThatIsNotASeparatorLineStaysInTheBatch(string sql) =>
        Assert.Equal([sql.Trim()], Texts(sql, SqlServerDialect.Instance));

    [Fact]
    public void GoIsOnlyASeparatorForSqlServer() =>
        Assert.Equal(["SELECT 1\nGO\nSELECT 2"], Texts("SELECT 1\nGO\nSELECT 2", PostgreSqlDialect.Instance));

    [Fact]
    public void MySqlDelimiterKeepsAProcedureBodyWhole()
    {
        const string sql = """
            DELIMITER //
            CREATE PROCEDURE p()
            BEGIN
              SELECT 1;
              SELECT 'a//b';
            END//
            DELIMITER ;
            CALL p();
            SELECT 3;
            """;

        var texts = Texts(sql, MySqlDialect.Instance);

        Assert.Equal(
            [
                "CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\n  SELECT 'a//b';\nEND".ReplaceLineEndings(),
                "CALL p()",
                "SELECT 3",
            ],
            texts.Select(t => t.ReplaceLineEndings()));
    }

    [Fact]
    public void MySqlDelimiterGluedToEndKeyword()
    {
        const string sql = "DELIMITER $$\nCREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND$$\nDELIMITER ;\nSELECT 2;";

        var texts = Texts(sql, MySqlDialect.Instance);

        Assert.Equal(["CREATE PROCEDURE p()\nBEGIN\n  SELECT 1;\nEND", "SELECT 2"], texts);
    }

    [Fact]
    public void MySqlDelimiterGluedToAnOperator()
    {
        const string sql = "delimiter //\nSELECT *//\nSELECT 2//";

        Assert.Equal(["SELECT *", "SELECT 2"], Texts(sql, MySqlDialect.Instance));
    }

    [Fact]
    public void MySqlDelimiterSeparatesStatementsOnOneLine() =>
        Assert.Equal(["SELECT 1", "SELECT 2"], Texts("DELIMITER |\nSELECT 1|SELECT 2|", MySqlDialect.Instance));

    [Fact]
    public void DelimiterDirectiveOnlyAppliesToMySql()
    {
        var texts = Texts("DELIMITER //\nSELECT 1//", PostgreSqlDialect.Instance);

        Assert.Equal(["DELIMITER //\nSELECT 1//"], texts);
    }

    [Fact]
    public void SqliteKeepsATriggerBodyWithCaseWhole()
    {
        const string trigger = """
            CREATE TRIGGER trg AFTER INSERT ON t
            BEGIN
              UPDATE c SET n = CASE WHEN n IS NULL THEN 1 ELSE n + 1 END;
              INSERT INTO log VALUES (NEW.id);
            END
            """;

        var texts = Texts(trigger + ";\nSELECT 1;", SqliteDialect.Instance);

        Assert.Equal([trigger, "SELECT 1"], texts);
    }

    [Fact]
    public void SqliteKeepsATemporaryTriggerWhole()
    {
        const string sql = "CREATE TEMP TRIGGER IF NOT EXISTS t BEFORE DELETE ON x BEGIN SELECT 1; SELECT 2; END; DELETE FROM x;";

        Assert.Equal(
            ["CREATE TEMP TRIGGER IF NOT EXISTS t BEFORE DELETE ON x BEGIN SELECT 1; SELECT 2; END", "DELETE FROM x"],
            Texts(sql, SqliteDialect.Instance));
    }

    [Fact]
    public void SqliteTransactionBeginStillSplits() =>
        Assert.Equal(["BEGIN", "SELECT 1", "COMMIT"], Texts("BEGIN; SELECT 1; COMMIT;", SqliteDialect.Instance));

    [Fact]
    public void TriggerBodiesAreOnlyKeptForSqlite() =>
        Assert.Equal(3, SqlScript.Split("CREATE TRIGGER t BEGIN SELECT 1; SELECT 2; END;", PostgreSqlDialect.Instance).Length);

    [Fact]
    public void PostgreSqlKeepsADollarQuotedFunctionWhole()
    {
        const string function = """
            CREATE FUNCTION f() RETURNS int AS $$
            BEGIN
              RETURN 1;
            END;
            $$ LANGUAGE plpgsql
            """;

        Assert.Equal([function, "SELECT f()"], Texts(function + ";\nSELECT f();", PostgreSqlDialect.Instance));
    }

    [Fact]
    public void PostgreSqlKeepsATaggedDollarQuoteWhole()
    {
        const string sql = "DO $body$ BEGIN PERFORM 1; RAISE NOTICE '$$;'; END $body$; SELECT 2";

        Assert.Equal(["DO $body$ BEGIN PERFORM 1; RAISE NOTICE '$$;'; END $body$", "SELECT 2"], Texts(sql, PostgreSqlDialect.Instance));
    }

    [Fact]
    public void StatementAtFindsTheStatementUnderTheCaret()
    {
        const string sql = "SELECT 1;\n\nSELECT 2;  ";
        var statements = SqlScript.Split(sql, PostgreSqlDialect.Instance);
        var second = sql.IndexOf("SELECT 2", StringComparison.Ordinal);

        Assert.Equal("SELECT 1", SqlScript.StatementAt(statements, 3)?.Text);
        Assert.Equal("SELECT 1", SqlScript.StatementAt(statements, 8)?.Text);
        Assert.Equal("SELECT 2", SqlScript.StatementAt(statements, second + 2)?.Text);
        Assert.Equal("SELECT 2", SqlScript.StatementAt(statements, second)?.Text);
    }

    [Fact]
    public void StatementAtBetweenStatementsPicksThePreviousOne()
    {
        const string sql = "SELECT 1;\n\nSELECT 2;";
        var statements = SqlScript.Split(sql, PostgreSqlDialect.Instance);

        Assert.Equal("SELECT 1", SqlScript.StatementAt(statements, 10)?.Text);
    }

    [Fact]
    public void StatementAtAfterTheLastStatementPicksTheLastOne()
    {
        const string sql = "SELECT 1;\nSELECT 2;\n\n   ";
        var statements = SqlScript.Split(sql, PostgreSqlDialect.Instance);

        Assert.Equal("SELECT 2", SqlScript.StatementAt(statements, sql.Length)?.Text);
    }

    [Fact]
    public void StatementAtBeforeTheFirstStatementPicksTheFirstOne()
    {
        var statements = SqlScript.Split("\n\n  SELECT 1; SELECT 2", PostgreSqlDialect.Instance);

        Assert.Equal("SELECT 1", SqlScript.StatementAt(statements, 0)?.Text);
    }

    [Fact]
    public void StatementAtWithNoStatementsIsNull() =>
        Assert.Null(SqlScript.StatementAt([], 0));

    [Fact]
    public void StatementContainsBothEnds()
    {
        var statement = new SqlStatement(5, 3, "abc");

        Assert.Equal(8, statement.End);
        Assert.False(statement.Contains(4));
        Assert.True(statement.Contains(5));
        Assert.True(statement.Contains(8));
        Assert.False(statement.Contains(9));
    }
}
