using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>r{char} single-character replace and R overwrite mode.</summary>
public sealed class VimEngineReplaceTests
{
    private const string Sample = "hello world\nsecond line\n";
    private const char Escape = '\u001B';
    private const char Backspace = '\u007F';

    private static VimHarness At(int caret) => new(Sample, caret);

    [Fact]
    public void RReplacesSingleCharacter()
    {
        var h = At(0);
        h.Keys("rH");
        Assert.Equal("Hello world\nsecond line\n", h.Text);
    }

    [Fact]
    public void RStaysInNormalMode()
    {
        var h = At(0);
        h.Keys("rH");
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void RDoesNotMoveCursor()
    {
        var h = At(5);
        h.Keys("rX");
        Assert.Equal(5, h.Pos);
    }

    [Fact]
    public void RWithCountReplacesMultipleChars()
    {
        var h = At(0);
        h.Keys("3rX");
        Assert.Equal("XXXlo world\nsecond line\n", h.Text);
    }

    [Fact]
    public void RWithCountCursorOnLastReplaced()
    {
        var h = At(0);
        h.Keys("3rX");
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void RCountExceedingLineRemainderIsNoOp()
    {
        // Only three characters remain before the newline, and Vim refuses rather than overwrite it.
        var h = At(8);
        h.Keys("99rX");
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void RWithNewlineReplacesCharWithNewline()
    {
        var h = At(5);
        h.Keys("r");
        h.Key('\r');
        Assert.Equal("hello\nworld\nsecond line\n", h.Text);
    }

    [Fact]
    public void REscapeCancelsReplace()
    {
        var h = At(0);
        h.Keys("r");
        h.Key(Escape);
        Assert.Equal(Sample, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void CapitalREntersReplaceMode()
    {
        var h = At(0);
        h.Key('R', shift: true);
        Assert.Equal(VimMode.Replace, h.Mode);
    }

    [Fact]
    public void CapitalROverwritesCharactersAsTyped()
    {
        var h = At(0);
        h.Key('R', shift: true);
        h.Key('X', shift: true);
        h.Key('Y', shift: true);
        Assert.Equal("XYllo world\nsecond line\n", h.Text);
    }

    [Fact]
    public void CapitalREscapeReturnsToNormal()
    {
        var h = At(0);
        h.Key('R', shift: true);
        h.Key(Escape);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void BackspaceInReplaceModeRestoresOverwrittenCharacters()
    {
        var h = At(0);
        h.Key('R', shift: true);
        h.Key('X', shift: true);
        h.Key('Y', shift: true);
        h.Key(Backspace);
        Assert.Equal("Xello world\nsecond line\n", h.Text);
        Assert.Equal(1, h.Pos);
        h.Key(Backspace);
        Assert.Equal(Sample, h.Text);
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void BackspaceInReplaceModeRemovesAppendedCharacters()
    {
        var h = At(11);
        h.Key('R', shift: true);
        h.Keys("!?");
        Assert.Equal("hello world!?\nsecond line\n", h.Text);
        h.Key(Backspace);
        h.Key(Backspace);
        Assert.Equal(Sample, h.Text);
        Assert.Equal(11, h.Pos);
    }

    [Fact]
    public void BackspaceBeforeReplaceStartOnlyMovesLeft()
    {
        var h = At(3);
        h.Key('R', shift: true);
        h.Key(Backspace);
        Assert.Equal(Sample, h.Text);
        Assert.Equal(2, h.Pos);
    }

    [Fact]
    public void ReplaceModeNeverWritesAControlCharacter()
    {
        var h = At(0);
        h.Key('R', shift: true);
        h.Key('\u0003');
        h.Key('\u001D');
        Assert.Equal(Sample, h.Text);
    }

    [Fact]
    public void ReplaceCharCancelsOnBackspace()
    {
        var h = At(0);
        h.Keys("r");
        h.Key(Backspace);
        Assert.Equal(Sample, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);

        // The cancelled r must not leave a replace pending.
        h.Keys("rH");
        Assert.Equal("Hello world\nsecond line\n", h.Text);
    }

    [Fact]
    public void VisualReplaceCancelsOnBackspace()
    {
        var h = At(0);
        h.Keys("vlr");
        h.Key(Backspace);
        Assert.Equal(Sample, h.Text);
    }
}
