using TablePro.Core.Sql;
using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;
using Analyzed = TablePro.Core.Sql.Analysis.SqlAnalysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>
/// The property that matters most is restraint, as on macOS: a half-typed statement is never flagged. Only problems
/// more typing at the caret cannot fix are reported.
/// </summary>
public sealed class StructureDiagnosticsTests
{
    private static readonly CompletionCatalog NoCatalog = CompletionCatalog.Empty;

    [Fact]
    public void AHalfTypedStatementIsQuiet()
    {
        Assert.Empty(Diagnose("SELECT * FROM users WHERE (id =", catalog: NoCatalog));
        Assert.Empty(Diagnose("SELECT * FROM users WHERE name = 'ali", catalog: NoCatalog));
        Assert.Empty(Diagnose("SELECT \"na", catalog: NoCatalog));
    }

    [Fact]
    public void EmptyAndValidTextIsQuiet()
    {
        Assert.Empty(Diagnose(string.Empty));
        Assert.Empty(Diagnose("   \r  "));
        Assert.Empty(Diagnose("SELECT * FROM users WHERE id = 1;"));
        Assert.Empty(Diagnose("SELECT COUNT(*) FROM orders WHERE total > (SELECT AVG(total) FROM orders);"));
    }

    [Fact]
    public void AClosingParenthesisWithNoOpenerIsAnError()
    {
        var diagnostic = Assert.Single(Diagnose("SELECT * FROM users)"));
        Assert.Equal(new SqlTextRange(19, 1), diagnostic.Range);
        Assert.Equal(SqlDiagnosticSeverity.Error, diagnostic.Severity);
        Assert.Equal(SqlDiagnosticCode.UnmatchedClosingBracket, diagnostic.Code);
        Assert.Equal("No matching opening bracket", diagnostic.Message);
    }

    [Fact]
    public void AMismatchedBracketKindIsReported()
    {
        Assert.Contains(SqlDiagnosticCode.UnmatchedClosingBracket, Codes("SELECT arr[1) FROM t", catalog: NoCatalog));
    }

    [Fact]
    public void AnUnterminatedBlockCommentIsReportedAtItsOpener()
    {
        var diagnostic = Assert.Single(Diagnose("SELECT 1 /* open"));
        Assert.Equal(SqlDiagnosticCode.UnterminatedComment, diagnostic.Code);
        Assert.Equal("Unterminated comment", diagnostic.Message);
        Assert.Equal(new SqlTextRange(9, 2), diagnostic.Range);
    }

    [Fact]
    public void BracketsInsideStringsAndCommentsDoNotCount()
    {
        Assert.Empty(Diagnose("SELECT ')' FROM users"));
        Assert.Empty(Diagnose("SELECT 1 -- )\r"));
        Assert.Empty(Diagnose("SELECT 1 /* ) */"));
    }

    [Fact]
    public void ADoubleSlashIsNoCommentInSql()
    {
        Assert.Single(Diagnose("SELECT 1 // )"));
    }

    [Fact]
    public void AnUnclosedParenthesisIsReportedOnceTheCaretLeavesItsStatement()
    {
        const string text = "SELECT (1 FROM users;\rSELECT 2;";
        Assert.Empty(Diagnose(text, caret: At(text, "1 FROM")));

        var diagnostic = Assert.Single(Diagnose(text, caret: text.Length));
        Assert.Equal(SqlDiagnosticCode.UnclosedBracket, diagnostic.Code);
        Assert.Equal(Range(text, "("), diagnostic.Range);
        Assert.Equal("No matching closing parenthesis", diagnostic.Message);
    }

    [Fact]
    public void TheCaretJustBeforeTheSemicolonIsStillInsideTheStatement()
    {
        const string text = "SELECT (1;";
        Assert.Empty(Diagnose(text, caret: text.Length - 1));
        Assert.Single(Diagnose(text, caret: text.Length));
    }

    [Fact]
    public void AnUnterminatedStringIsReportedOnceTheCaretIsBeforeIt()
    {
        const string text = "SELECT 1;\rSELECT 'open";
        Assert.Empty(Diagnose(text, caret: text.Length));

        var diagnostic = Assert.Single(Diagnose(text, caret: 3));
        Assert.Equal(SqlDiagnosticCode.UnterminatedString, diagnostic.Code);
        Assert.Equal(new SqlTextRange(At(text, "'"), 1), diagnostic.Range);
    }

    [Fact]
    public void AnUnterminatedPrefixedStringMarksItsPrefixAndQuote()
    {
        const string text = "SELECT 1; SELECT E'open";
        var diagnostic = Assert.Single(Diagnose(text, caret: 0));
        Assert.Equal(Range(text, "E'"), diagnostic.Range);
    }

    [Fact]
    public void AnUnterminatedQuotedNameIsReported()
    {
        var diagnostic = Assert.Single(Diagnose("SELECT 1; SELECT \"open", caret: 0, catalog: NoCatalog));
        Assert.Equal(SqlDiagnosticCode.UnterminatedQuotedName, diagnostic.Code);
    }

    [Fact]
    public void BracketsAreBalancedPerStatement()
    {
        // The second statement's closer does not close the first statement's opener.
        const string text = "SELECT (1;\rSELECT 2);";
        var codes = Codes(text, caret: text.Length);
        Assert.Equal([SqlDiagnosticCode.UnclosedBracket, SqlDiagnosticCode.UnmatchedClosingBracket], codes);
    }

    [Fact]
    public void SqlServerBracketNamesAreNotBrackets()
    {
        Assert.Empty(Diagnose("SELECT [order id] FROM [orders]", SqlServerDialect.Instance, NoCatalog));
    }

    [Fact]
    public void ArraySubscriptsAndBracesBalance()
    {
        Assert.Empty(Diagnose("SELECT arr[-1], arr[1:2], {fn NOW()} FROM t", catalog: NoCatalog));
        Assert.Single(Diagnose("SELECT arr[1]] FROM t", catalog: NoCatalog));
    }

    [Fact]
    public void ACommandLanguageGetsNoSqlDiagnostics()
    {
        Assert.Empty(Diagnose("GET key)", RedisDialect.Instance));
    }

    [Fact]
    public void TextPastTheLimitIsNotDiagnosed()
    {
        var text = "SELECT 1)" + new string(' ', SqlAnalyzer.MaximumDiagnosedLength);
        Assert.Empty(Diagnose(text));
        Assert.NotEmpty(Diagnose("SELECT 1)"));
    }

    [Fact]
    public void MovingTheCaretOutOfAnOpenStatementChangesTheResult()
    {
        const string text = "SELECT (1;\rSELECT 2;";
        var analysis = Analyze(text, caret: 5 + 3);
        Assert.Empty(analysis.Diagnostics);
        Assert.False(analysis.CaretChangesResult(9));
        Assert.True(analysis.CaretChangesResult(text.Length));
        Assert.False(Analyze("SELECT 1;").CaretChangesResult(0));
    }

    [Fact]
    public void DiagnosticsAreOrderedByPosition()
    {
        const string text = "SELECT 1) /* x";
        var diagnostics = Diagnose(text);
        Assert.Equal([SqlDiagnosticCode.UnmatchedClosingBracket, SqlDiagnosticCode.UnterminatedComment], diagnostics.Select(d => d.Code));
    }

    [Fact]
    public void NextAndPreviousWrapAroundTheText()
    {
        var diagnostics = Diagnose("SELECT 1); SELECT 2);");
        Assert.Equal(2, diagnostics.Length);
        Assert.Equal(diagnostics[0], Analyzed.Next(diagnostics, 0, forward: true));
        Assert.Equal(diagnostics[1], Analyzed.Next(diagnostics, diagnostics[0].Start, forward: true));
        Assert.Equal(diagnostics[0], Analyzed.Next(diagnostics, diagnostics[1].Start, forward: true));
        Assert.Equal(diagnostics[1], Analyzed.Next(diagnostics, 0, forward: false));
        Assert.Equal(diagnostics[0], Analyzed.Next(diagnostics, diagnostics[1].Start, forward: false));
        Assert.Null(Analyzed.Next([], 0, forward: true));
    }
}
