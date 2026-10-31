using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>
/// Boundary and regression cases that cut across command families: end-of-buffer caret states, empty and single-character
/// buffers, Unicode and very long content.
/// </summary>
public sealed class VimEngineEdgeCasesTests
{
    private const char Escape = '\u001B';

    [Fact]
    public void EmptyBufferAllMotionsAreSafe()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("hjklwbe0$^_");
        h.Keys("gg");
        h.Key('G', shift: true);
        Assert.Equal(0, h.Pos);
        Assert.Equal(string.Empty, h.Text);
    }

    [Fact]
    public void EmptyBufferOperatorsAreSafe()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("xdwddyycc");
        Assert.Equal(string.Empty, h.Text);
    }

    [Fact]
    public void EmptyBufferInsertEntryThenEscape()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("i");
        h.Key(Escape);
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void EmptyBufferVisualModeIsSafe()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("v");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
        Assert.Equal(0, h.Buffer.SelectionLength);
        h.Keys("d");
        Assert.Equal(string.Empty, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void SingleCharBufferMotionsClamp()
    {
        var h = new VimHarness("a");
        h.Keys("l");
        Assert.Equal(0, h.Pos);
        h.Keys("h");
        Assert.Equal(0, h.Pos);
        h.Keys("w");
        Assert.Equal(0, h.Pos);
        h.Keys("$");
        Assert.Equal(0, h.Pos);
        h.Keys("0");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void SingleCharBufferXLeavesEmpty()
    {
        var h = new VimHarness("a");
        h.Keys("x");
        Assert.Equal(string.Empty, h.Text);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void WAtVeryLastCharStaysOnIt()
    {
        // Regression: the block caret once sat past the ';'.
        var h = new VimHarness("SELECT * FROM users;", 19);
        h.Keys("w");
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void EscapeFromInsertAtEndOfNoNewlineBufferStepsBack()
    {
        // Regression: Escape once appeared to do nothing after typing the final ';'.
        var h = new VimHarness("SELECT * FROM users;", 20);
        h.Keys("i");
        h.Key(Escape);
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(19, h.Pos);
    }

    [Fact]
    public void CursorClampedAfterDeleteAtEndOfBuffer()
    {
        var h = new VimHarness("hello", 4);
        h.Keys("x");
        Assert.Equal("hell", h.Text);
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void JOnLineWithJustNewlineIsNoOp()
    {
        var h = new VimHarness("\n");
        h.Key('J', shift: true);
        Assert.Equal("\n", h.Text);
    }

    [Fact]
    public void DollarOnEmptyLineStaysAtLineStart()
    {
        var h = new VimHarness("\n");
        h.Keys("$");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void MotionsOverConsecutiveEmptyLines()
    {
        var h = new VimHarness("a\n\n\nb\n");
        h.Keys("j");
        Assert.Equal(2, h.Pos);
        h.Keys("j");
        Assert.Equal(3, h.Pos);
        h.Keys("j");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void MotionsAcrossVeryLongLineDoNotCrash()
    {
        var h = new VimHarness(new string('a', 10_000) + "\n");
        h.Keys("$");
        Assert.Equal(9999, h.Pos);
        h.Keys("0");
        Assert.Equal(0, h.Pos);

        // One word filling the line, so w clamps onto its last character.
        h.Keys("w");
        Assert.Equal(9999, h.Pos);
    }

    [Fact]
    public void MotionsOnAsciiSafeUnicode()
    {
        var h = new VimHarness("café\n");
        h.Keys("$");
        Assert.Equal(h.Text.Length - 2, h.Pos);
    }

    [Fact]
    public void DoubleByteUnicodeBuffer()
    {
        // CJK characters are one UTF-16 code unit each.
        var h = new VimHarness("你好世界\n");
        h.Keys("l");
        Assert.Equal(1, h.Pos);
        h.Keys("$");
        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void CrlfLineEndingsTreatedAsBoundary()
    {
        var h = new VimHarness("hello\r\nworld\n");
        h.Keys("j");
        Assert.Equal(1, h.Buffer.LineAndColumn(h.Pos).Line);
    }

    [Fact]
    public void ExtremeCountDoesNotOverflowOrCrash()
    {
        var h = new VimHarness("hello\n");
        h.Keys(new string('9', 200));
        h.Keys("l");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void VisualSelectThenOperatorThenUndo()
    {
        var h = new VimHarness("hello world\n");
        h.Keys("v");
        h.Keys("e");
        h.Keys("d");
        Assert.Equal(" world\n", h.Text);
        h.Keys("u");
        Assert.Equal(1, h.Buffer.UndoCount);
    }

    [Fact]
    public void RapidModeSwitchesPreserveState()
    {
        var h = new VimHarness("hello\n");
        for (var i = 0; i < 10; i++)
        {
            h.Keys("i");
            h.Key(Escape);
        }

        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void ResetClearsAllPendingState()
    {
        var h = new VimHarness("hello world\n", 5);
        h.Keys("3d");
        h.Engine.Reset();
        Assert.Equal(VimMode.Normal, h.Mode);

        // A leftover count of 3 or a pending d would change what l does.
        h.Select(0);
        h.Keys("l");
        Assert.Equal(1, h.Pos);
    }
}
