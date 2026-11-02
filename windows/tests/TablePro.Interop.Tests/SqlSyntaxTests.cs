namespace TablePro.Interop.Tests;

public sealed class SqlSyntaxTests
{
    private static List<(SyntaxKind Kind, string Text)> Scan(
        SqlGrammar grammar,
        string text,
        bool? backslashEscapes = null)
    {
        var tokens = new SyntaxToken[text.Length];
        var count = SqlSyntax.Tokenize(grammar, text, tokens, backslashEscapes);
        return tokens.Take(count).Select(t => (t.Kind, text.Substring(t.Start, t.Length))).ToList();
    }

    [Fact]
    public void KeywordsMatchInAnyCaseAndWhiteSpaceIsLeftOut()
    {
        Assert.Equal(
            [
                (SyntaxKind.Keyword, "select"),
                (SyntaxKind.Identifier, "id"),
                (SyntaxKind.Operator, ","),
                (SyntaxKind.Number, "2.5"),
                (SyntaxKind.Keyword, "FrOm"),
                (SyntaxKind.QuotedIdentifier, "\"Orders\""),
                (SyntaxKind.Punctuation, ";"),
            ],
            Scan(SqlGrammar.PostgreSql, "select id, 2.5\r\nFrOm \"Orders\";"));
    }

    [Fact]
    public void OffsetsCountUtf16UnitsPastSurrogatePairsAndVietnamese()
    {
        var tokens = Scan(SqlGrammar.MySql, "-- 😀\nselect 'Đơn hàng 😀 số 1', N'tiếng việt' /* 😀 */ from t");

        Assert.Equal(
            [
                (SyntaxKind.Comment, "-- 😀"),
                (SyntaxKind.Keyword, "select"),
                (SyntaxKind.StringLiteral, "'Đơn hàng 😀 số 1'"),
                (SyntaxKind.Operator, ","),
                (SyntaxKind.Identifier, "N"),
                (SyntaxKind.StringLiteral, "'tiếng việt'"),
                (SyntaxKind.Comment, "/* 😀 */"),
                (SyntaxKind.Keyword, "from"),
                (SyntaxKind.Identifier, "t"),
            ],
            tokens);
    }

    [Fact]
    public void AnOpenBlockCommentRunsToTheEndAcrossLines()
    {
        Assert.Equal(
            [(SyntaxKind.Keyword, "select"), (SyntaxKind.Comment, "/* one\r\ntwo\nselect 1")],
            Scan(SqlGrammar.Sqlite, "select /* one\r\ntwo\nselect 1"));
    }

    [Fact]
    public void BackslashEscapesFollowTheArgumentOrTheGrammar()
    {
        const string text = @"select 'a\'b' x";

        Assert.Contains((SyntaxKind.StringLiteral, @"'a\'b'"), Scan(SqlGrammar.MySql, text));
        Assert.Contains((SyntaxKind.StringLiteral, @"'a\'b'"), Scan(SqlGrammar.MySql, text, backslashEscapes: true));
        Assert.Contains((SyntaxKind.StringLiteral, @"'a\'"), Scan(SqlGrammar.MySql, text, backslashEscapes: false));
        Assert.Contains((SyntaxKind.StringLiteral, @"'a\'"), Scan(SqlGrammar.PostgreSql, text));
    }

    [Fact]
    public void AShortSpanGetsTheFirstTokens()
    {
        var tokens = new SyntaxToken[2];

        var count = SqlSyntax.Tokenize(SqlGrammar.PostgreSql, "a b c d", tokens);

        Assert.Equal(2, count);
        Assert.Equal(new SyntaxToken(2, 1, SyntaxKind.Identifier), tokens[1]);
    }

    [Fact]
    public void ALongScriptUsesAPooledBufferAndKeepsItsOffsets()
    {
        var text = string.Concat(Enumerable.Repeat("select 'tiếng việt' from t;\n", 2_000));
        var tokens = new SyntaxToken[text.Length];

        var count = SqlSyntax.Tokenize(SqlGrammar.PostgreSql, text, tokens);

        Assert.Equal(10_000, count);
        var last = tokens[count - 1];
        Assert.Equal(SyntaxKind.Punctuation, last.Kind);
        Assert.Equal(text.Length - 2, last.Start);
    }

    [Fact]
    public void RedisAndMongoHaveNoTokensAndEmptyInputHasNone()
    {
        Assert.Empty(Scan(SqlGrammar.Redis, "GET key"));
        Assert.Empty(Scan(SqlGrammar.Mongo, "db.users.find()"));
        Assert.Empty(Scan(SqlGrammar.PostgreSql, ""));
    }

    [Fact]
    public void AnUnknownGrammarIsRefused()
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => SqlSyntax.Tokenize((SqlGrammar)42, "select 1", new SyntaxToken[8]));
    }
}
