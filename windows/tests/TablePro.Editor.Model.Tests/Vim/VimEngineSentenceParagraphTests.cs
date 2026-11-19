namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineSentenceParagraphTests
{
    [Fact]
    public void RightParenAdvancesToNextSentence()
    {
        var s = new VimSession("First sentence. Second sentence.\n", caret: 0);
        s.Press(")");
        Assert.Equal(16, s.Caret);
    }

    [Fact]
    public void RightParenAcrossLines()
    {
        var s = new VimSession("Line one.\nLine two.\n", caret: 0);
        s.Press(")");
        Assert.Equal(10, s.Caret);
    }

    [Fact]
    public void RightParenWithCount()
    {
        var s = new VimSession("First. Second. Third.\n", caret: 0);
        s.Press("2)");
        Assert.Equal(15, s.Caret);
    }

    [Fact]
    public void LeftParenRetreatsToPreviousSentence()
    {
        var s = new VimSession("First sentence. Second sentence.\n", caret: 16);
        s.Press("(");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void RightBraceAdvancesPastBlankLine()
    {
        var s = new VimSession("para one\nstill one\n\npara two\n", caret: 0);
        s.Press("}");
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void RightBraceFromBlankLineAdvancesToNextParagraphEnd()
    {
        var s = new VimSession("para one\n\npara two\nstill two\n\npara three\n", caret: 9);
        s.Press("}");
        Assert.Equal(29, s.Caret);
    }

    [Fact]
    public void RightBraceWithCount()
    {
        var s = new VimSession("p1\n\np2\n\np3\n", caret: 0);
        s.Press("2}");
        Assert.Equal(7, s.Caret);
    }

    [Fact]
    public void LeftBraceRetreatsToParagraphStart()
    {
        var s = new VimSession("para one\nstill one\n\npara two\n", caret: 21);
        s.Press("{");
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void LeftBraceFromFirstParagraphLandsAtBufferStart()
    {
        var s = new VimSession("only paragraph\nstill one\n", caret: 16);
        s.Press("{");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void DoubleRightBracketAdvancesToNextSection()
    {
        var s = new VimSession("{\n  body;\n}\n\n{\n  next;\n}\n", caret: 0);
        s.Press("]]");
        Assert.Equal(13, s.Caret);
    }

    [Fact]
    public void DoubleLeftBracketRetreatsToPreviousSection()
    {
        var s = new VimSession("{\n  body;\n}\n\n{\n  next;\n}\n", caret: 13);
        s.Press("[[");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void SentenceBoundaryWithExclamation()
    {
        var s = new VimSession("Wow! Cool.\n", caret: 0);
        s.Press(")");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void SentenceBoundaryWithQuestion()
    {
        var s = new VimSession("Why? Because.\n", caret: 0);
        s.Press(")");
        Assert.Equal(5, s.Caret);
    }
}
