using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class SqlLexerTests
{
    private static readonly SqlLexerFeatures Postgres = PostgreSqlDialect.Instance.LexerFeatures;
    private static readonly SqlLexerFeatures MySql = MySqlDialect.Instance.LexerFeatures;
    private static readonly SqlLexerFeatures SqlServer = SqlServerDialect.Instance.LexerFeatures;
    private static readonly SqlLexerFeatures Sqlite = SqliteDialect.Instance.LexerFeatures;
    private static readonly SqlLexerFeatures DuckDb = DuckDbDialect.Instance.LexerFeatures;

    private static Lexeme Single(string text, SqlLexerFeatures features)
    {
        var tokens = Lexing.All(text, features);
        Assert.Single(tokens);
        return tokens[0];
    }

    [Fact]
    public void ProducesEveryTokenKind()
    {
        const string sql = "SELECT a, t.b FROM \"q\" WHERE x >= 1 AND y = ? ; -- note\n/* block */ ('s')";

        var tokens = Lexing.All(sql, Postgres);

        Assert.Equal(Enum.GetValues<SqlTokenKind>().ToHashSet(), tokens.Select(t => t.Kind).ToHashSet());
    }

    [Fact]
    public void ClassifiesASimpleStatement()
    {
        var tokens = Lexing.Significant("SELECT a, t.b FROM \"q\" WHERE x >= 1.5 AND y = ?;", Postgres);

        Assert.Equal(
            [
                new(SqlTokenKind.Word, "SELECT"),
                new(SqlTokenKind.Word, "a"),
                new(SqlTokenKind.Comma, ","),
                new(SqlTokenKind.Word, "t"),
                new(SqlTokenKind.Dot, "."),
                new(SqlTokenKind.Word, "b"),
                new(SqlTokenKind.Word, "FROM"),
                new(SqlTokenKind.QuotedIdentifier, "\"q\""),
                new(SqlTokenKind.Word, "WHERE"),
                new(SqlTokenKind.Word, "x"),
                new(SqlTokenKind.Operator, ">="),
                new(SqlTokenKind.Number, "1.5"),
                new(SqlTokenKind.Word, "AND"),
                new(SqlTokenKind.Word, "y"),
                new(SqlTokenKind.Operator, "="),
                new(SqlTokenKind.Parameter, "?"),
                new Lexeme(SqlTokenKind.Semicolon, ";"),
            ],
            tokens);
    }

    public static TheoryData<string, string> TilingCases => new()
    {
        { "SELECT * FROM t WHERE a <> 'x''y' -- c\r\n/* d */ AND b = $1;", "PostgreSQL" },
        { "SELECT `a`, \"s\\\"\" # c\nFROM t WHERE x = @v;", "MySQL" },
        { "SELECT [a]]b], N'x' FROM t\nGO 2\n", "SQL Server" },
        { "CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; END;", "SQLite" },
        { "SELECT $tag$ body $tag$, $p0, 0xFF, 1e-3 FROM 'f.parquet'", "DuckDB" },
        { "'unterminated", "PostgreSQL" },
        { "/* open", "SQL Server" },
        { "", "SQLite" },
        { "é漢字 ¤ ~^ !", "PostgreSQL" },
    };

    [Theory]
    [MemberData(nameof(TilingCases))]
    public void TokensCoverTheTextContiguously(string sql, string dialectName)
    {
        var features = DialectByName(dialectName).LexerFeatures;
        var lexer = new SqlLexer(sql, features);
        var expectedStart = 0;
        while (lexer.TryRead(out var token))
        {
            Assert.Equal(expectedStart, token.Start);
            Assert.True(token.Length > 0);
            Assert.Equal(token.End, lexer.Position);
            expectedStart = token.End;
        }

        Assert.Equal(sql.Length, expectedStart);
    }

    [Fact]
    public void StartsAtTheGivenOffset()
    {
        const string sql = "SELECT 1; SELECT 2";
        var lexer = new SqlLexer(sql, Postgres, start: 10);

        Assert.Equal(10, lexer.Position);
        Assert.True(lexer.TryRead(out var token));
        Assert.Equal("SELECT", token.Slice(sql).ToString());
        Assert.Equal(10, token.Start);
        Assert.Equal(16, token.End);
    }

    [Fact]
    public void EndOfTextReadsNothing()
    {
        var lexer = new SqlLexer("", Postgres);

        Assert.False(lexer.TryRead(out var token));
        Assert.Equal(default, token);
    }

    [Theory]
    [InlineData(SqlTokenKind.Whitespace, true)]
    [InlineData(SqlTokenKind.LineComment, true)]
    [InlineData(SqlTokenKind.BlockComment, true)]
    [InlineData(SqlTokenKind.String, false)]
    [InlineData(SqlTokenKind.Word, false)]
    [InlineData(SqlTokenKind.Semicolon, false)]
    public void TriviaIsWhitespaceAndComments(SqlTokenKind kind, bool expected) =>
        Assert.Equal(expected, new SqlToken(kind, 0, 1).IsTrivia);

    [Fact]
    public void BackticksQuoteNamesOnlyWhereSupported()
    {
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "`a``b`"), Single("`a``b`", MySql));
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "`x y`"), Single("`x y`", Sqlite));
        Assert.NotEqual(SqlTokenKind.QuotedIdentifier, Lexing.All("`a`", Postgres)[0].Kind);
    }

    [Fact]
    public void BracketsQuoteNamesOnlyWhereSupported()
    {
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "[a]]b]"), Single("[a]]b]", SqlServer));
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "[my col]"), Single("[my col]", Sqlite));

        var postgres = Lexing.Significant("arr[1]", Postgres);
        Assert.DoesNotContain(postgres, t => t.Kind == SqlTokenKind.QuotedIdentifier);
        Assert.Contains(new Lexeme(SqlTokenKind.Number, "1"), postgres);
    }

    [Fact]
    public void DoubleQuotesAreNamesExceptInMySql()
    {
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "\"a\"\"b\""), Single("\"a\"\"b\"", Postgres));
        Assert.Equal(new Lexeme(SqlTokenKind.QuotedIdentifier, "\"a\""), Single("\"a\"", SqlServer));
        Assert.Equal(new Lexeme(SqlTokenKind.String, "\"a\\\"b\""), Single("\"a\\\"b\"", MySql));
    }

    [Fact]
    public void DollarQuotedBodyIsOneString()
    {
        const string body = "$$ BEGIN RETURN 'x;y'; END; $$";

        Assert.Equal(new Lexeme(SqlTokenKind.String, body), Single(body, Postgres));
        Assert.Equal(new Lexeme(SqlTokenKind.String, body), Single(body, DuckDb));
    }

    [Fact]
    public void TaggedDollarQuoteIgnoresOtherTags()
    {
        const string body = "$fn$ SELECT $$inner$$; $other$ $fn$";

        var tokens = Lexing.Significant(body + " x", Postgres);

        Assert.Equal([new(SqlTokenKind.String, body), new(SqlTokenKind.Word, "x")], tokens);
    }

    [Fact]
    public void DollarDigitIsAPositionalParameter()
    {
        var tokens = Lexing.Significant("WHERE a = $1 AND b = $12", Postgres);

        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "$1"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "$12"), tokens);
        Assert.DoesNotContain(tokens, t => t.Kind == SqlTokenKind.String);
    }

    [Fact]
    public void DollarNameWithoutClosingDollarIsANamedParameter()
    {
        var tokens = Lexing.Significant("VALUES ($p0, $p1)", DuckDb);

        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "$p0"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "$p1"), tokens);
    }

    [Fact]
    public void DollarQuotesAreNotStringsInMySql()
    {
        var tokens = Lexing.Significant("$$ a $$", MySql);

        Assert.DoesNotContain(tokens, t => t.Kind == SqlTokenKind.String);
        Assert.Contains(new Lexeme(SqlTokenKind.Word, "a"), tokens);
    }

    [Fact]
    public void HashStartsACommentOnlyInMySql()
    {
        var mysql = Lexing.All("# note ; here\nSELECT", MySql);
        Assert.Equal(new Lexeme(SqlTokenKind.LineComment, "# note ; here"), mysql[0]);
        Assert.Equal(new Lexeme(SqlTokenKind.Word, "SELECT"), mysql[^1]);

        var postgres = Lexing.Significant("a # b", Postgres);
        Assert.Equal([new(SqlTokenKind.Word, "a"), new(SqlTokenKind.Operator, "#"), new(SqlTokenKind.Word, "b")], postgres);
    }

    [Theory]
    [InlineData("-- note")]
    [InlineData("--\tnote")]
    [InlineData("--")]
    [InlineData("--\r\n")]
    public void MySqlDashCommentNeedsWhitespaceOrEnd(string text)
    {
        var first = Lexing.All(text, MySql)[0];

        Assert.Equal(SqlTokenKind.LineComment, first.Kind);
        Assert.Equal(text.TrimEnd('\r', '\n'), first.Text);
    }

    [Fact]
    public void MySqlDashWithoutSpaceIsArithmetic()
    {
        var tokens = Lexing.Significant("SELECT 5--1", MySql);

        Assert.DoesNotContain(tokens, t => t.Kind == SqlTokenKind.LineComment);
        Assert.Equal(new Lexeme(SqlTokenKind.Number, "1"), tokens[^1]);
    }

    [Fact]
    public void OtherDialectsTreatDashDashAsACommentEverywhere()
    {
        var tokens = Lexing.Significant("SELECT 5--1", Postgres);

        Assert.Equal(new Lexeme(SqlTokenKind.LineComment, "--1"), tokens[^1]);
    }

    [Fact]
    public void LineCommentStopsAtTheLineBreak()
    {
        var tokens = Lexing.All("-- a\r\nb", Postgres);

        Assert.Equal(
            [new(SqlTokenKind.LineComment, "-- a"), new(SqlTokenKind.Whitespace, "\r\n"), new(SqlTokenKind.Word, "b")],
            tokens);
    }

    [Fact]
    public void BackslashEscapesQuotesInMySql()
    {
        Assert.Equal(new Lexeme(SqlTokenKind.String, @"'it\'s'"), Single(@"'it\'s'", MySql));
        Assert.Equal(new Lexeme(SqlTokenKind.String, @"'a\\'"), Lexing.Significant(@"'a\\' b", MySql)[0]);
    }

    [Fact]
    public void BackslashIsLiteralInStandardStrings()
    {
        var tokens = Lexing.Significant(@"'a\' AS x", Postgres);

        Assert.Equal(new Lexeme(SqlTokenKind.String, @"'a\'"), tokens[0]);
        Assert.Equal(new Lexeme(SqlTokenKind.Word, "x"), tokens[^1]);
    }

    [Fact]
    public void NestedBlockCommentsNestWhereSupported()
    {
        var postgres = Lexing.Significant("/* a /* b */ c */ x", Postgres);
        Assert.Equal([new(SqlTokenKind.BlockComment, "/* a /* b */ c */"), new(SqlTokenKind.Word, "x")], postgres);

        var sqlServer = Lexing.Significant("/* a /* b */ c */ x", SqlServer);
        Assert.Equal(SqlTokenKind.BlockComment, sqlServer[0].Kind);
        Assert.Single(sqlServer, t => t.Kind == SqlTokenKind.BlockComment);

        var mysql = Lexing.Significant("/* a /* b */ c */ x", MySql);
        Assert.Equal(new Lexeme(SqlTokenKind.BlockComment, "/* a /* b */"), mysql[0]);
        Assert.Equal(new Lexeme(SqlTokenKind.Word, "c"), mysql[1]);
    }

    [Theory]
    [InlineData("'it''s'")]
    [InlineData("''")]
    [InlineData("''''")]
    public void DoubledQuoteStaysInsideTheString(string literal)
    {
        foreach (var features in new[] { Postgres, MySql, SqlServer, Sqlite, DuckDb })
        {
            Assert.Equal(new Lexeme(SqlTokenKind.String, literal), Single(literal, features));
        }
    }

    [Theory]
    [InlineData("N'abc'")]
    [InlineData("n'abc'")]
    [InlineData("X'0AFF'")]
    [InlineData("x'0a'")]
    [InlineData("B'0101'")]
    [InlineData("E'tab'")]
    public void PrefixedLiteralIsOneString(string literal) =>
        Assert.Equal(new Lexeme(SqlTokenKind.String, literal), Single(literal, Postgres));

    [Fact]
    public void EscapeStringPrefixEnablesBackslashEscapes()
    {
        var tokens = Lexing.Significant(@"E'it\'s' x", Postgres);

        Assert.Equal(new Lexeme(SqlTokenKind.String, @"E'it\'s'"), tokens[0]);
        Assert.Equal(new Lexeme(SqlTokenKind.Word, "x"), tokens[1]);
    }

    [Fact]
    public void LongerWordBeforeAQuoteIsNotAPrefix()
    {
        var tokens = Lexing.Significant("ab'x'", Postgres);

        Assert.Equal([new(SqlTokenKind.Word, "ab"), new(SqlTokenKind.String, "'x'")], tokens);
    }

    [Theory]
    [InlineData("'abc", "PostgreSQL")]
    [InlineData("N'abc", "SQL Server")]
    [InlineData("\"abc", "PostgreSQL")]
    [InlineData("\"abc", "MySQL")]
    [InlineData("`abc", "MySQL")]
    [InlineData("[abc", "SQL Server")]
    [InlineData("/* abc", "PostgreSQL")]
    [InlineData("/* a /* b */", "PostgreSQL")]
    [InlineData("$$ abc", "PostgreSQL")]
    [InlineData("$t$ abc $$", "DuckDB")]
    [InlineData("'abc\\", "MySQL")]
    public void UnterminatedTokenRunsToTheEndAndIsMarked(string text, string dialectName)
    {
        var token = Single(text, DialectByName(dialectName).LexerFeatures);

        Assert.True(token.IsUnterminated);
        Assert.Equal(text, token.Text);
    }

    [Fact]
    public void TerminatedTokensAreNotMarked()
    {
        var tokens = Lexing.All("'a' \"b\" /* c */ $$d$$", Postgres);

        Assert.All(tokens, t => Assert.False(t.IsUnterminated));
    }

    [Fact]
    public void DoubleColonIsACastNotAParameter()
    {
        var tokens = Lexing.Significant("a::int", Postgres);

        Assert.Equal([new(SqlTokenKind.Word, "a"), new(SqlTokenKind.Operator, "::"), new(SqlTokenKind.Word, "int")], tokens);
    }

    [Fact]
    public void ColonBeforeANameIsAParameter()
    {
        var tokens = Lexing.Significant("WHERE id = :id AND x = :p::text", Postgres);

        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, ":id"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, ":p"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Operator, "::"), tokens);
        Assert.Equal(new Lexeme(SqlTokenKind.Word, "text"), tokens[^1]);
    }

    [Fact]
    public void AtSignStartsVariablesAndSystemVariables()
    {
        var tokens = Lexing.Significant("SELECT @x, @@ROWCOUNT, @@global.max_connections", SqlServer);

        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "@x"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "@@ROWCOUNT"), tokens);
        Assert.Contains(new Lexeme(SqlTokenKind.Parameter, "@@global"), tokens);
        Assert.Equal([new(SqlTokenKind.Dot, "."), new(SqlTokenKind.Word, "max_connections")], tokens[^2..]);
    }

    [Fact]
    public void LoneAtSignIsAnOperator()
    {
        var tokens = Lexing.Significant("@ 5", Postgres);

        Assert.Equal(new Lexeme(SqlTokenKind.Operator, "@"), tokens[0]);
    }

    [Theory]
    [InlineData("42")]
    [InlineData("3.14")]
    [InlineData(".5")]
    [InlineData("1.")]
    [InlineData("1e10")]
    [InlineData("1.5E-3")]
    [InlineData("2e+4")]
    [InlineData("0xFF")]
    [InlineData("0XaB09")]
    [InlineData("1_000_000")]
    public void NumberIsOneToken(string number) =>
        Assert.Equal(new Lexeme(SqlTokenKind.Number, number), Single(number, Postgres));

    [Fact]
    public void ExponentNeedsDigits()
    {
        var tokens = Lexing.Significant("1e", Postgres);

        Assert.Equal([new(SqlTokenKind.Number, "1"), new(SqlTokenKind.Word, "e")], tokens);
    }

    [Fact]
    public void NumberFollowedByLettersSplits()
    {
        var tokens = Lexing.Significant("123abc", Postgres);

        Assert.Equal([new(SqlTokenKind.Number, "123"), new(SqlTokenKind.Word, "abc")], tokens);
    }

    [Fact]
    public void DotBetweenNamesIsADot()
    {
        var tokens = Lexing.Significant("s.t", Postgres);

        Assert.Equal([new(SqlTokenKind.Word, "s"), new(SqlTokenKind.Dot, "."), new(SqlTokenKind.Word, "t")], tokens);
    }

    [Theory]
    [InlineData("café_1")]
    [InlineData("_private")]
    [InlineData("a$b")]
    [InlineData("表")]
    public void WordsIncludeLettersDigitsUnderscoreAndDollar(string word) =>
        Assert.Equal(new Lexeme(SqlTokenKind.Word, word), Single(word, Postgres));

    [Theory]
    [InlineData("<>")]
    [InlineData("!=")]
    [InlineData("||")]
    [InlineData("<=")]
    [InlineData("->>")]
    [InlineData("~*")]
    public void OperatorCharactersGroup(string op) =>
        Assert.Equal(new Lexeme(SqlTokenKind.Operator, op), Single(op, Postgres));

    [Fact]
    public void OperatorStopsBeforeAComment()
    {
        var tokens = Lexing.Significant("=--x\n*/*c*/", Postgres);

        Assert.Equal(
            [
                new(SqlTokenKind.Operator, "="),
                new(SqlTokenKind.LineComment, "--x"),
                new(SqlTokenKind.Operator, "*"),
                new(SqlTokenKind.BlockComment, "/*c*/"),
            ],
            tokens);
    }

    [Fact]
    public void KeywordAndFunctionLookupsIgnoreCase()
    {
        Assert.True(SqlKeywords.IsKeyword("select"));
        Assert.True(SqlKeywords.IsKeyword("Returning"));
        Assert.False(SqlKeywords.IsKeyword("customers"));
        Assert.True(SqlKeywords.IsFunction("count"));
        Assert.True(SqlKeywords.IsFunction("ROW_NUMBER"));
        Assert.False(SqlKeywords.IsFunction("select"));
    }

    internal static SqlDialect DialectByName(string name) => name switch
    {
        "PostgreSQL" => PostgreSqlDialect.Instance,
        "MySQL" => MySqlDialect.Instance,
        "MariaDB" => MySqlDialect.MariaDb,
        "SQL Server" => SqlServerDialect.Instance,
        "SQLite" => SqliteDialect.Instance,
        "DuckDB" => DuckDbDialect.Instance,
        _ => throw new ArgumentOutOfRangeException(nameof(name), name, null),
    };
}
