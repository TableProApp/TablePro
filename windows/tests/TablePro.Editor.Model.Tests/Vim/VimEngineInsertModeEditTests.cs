using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineInsertModeEditTests
{
    private const string Text = "hello world\n";
    private const string CtrlD = "\u0004";
    private const string CtrlH = "\u0008";
    private const string CtrlT = "\u0014";
    private const string CtrlU = "\u0015";
    private const string CtrlW = "\u0017";

    private static VimSession InInsert(int offset, string text = Text)
    {
        var s = new VimSession(text, caret: offset);
        s.Key("i");
        return s;
    }

    [Fact]
    public void CtrlWDeletesPreviousWord()
    {
        var s = InInsert(11);
        s.Key(CtrlW);
        Assert.Equal("hello \n", s.Text);
    }

    [Fact]
    public void CtrlWInMiddleOfWord()
    {
        var s = InInsert(8);
        s.Key(CtrlW);
        Assert.Equal("hello rld\n", s.Text);
    }

    [Fact]
    public void CtrlWAtLineStartIsNoOp()
    {
        var s = InInsert(0);
        s.Key(CtrlW);
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void CtrlWConsumed()
    {
        var s = InInsert(11);
        Assert.True(s.Key(CtrlW));
    }

    [Fact]
    public void CtrlUDeletesToLineStart()
    {
        var s = InInsert(11);
        s.Key(CtrlU);
        Assert.Equal("\n", s.Text);
    }

    [Fact]
    public void CtrlUOnEmptyLineIsNoOp()
    {
        var s = InInsert(0, "\n");
        s.Key(CtrlU);
        Assert.Equal("\n", s.Text);
    }

    [Fact]
    public void CtrlUInMiddleOfLine()
    {
        var s = InInsert(6);
        s.Key(CtrlU);
        Assert.Equal("world\n", s.Text);
    }

    // Ctrl+H is the editor's backspace, which handles selections and every caret.
    [Fact]
    public void CtrlHIsLeftToTheTextViewBackspace()
    {
        var s = InInsert(5);
        Assert.False(s.Key(CtrlH));
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void CtrlTIndentsCurrentLine()
    {
        var s = InInsert(5);
        s.Key(CtrlT);
        Assert.Equal("    hello world\n", s.Text);
    }

    [Fact]
    public void CtrlDOutdentsCurrentLine()
    {
        var s = InInsert(10, "        hello\n");
        s.Key(CtrlD);
        Assert.Equal("    hello\n", s.Text);
    }

    [Fact]
    public void CtrlEditsKeepInsertMode()
    {
        var s = InInsert(11);
        s.Key(CtrlW);
        Assert.Equal(VimMode.Insert, s.Mode);
        s.Key(CtrlU);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void CtrlWInReplaceModeDeletesPreviousWord()
    {
        var s = new VimSession(Text, caret: 11);
        s.Key("R", shift: true);
        Assert.Equal(VimMode.Replace, s.Mode);
        s.Key(CtrlW);
        Assert.Equal("hello \n", s.Text);
    }
}
