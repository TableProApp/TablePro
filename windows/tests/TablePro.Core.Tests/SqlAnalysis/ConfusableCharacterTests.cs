using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>
/// Ported from the macOS app's SQLConfusableCharacterScannerTests, with the same messages. The characters are written
/// as four-digit \x escapes so the source shows which invisible or look-alike character each test is about.
/// </summary>
public sealed class ConfusableCharacterTests
{
    public static TheoryData<string> Engines => ["postgres", "mysql", "sqlite", "oracle", "sqlserver"];

    private static SqlDialect DialectOf(string name) => name switch
    {
        "postgres" => PostgreSqlDialect.Instance,
        "mysql" => MySqlDialect.Instance,
        "sqlite" => SqliteDialect.Instance,
        "oracle" => OracleDialect.Instance,
        _ => SqlServerDialect.Instance,
    };

    private static SqlDiagnostic[] Scan(string text, SqlDialect dialect) =>
        [.. Diagnose(text, dialect, CompletionCatalog.Empty).Where(d => d.Code == SqlDiagnosticCode.ConfusableCharacter)];

    private static SqlTextRange[] Ranges(string text, SqlDialect dialect) => [.. Scan(text, dialect).Select(d => d.Range)];

    private static SqlTextRange Last(string text, string needle)
    {
        var at = text.LastIndexOf(needle, StringComparison.Ordinal);
        return new SqlTextRange(at, needle.Length);
    }

    [Theory]
    [MemberData(nameof(Engines))]
    public void AFullWidthSemicolonIsFlaggedWhereverItEndsAStatement(string engine)
    {
        var matches = Scan("SELECT 1\xFF1B\rSELECT 2\xFF1B", DialectOf(engine));
        Assert.Equal([new SqlTextRange(8, 1), new SqlTextRange(18, 1)], matches.Select(m => m.Range));
        Assert.All(matches, m => Assert.Equal(SqlDiagnosticSeverity.Warning, m.Severity));
    }

    [Theory]
    [MemberData(nameof(Engines))]
    public void FullWidthCommasAndParenthesesAreFlagged(string engine)
    {
        Assert.Equal(
            [new SqlTextRange(12, 1), new SqlTextRange(14, 1), new SqlTextRange(15, 1)],
            Ranges("SELECT COUNT\xFF08*\xFF09\xFF0C id FROM t", DialectOf(engine)));
    }

    [Theory]
    [MemberData(nameof(Engines))]
    public void CurlyQuotesAroundAValueAreFlagged(string engine)
    {
        var matches = Scan("SELECT * FROM t WHERE name = \x2018" + "Bob\x2019 OR note = \x201Cx\x201D", DialectOf(engine));
        Assert.Equal(4, matches.Length);
        Assert.Contains("U+2018", matches[0].Message, StringComparison.Ordinal);
        Assert.Contains("U+201D", matches[3].Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData('\x00A0')]
    [InlineData('\x2000')]
    [InlineData('\x2005')]
    [InlineData('\x200A')]
    [InlineData('\x202F')]
    [InlineData('\x205F')]
    [InlineData('\x3000')]
    public void EveryNonAsciiSpaceBetweenTokensIsFlagged(char space)
    {
        var match = Assert.Single(Scan($"SELECT *{space}FROM t", MySqlDialect.Instance));
        Assert.Equal(new SqlTextRange(8, 1), match.Range);
        Assert.StartsWith("Non-ASCII space", match.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ARunOfTheSameCharacterIsOneWarning()
    {
        Assert.Equal(
            [new SqlTextRange(8, 3), new SqlTextRange(17, 2)],
            Ranges("SELECT *\x3000\x3000\x3000" + "FROM t\xFF1B\xFF1B", PostgreSqlDialect.Instance));
    }

    [Fact]
    public void DifferentCharactersSideBySideAreSeparateWarnings()
    {
        Assert.Equal([new SqlTextRange(7, 1), new SqlTextRange(8, 1)], Ranges("SELECT \xFF08\xFF09", SqliteDialect.Instance));
    }

    [Theory]
    [MemberData(nameof(Engines))]
    public void CharactersInsideQuotedTextAndCommentsAreLeftAlone(string engine)
    {
        var dialect = DialectOf(engine);
        string[] texts =
        [
            "SELECT '\x4F60\x597D\xFF0C\x4E16\x754C\xFF1B' FROM t",
            "SELECT 1 -- \xFF1B\x3000\x201C",
            "SELECT 1 /* \xFF08\x00A0\x2019 */",
            "SELECT '\x2018quoted\x2019'",
        ];
        foreach (var text in texts)
        {
            Assert.True(Scan(text, dialect).Length == 0, $"{engine} flagged {text}");
        }
    }

    [Theory]
    [MemberData(nameof(Engines))]
    public void AnUnquotedIdentifierInAnotherScriptIsLeftAlone(string engine)
    {
        var dialect = DialectOf(engine);
        Assert.Empty(Scan("SELECT \x540D\x524D FROM \x9867\x5BA2", dialect));
        Assert.Empty(Scan("SELECT * FROM \x58F2\x4E0A\xFF12\xFF10\xFF12\xFF14", dialect));
        Assert.Empty(Scan("SELECT caf\x00E9\xFF3F\xFF11", dialect));
    }

    [Fact]
    public void FullWidthLettersAndDigitsOutsideAnotherScriptAreOneWord()
    {
        var keyword = Assert.Single(Scan("\xFF33\xFF25\xFF2C\xFF25\xFF23\xFF34 1", MySqlDialect.Instance));
        Assert.Equal(new SqlTextRange(0, 6), keyword.Range);
        Assert.Equal("Full-width letters or digits. SQL needs the ASCII SELECT.", keyword.Message);

        const string digit = "SELECT * FROM t WHERE id = \xFF11";
        Assert.Equal(Range(digit, "\xFF11"), Assert.Single(Scan(digit, PostgreSqlDialect.Instance)).Range);

        const string mixed = "SELECT user\xFF3F\xFF49" + "d FROM t";
        var match = Assert.Single(Scan(mixed, SqliteDialect.Instance));
        Assert.Equal(Range(mixed, "\xFF3F\xFF49"), match.Range);
        Assert.Equal("Full-width letters or digits. SQL needs the ASCII _i.", match.Message);
    }

    [Fact]
    public void MySqlHashCommentsAreQuietAndBackslashesKeepStringsOpen()
    {
        Assert.Empty(Scan("SELECT 1 # \xFF1B", MySqlDialect.Instance));
        const string text = "SELECT 'it\\'s\xFF1B' \xFF1B";
        Assert.Equal([Last(text, "\xFF1B")], Ranges(text, MySqlDialect.Instance));
    }

    [Fact]
    public void PostgreSqlDollarQuotesEscapeStringsAndNestedCommentsAreQuiet()
    {
        const string body = "CREATE FUNCTION f() RETURNS int AS $fn$ SELECT 1\xFF1B $fn$ LANGUAGE sql\xFF1B";
        Assert.Equal([Last(body, "\xFF1B")], Ranges(body, PostgreSqlDialect.Instance));
        Assert.Empty(Scan("SELECT $$\xFF08\x3000\x201C$$", PostgreSqlDialect.Instance));

        const string escaped = "SELECT E'it\\'s\xFF1B' \xFF1B";
        Assert.Equal([Last(escaped, "\xFF1B")], Ranges(escaped, PostgreSqlDialect.Instance));

        const string nested = "SELECT 1 /* a /* b */ \xFF08 */ \xFF1B";
        Assert.Equal([Range(nested, "\xFF1B")], Ranges(nested, PostgreSqlDialect.Instance));
        Assert.Equal(2, Ranges(nested, MySqlDialect.Instance).Length);
    }

    [Fact]
    public void AHashStartsNoCommentInPostgreSqlOrSqlite()
    {
        Assert.Equal([new SqlTextRange(11, 1)], Ranges("SELECT 1 # \xFF1B", PostgreSqlDialect.Instance));
        Assert.Equal([new SqlTextRange(11, 1)], Ranges("SELECT 1 # \xFF1B", SqliteDialect.Instance));
    }

    [Fact]
    public void BracketedNamesAreQuietOnlyWhereBracketsQuoteNames()
    {
        const string text = "SELECT [\x4EF7\x683C\xFF08\x5143\xFF09], [a]]\xFF1B] FROM t\xFF1B";
        Assert.Equal([Last(text, "\xFF1B")], Ranges(text, SqlServerDialect.Instance));
        Assert.Equal(4, Ranges(text, OracleDialect.Instance).Length);
    }

    [Fact]
    public void MessagesNameTheCharacterAndItsAsciiCounterpart()
    {
        Assert.Equal("Full-width semicolon (U+FF1B). SQL reads only ; as a statement separator.", ConfusableCharacters.PunctuationMessage('\xFF1B'));
        Assert.Equal("Full-width comma (U+FF0C). SQL needs the ASCII comma (U+002C).", ConfusableCharacters.PunctuationMessage('\xFF0C'));
        Assert.Equal(
            "Full-width left parenthesis (U+FF08). SQL needs the ASCII left parenthesis (U+0028).",
            ConfusableCharacters.PunctuationMessage('\xFF08'));
        Assert.Equal("Curly quote (U+201C). SQL needs the straight quote (U+0022).", ConfusableCharacters.CurlyQuoteMessage('\x201C'));
        Assert.Equal("Curly quote (U+2019). SQL needs the straight quote (U+0027).", ConfusableCharacters.CurlyQuoteMessage('\x2019'));
        Assert.Equal("Non-ASCII space (U+3000). SQL needs an ASCII space (U+0020).", ConfusableCharacters.SpaceMessage('\x3000'));
    }

    [Fact]
    public void EveryFullWidthPunctuationMarkHasANameOfItsOwn()
    {
        for (var c = '\xFF01'; c <= '\xFF5E'; c++)
        {
            if (ConfusableCharacters.IsFullWidthWordUnit(c))
            {
                continue;
            }

            var ascii = (char)(c - 0xFEE0);
            Assert.DoesNotContain($"ASCII {ascii} (", ConfusableCharacters.PunctuationMessage(c), StringComparison.Ordinal);
        }
    }

    [Fact]
    public void AConfusableCharacterIsAWarningAndAStrayCloserStillAnError()
    {
        var diagnostics = Diagnose("SELECT 1)\xFF1B", MySqlDialect.Instance);
        Assert.Equal([SqlDiagnosticSeverity.Error, SqlDiagnosticSeverity.Warning], diagnostics.Select(d => d.Severity));
        Assert.Equal([new SqlTextRange(8, 1), new SqlTextRange(9, 1)], diagnostics.Select(d => d.Range));
    }
}
