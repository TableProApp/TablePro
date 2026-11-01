namespace TablePro.Core.Tests.Vim;

/// <summary>
/// Sentence ( ), paragraph { } and section [[ ]] motions. A sentence ends at '.', '!' or '?' followed by whitespace;
/// a blank line ends a paragraph.
/// </summary>
public sealed class VimEngineSentenceParagraphTests
{
    private static int Run(string text, int caret, string keys)
    {
        var h = new VimHarness(text, caret);
        h.Keys(keys);
        return h.Pos;
    }

    [Fact]
    public void RightParenAdvancesToNextSentence() =>
        Assert.Equal(16, Run("First sentence. Second sentence.\n", 0, ")"));

    [Fact]
    public void RightParenAcrossLines() =>
        Assert.Equal(10, Run("Line one.\nLine two.\n", 0, ")"));

    [Fact]
    public void RightParenWithCount() =>
        Assert.Equal(15, Run("First. Second. Third.\n", 0, "2)"));

    [Fact]
    public void LeftParenRetreatsToPreviousSentence() =>
        Assert.Equal(0, Run("First sentence. Second sentence.\n", 16, "("));

    [Fact]
    public void RightBraceAdvancesPastBlankLine() =>
        Assert.Equal(19, Run("para one\nstill one\n\npara two\n", 0, "}"));

    [Fact]
    public void RightBraceFromBlankLineAdvancesToNextParagraphEnd() =>
        Assert.Equal(29, Run("para one\n\npara two\nstill two\n\npara three\n", 9, "}"));

    [Fact]
    public void RightBraceWithCount() =>
        Assert.Equal(7, Run("p1\n\np2\n\np3\n", 0, "2}"));

    [Fact]
    public void LeftBraceRetreatsToParagraphStart() =>
        Assert.Equal(19, Run("para one\nstill one\n\npara two\n", 21, "{"));

    [Fact]
    public void LeftBraceFromFirstParagraphLandsAtBufferStart() =>
        Assert.Equal(0, Run("only paragraph\nstill one\n", 16, "{"));

    [Fact]
    public void DoubleRightBracketAdvancesToNextSection() =>
        Assert.Equal(13, Run("{\n  body;\n}\n\n{\n  next;\n}\n", 0, "]]"));

    [Fact]
    public void DoubleLeftBracketRetreatsToPreviousSection() =>
        Assert.Equal(0, Run("{\n  body;\n}\n\n{\n  next;\n}\n", 13, "[["));

    [Fact]
    public void SentenceBoundaryWithExclamation() =>
        Assert.Equal(5, Run("Wow! Cool.\n", 0, ")"));

    [Fact]
    public void SentenceBoundaryWithQuestion() =>
        Assert.Equal(5, Run("Why? Because.\n", 0, ")"));
}
