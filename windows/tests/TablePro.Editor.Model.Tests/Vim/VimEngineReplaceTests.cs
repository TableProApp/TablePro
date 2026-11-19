using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineReplaceTests
{
    private const string Initial = "hello world\nsecond line\n";

    [Fact]
    public void RReplacesSingleCharacter()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("rH");
        Assert.Equal("Hello world\nsecond line\n", s.Text);
    }

    [Fact]
    public void RStaysInNormalMode()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("rH");
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void RDoesNotMoveCursor()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("rX");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void RWithCountReplacesMultipleChars()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("3rX");
        Assert.Equal("XXXlo world\nsecond line\n", s.Text);
    }

    [Fact]
    public void RWithCountCursorOnLastReplaced()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("3rX");
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void RCountExceedingLineRemainderIsNoOp()
    {
        // Vim refuses the whole count rather than overwrite the newline.
        var s = new VimSession(Initial, caret: 8);
        s.Press("99rX");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void RWithNewlineReplacesCharWithNewline()
    {
        var s = new VimSession(Initial, caret: 5);
        s.Press("r");
        s.Key("\r");
        Assert.Equal("hello\nworld\nsecond line\n", s.Text);
    }

    [Fact]
    public void REscapeCancelsReplace()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("r");
        s.Escape();
        Assert.Equal(Initial, s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void CapitalREntersReplaceMode()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("R", shift: true);
        Assert.Equal(VimMode.Replace, s.Mode);
    }

    [Fact]
    public void CapitalROverwritesCharactersAsTyped()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("R", shift: true);
        s.Key("X", shift: true);
        s.Key("Y", shift: true);
        Assert.Equal("XYllo world\nsecond line\n", s.Text);
    }

    [Fact]
    public void CapitalREscapeReturnsToNormal()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("R", shift: true);
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void BackspaceInReplaceModeRestoresOverwrittenCharacters()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("R", shift: true);
        s.Key("X", shift: true);
        s.Key("Y", shift: true);
        s.Backspace();
        Assert.Equal("Xello world\nsecond line\n", s.Text);
        Assert.Equal(1, s.Caret);
        s.Backspace();
        Assert.Equal(Initial, s.Text);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void BackspaceInReplaceModeRemovesAppendedCharacters()
    {
        var s = new VimSession(Initial, caret: 11);
        s.Key("R", shift: true);
        s.Press("!?");
        Assert.Equal("hello world!?\nsecond line\n", s.Text);
        s.Backspace();
        s.Backspace();
        Assert.Equal(Initial, s.Text);
        Assert.Equal(11, s.Caret);
    }

    [Fact]
    public void BackspaceBeforeReplaceStartOnlyMovesLeft()
    {
        var s = new VimSession(Initial, caret: 3);
        s.Key("R", shift: true);
        s.Backspace();
        Assert.Equal(Initial, s.Text);
        Assert.Equal(2, s.Caret);
    }

    [Fact]
    public void ReplaceModeNeverWritesAControlCharacter()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Key("R", shift: true);
        s.Key("\u0003");
        s.Key("\u001D");
        Assert.Equal(Initial, s.Text);
    }

    [Fact]
    public void ReplaceCharCancelsOnBackspace()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("r");
        s.Backspace();
        Assert.Equal(Initial, s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
        s.Press("rH");
        // The cancelled r must not leave a pending replace.
        Assert.Equal("Hello world\nsecond line\n", s.Text);
    }

    [Fact]
    public void VisualReplaceCancelsOnBackspace()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("vlr");
        s.Backspace();
        Assert.Equal(Initial, s.Text);
    }
}
