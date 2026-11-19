namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineUndoRepeatTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    private const string Redo = "\u0012";

    [Fact]
    public void UCallsBufferUndo()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("x");
        Assert.Equal(Text[1..], s.Text);
        s.Press("u");
        Assert.Equal(Text, s.Text);
    }

    [Fact]
    public void UWithCountCallsUndoNTimes()
    {
        // Four edits and 3u leave the first one, so exactly three were undone.
        var s = new VimSession(Text, caret: 0);
        s.Press("xxxx");
        Assert.Equal(Text[4..], s.Text);
        s.Press("3u");
        Assert.Equal(Text[1..], s.Text);
    }

    [Fact]
    public void UConsumesKey()
    {
        var s = new VimSession(Text, caret: 0);
        Assert.True(s.Key("u"));
    }

    [Fact]
    public void RedoCallsBufferRedo()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("x");
        s.Press("u");
        Assert.Equal(Text, s.Text);
        s.Key(Redo);
        Assert.Equal(Text[1..], s.Text);
    }

    [Fact]
    public void MultipleRedoCalls()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("xxxx");
        s.Press("4u");
        Assert.Equal(Text, s.Text);
        s.Key(Redo);
        s.Key(Redo);
        s.Key(Redo);
        Assert.Equal(Text[3..], s.Text);
    }

    [Fact]
    public void CapitalUUndoesLineChanges()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("x");
        s.Press("x");
        s.Key("U", shift: true);
        Assert.Equal(Text, s.Text);
    }

    [Fact]
    public void DotRepeatsLastEdit()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("dw");
        Assert.Equal("world\nsecond line\nthird line\n", s.Text);
        s.Press(".");
        Assert.Equal("\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DotRepeatsXDelete()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", s.Text);
        s.Press(".");
        Assert.Equal("llo world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DotRepeatsWithExplicitCount()
    {
        var s = new VimSession("a b c d e f\n", caret: 0);
        s.Press("dw");
        s.Press("3.");
        Assert.Equal("e f\n", s.Text);
    }

    [Fact]
    public void DotDoesNotRepeatMotions()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("l");
        s.Press("l");
        s.Press(".");
        Assert.Equal(Text, s.Text);
    }

    [Fact]
    public void DotRepeatsInsertedText()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("i");
        s.Type("X");
        s.Escape();
        Assert.True(s.Key("."), ". must be consumed in normal mode");
    }
}
