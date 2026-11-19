using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineEdgeCasesTests
{
    [Fact]
    public void EmptyBufferAllMotionsAreSafe()
    {
        var s = new VimSession("", caret: 0);
        s.Press("hjklwbe0$^_");
        s.Press("gg");
        s.Key("G", shift: true);
        Assert.Equal(0, s.Caret);
        Assert.Equal("", s.Text);
    }

    [Fact]
    public void EmptyBufferOperatorsAreSafe()
    {
        var s = new VimSession("", caret: 0);
        s.Press("xdwddyycc");
        Assert.Equal("", s.Text);
    }

    [Fact]
    public void EmptyBufferInsertEntryThenEscape()
    {
        var s = new VimSession("", caret: 0);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void EmptyBufferVisualModeIsSafe()
    {
        var s = new VimSession("", caret: 0);
        s.Press("v");
        Assert.Equal(VimMode.Visual, s.Mode);
        Assert.Equal(0, s.Selection.Length);
        s.Press("d");
        Assert.Equal("", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void SingleCharBufferMotionsClamp()
    {
        var s = new VimSession("a", caret: 0);
        s.Press("l");
        Assert.Equal(0, s.Caret);
        s.Press("h");
        Assert.Equal(0, s.Caret);
        s.Press("w");
        Assert.Equal(0, s.Caret);
        s.Press("$");
        Assert.Equal(0, s.Caret);
        s.Press("0");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void SingleCharBufferXLeavesEmpty()
    {
        var s = new VimSession("a", caret: 0);
        s.Press("x");
        Assert.Equal("", s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void WAtVeryLastCharStaysOnIt()
    {
        // Regression: the block cursor sat past the ';'.
        var s = new VimSession("SELECT * FROM users;", caret: 19);
        s.Press("w");
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void EscapeFromInsertAtEndOfNoNewlineBufferStepsBack()
    {
        // Regression: Esc looked like it did nothing after typing ';'.
        var s = new VimSession("SELECT * FROM users;", caret: 20);
        s.Press("i");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(19, s.Caret);
    }

    [Fact]
    public void CursorClampedAfterDeleteAtEndOfBuffer()
    {
        var s = new VimSession("hello", caret: 4);
        s.Press("x");
        Assert.Equal("hell", s.Text);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void JOnLineWithJustNewlineIsNoOp()
    {
        var s = new VimSession("\n", caret: 0);
        s.Key("J", shift: true);
        Assert.Equal("\n", s.Text);
    }

    [Fact]
    public void DollarOnEmptyLineStaysAtLineStart()
    {
        var s = new VimSession("\n", caret: 0);
        s.Press("$");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void MotionsOverConsecutiveEmptyLines()
    {
        var s = new VimSession("a\n\n\nb\n", caret: 0);
        s.Press("j");
        Assert.Equal(2, s.Caret);
        s.Press("j");
        Assert.Equal(3, s.Caret);
        s.Press("j");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void MotionsAcrossVeryLongLineDoNotCrash()
    {
        var s = new VimSession(new string('a', 10_000) + "\n", caret: 0);
        s.Press("$");
        Assert.Equal(9999, s.Caret);
        s.Press("0");
        Assert.Equal(0, s.Caret);
        s.Press("w");
        Assert.Equal(9999, s.Caret);
    }

    [Fact]
    public void MotionsOnAsciiSafeUnicode()
    {
        var s = new VimSession("café\n", caret: 0);
        var length = s.Text.Length;
        s.Press("$");
        Assert.Equal(length - 2, s.Caret);
    }

    [Fact]
    public void DoubleByteUnicodeBuffer()
    {
        var s = new VimSession("你好世界\n", caret: 0);
        s.Press("l");
        Assert.Equal(1, s.Caret);
        s.Press("$");
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void CRLFLineEndingsTreatedAsBoundary()
    {
        var s = new VimSession("hello\r\nworld\n", caret: 0);
        s.Press("j");
        var (line, _) = s.Engine.Buffer.LineAndColumn(s.Caret);
        Assert.Equal(1, line);
    }

    [Fact]
    public void ExtremeCountDoesNotOverflowOrCrash()
    {
        var s = new VimSession("hello\n", caret: 0);
        for (var i = 0; i < 200; i++)
        {
            s.Key("9");
        }
        s.Press("l");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void VisualSelectThenOperatorThenUndo()
    {
        var s = new VimSession("hello world\n", caret: 0);
        s.Press("v");
        s.Press("e");
        s.Press("d");
        Assert.Equal(" world\n", s.Text);
        s.Press("u");
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void RapidModeSwitchesPreserveState()
    {
        var s = new VimSession("hello\n", caret: 0);
        for (var i = 0; i < 10; i++)
        {
            s.Press("i");
            s.Escape();
        }
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void ResetClearsAllPendingState()
    {
        var s = new VimSession("hello world\n", caret: 5);
        s.Press("3d");
        s.Engine.Reset();
        Assert.Equal(VimMode.Normal, s.Mode);
        s.SetCaret(0);
        s.Press("l");
        Assert.True(s.Caret == 1, "Reset must clear the count and the pending operator");
    }
}
