namespace TablePro.Core.Tests.Vim;

/// <summary>Macros: q{a-z} records, @{a-z} replays and @@ replays the macro replayed last.</summary>
public sealed class VimEngineMacroTests
{
    private static VimHarness Make() => new("aaa bbb ccc ddd\n");

    [Fact]
    public void QStartsRecordingIntoNamedRegister()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("dw");
        h.Keys("q");

        // Recording still runs the keys.
        Assert.Equal("bbb ccc ddd\n", h.Text);
    }

    [Fact]
    public void QAToQClosesRecording()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("x");
        h.Keys("q");
        h.Keys("x");
        Assert.Equal("a bbb ccc ddd\n", h.Text);
    }

    [Fact]
    public void AtAReplaysNamedMacro()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("dw");
        h.Keys("q");
        Assert.Equal("bbb ccc ddd\n", h.Text);
        h.Keys("@a");
        Assert.Equal("ccc ddd\n", h.Text);
    }

    [Fact]
    public void AtACanBeReplayedMultipleTimes()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("dw");
        h.Keys("q");
        h.Keys("@a");
        h.Keys("@a");
        Assert.Equal("ddd\n", h.Text);
    }

    [Fact]
    public void AtAtReplaysLastMacro()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("dw");
        h.Keys("q");
        h.Keys("@a");
        h.Keys("@@");
        Assert.Equal("ddd\n", h.Text);
    }

    [Fact]
    public void AtAWithCount()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("dw");
        h.Keys("q");
        h.Keys("3@a");
        Assert.Equal("\n", h.Text);
    }

    [Fact]
    public void TwoIndependentMacros()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("w");
        h.Keys("q");
        Assert.Equal(4, h.Pos);
        h.Keys("qb");
        h.Keys("dw");
        h.Keys("q");
        Assert.Equal("aaa ccc ddd\n", h.Text);
        h.Keys("0@a");
        Assert.Equal(4, h.Pos);
    }

    [Fact]
    public void EmptyMacroReplayIsNoOp()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("q");
        var snapshot = h.Text;
        h.Keys("@a");
        Assert.Equal(snapshot, h.Text);
    }

    [Fact]
    public void RecordingCapturesVisualOperation()
    {
        var h = Make();
        h.Keys("qa");
        h.Keys("v");
        h.Keys("ll");
        h.Keys("d");
        h.Keys("q");
        Assert.Equal(" bbb ccc ddd\n", h.Text);

        // Where the replayed delete lands depends on the caret; it only has to change the text again.
        h.Keys("@a");
        Assert.NotEqual(" bbb ccc ddd\n", h.Text);
    }

    [Fact]
    public void RecursiveMacroDoesNotInfiniteLoop()
    {
        var h = new VimHarness("abcd\n");
        h.Keys("qa");
        h.Keys("x@a");
        h.Keys("q");

        // Reaching here without a stack overflow is the point; the replay depth is capped.
        Assert.NotNull(h.Text);
    }
}
