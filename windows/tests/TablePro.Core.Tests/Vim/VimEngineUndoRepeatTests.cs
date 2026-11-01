namespace TablePro.Core.Tests.Vim;

/// <summary>Undo (u), redo (Ctrl+R), line undo (U) and dot repeat.</summary>
public sealed class VimEngineUndoRepeatTests
{
    private const char CtrlR = '\u0012';
    private const string Text = "hello world\nsecond line\nthird line\n";

    private static VimHarness Make() => new(Text);

    [Fact]
    public void UCallsBufferUndo()
    {
        var h = Make();
        Assert.Equal(0, h.Buffer.UndoCount);
        h.Keys("u");
        Assert.Equal(1, h.Buffer.UndoCount);
    }

    [Fact]
    public void UWithCountCallsUndoNTimes()
    {
        var h = Make();
        h.Keys("3u");
        Assert.Equal(3, h.Buffer.UndoCount);
    }

    [Fact]
    public void UConsumesKey() => Assert.True(Make().Key('u'));

    [Fact]
    public void RedoCallsBufferRedo()
    {
        var h = Make();
        Assert.Equal(0, h.Buffer.RedoCount);
        h.Key(CtrlR);
        Assert.Equal(1, h.Buffer.RedoCount);
    }

    [Fact]
    public void MultipleRedoCalls()
    {
        var h = Make();
        h.Key(CtrlR);
        h.Key(CtrlR);
        h.Key(CtrlR);
        Assert.Equal(3, h.Buffer.RedoCount);
    }

    [Fact]
    public void CapitalUUndoesLineChanges()
    {
        // U restores the line by undoing each change made on it.
        var h = Make();
        h.Keys("x");
        h.Keys("x");
        h.Key('U', shift: true);
        Assert.Equal(2, h.Buffer.UndoCount);
    }

    [Fact]
    public void DotRepeatsLastEdit()
    {
        var h = Make();
        h.Keys("dw");
        Assert.Equal("world\nsecond line\nthird line\n", h.Text);
        h.Keys(".");
        Assert.Equal("\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DotRepeatsXDelete()
    {
        var h = Make();
        h.Keys("x");
        Assert.Equal("ello world\nsecond line\nthird line\n", h.Text);
        h.Keys(".");
        Assert.Equal("llo world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DotRepeatsWithExplicitCount()
    {
        var h = new VimHarness("a b c d e f\n");
        h.Keys("dw");
        h.Keys("3.");
        Assert.Equal("e f\n", h.Text);
    }

    [Fact]
    public void DotDoesNotRepeatMotions()
    {
        var h = Make();
        h.Keys("l");
        h.Keys("l");
        h.Keys(".");
        Assert.Equal(Text, h.Text);
    }

    [Fact]
    public void DotRepeatsInsertedText()
    {
        // The editor types insert-mode text, so at the engine level only the dot being consumed can be checked.
        var h = Make();
        h.Keys("i");
        h.Key('X');
        h.Key('\u001B');
        Assert.True(h.Key('.'));
    }
}
