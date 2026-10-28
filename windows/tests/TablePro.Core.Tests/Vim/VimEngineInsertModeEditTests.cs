using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>
/// Editing chords inside insert mode: Ctrl+W, Ctrl+U, Ctrl+T and Ctrl+D. Ctrl+H is left to the editor, whose
/// backspace it is.
/// </summary>
public sealed class VimEngineInsertModeEditTests
{
    private const char CtrlD = '\u0004';
    private const char CtrlH = '\u0008';
    private const char CtrlT = '\u0014';
    private const char CtrlU = '\u0015';
    private const char CtrlW = '\u0017';

    private static VimHarness InsertAt(int offset, string text = "hello world\n")
    {
        var h = new VimHarness(text, offset);
        h.Keys("i");
        return h;
    }

    [Fact]
    public void CtrlWDeletesPreviousWord()
    {
        var h = InsertAt(11);
        h.Key(CtrlW);
        Assert.Equal("hello \n", h.Text);
    }

    [Fact]
    public void CtrlWInMiddleOfWord()
    {
        var h = InsertAt(8);
        h.Key(CtrlW);
        Assert.Equal("hello rld\n", h.Text);
    }

    [Fact]
    public void CtrlWAtLineStartIsNoOp()
    {
        var h = InsertAt(0);
        h.Key(CtrlW);
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void CtrlWConsumed() => Assert.True(InsertAt(11).Key(CtrlW));

    [Fact]
    public void CtrlUDeletesToLineStart()
    {
        var h = InsertAt(11);
        h.Key(CtrlU);
        Assert.Equal("\n", h.Text);
    }

    [Fact]
    public void CtrlUOnEmptyLineIsNoOp()
    {
        var h = InsertAt(0, "\n");
        h.Key(CtrlU);
        Assert.Equal("\n", h.Text);
    }

    [Fact]
    public void CtrlUInMiddleOfLine()
    {
        var h = InsertAt(6);
        h.Key(CtrlU);
        Assert.Equal("world\n", h.Text);
    }

    [Fact]
    public void CtrlHIsLeftToTheTextViewBackspace()
    {
        // The editor's own backspace handles selections and every caret, so the engine declines Ctrl+H.
        var h = InsertAt(5);
        Assert.False(h.Key(CtrlH));
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void CtrlTIndentsCurrentLine()
    {
        var h = InsertAt(5);
        h.Key(CtrlT);
        Assert.Equal("    hello world\n", h.Text);
    }

    [Fact]
    public void CtrlDOutdentsCurrentLine()
    {
        var h = InsertAt(10, "        hello\n");
        h.Key(CtrlD);
        Assert.Equal("    hello\n", h.Text);
    }

    [Fact]
    public void CtrlEditsKeepInsertMode()
    {
        var h = InsertAt(11);
        h.Key(CtrlW);
        Assert.Equal(VimMode.Insert, h.Mode);
        h.Key(CtrlU);
        Assert.Equal(VimMode.Insert, h.Mode);
    }

    [Fact]
    public void CtrlWInReplaceModeDeletesPreviousWord()
    {
        var h = new VimHarness("hello world\n", 11);
        h.Key('R', shift: true);
        Assert.Equal(VimMode.Replace, h.Mode);
        h.Key(CtrlW);
        Assert.Equal("hello \n", h.Text);
    }
}
