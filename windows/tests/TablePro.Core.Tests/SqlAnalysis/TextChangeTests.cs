using TablePro.Core.Sql.Analysis;
using static TablePro.Core.Tests.SqlAnalysis.Analysis;
using Analyzed = TablePro.Core.Sql.Analysis.SqlAnalysis;

namespace TablePro.Core.Tests.SqlAnalysis;

/// <summary>Keeping the last diagnostics on their text while the next analysis runs.</summary>
public sealed class TextChangeTests
{
    [Theory]
    [InlineData("abcdef", "abXYef", 2, 2, 2)]
    [InlineData("abc", "abc!", 3, 0, 1)]
    [InlineData("abc", "c", 0, 2, 0)]
    [InlineData("aaa", "aaaa", 3, 0, 1)]
    [InlineData("", "x", 0, 0, 1)]
    [InlineData("same", "same", 4, 0, 0)]
    public void TheChangeIsTheRangeBetweenTheCommonPrefixAndSuffix(string before, string after, int start, int oldLength, int newLength)
    {
        Assert.Equal(new SqlTextChange(start, oldLength, newLength), SqlTextChange.Between(before, after));
    }

    [Fact]
    public void RangesBeforeAndAfterTheEditMoveAndTouchedOnesAreDropped()
    {
        var change = new SqlTextChange(10, 2, 5);
        Assert.True(change.TryMap(2, 3, out var before));
        Assert.Equal(2, before);
        Assert.True(change.TryMap(20, 3, out var after));
        Assert.Equal(23, after);
        Assert.False(change.TryMap(8, 2, out _));
        Assert.False(change.TryMap(12, 1, out _));
        Assert.False(change.TryMap(11, 1, out _));
    }

    [Fact]
    public void DiagnosticsFollowTypingElsewhere()
    {
        const string text = "SELECT 1);\rSELECT * FROM userz;";
        var analysis = Analyze(text);
        Assert.Equal(2, analysis.Diagnostics.Length);

        // Typing at the start shifts both; typing into the unknown name drops only its warning.
        var shifted = analysis.DiagnosticsMappedTo("-- x\r" + text);
        Assert.Equal(analysis.Diagnostics.Select(d => d.Start + 5), shifted.Select(d => d.Start));

        var edited = analysis.DiagnosticsMappedTo(text.Replace("userz", "users", StringComparison.Ordinal));
        Assert.Equal(SqlDiagnosticCode.UnmatchedClosingBracket, Assert.Single(edited).Code);
        Assert.Equal(analysis.Diagnostics, analysis.DiagnosticsMappedTo(text));
    }

    [Fact]
    public void TheEmptyAnalysisAnswersEverythingWithNothing()
    {
        var empty = Analyzed.Empty;
        Assert.Empty(empty.Diagnostics);
        Assert.Null(empty.SymbolAt(0));
        Assert.Null(empty.HoverAt(0));
        Assert.Empty(empty.ReferencesAt(0));
        Assert.Equal(0, empty.StatementCount);
    }
}
