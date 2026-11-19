namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineMacroTests
{
    private const string Initial = "aaa bbb ccc ddd\n";

    [Fact]
    public void QStartsRecordingIntoNamedRegister()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("dw");
        s.Press("q");
        Assert.Equal("bbb ccc ddd\n", s.Text);
    }

    [Fact]
    public void QAtoQClosesRecording()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("x");
        s.Press("q");
        s.Press("x");
        Assert.Equal("a bbb ccc ddd\n", s.Text);
    }

    [Fact]
    public void AtAReplaysNamedMacro()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("dw");
        s.Press("q");
        Assert.Equal("bbb ccc ddd\n", s.Text);
        s.Press("@a");
        Assert.Equal("ccc ddd\n", s.Text);
    }

    [Fact]
    public void AtACanBeReplayedMultipleTimes()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("dw");
        s.Press("q");
        s.Press("@a");
        s.Press("@a");
        Assert.Equal("ddd\n", s.Text);
    }

    [Fact]
    public void AtAtReplaysLastMacro()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("dw");
        s.Press("q");
        s.Press("@a");
        s.Press("@@");
        Assert.Equal("ddd\n", s.Text);
    }

    [Fact]
    public void AtAWithCount()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("dw");
        s.Press("q");
        s.Press("3@a");
        Assert.Equal("\n", s.Text);
    }

    [Fact]
    public void TwoIndependentMacros()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("w");
        s.Press("q");
        Assert.Equal(4, s.Caret);
        s.Press("qb");
        s.Press("dw");
        s.Press("q");
        Assert.Equal("aaa ccc ddd\n", s.Text);
        s.Press("0@a");
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void EmptyMacroReplayIsNoOp()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("q");
        var snapshot = s.Text;
        s.Press("@a");
        Assert.Equal(snapshot, s.Text);
    }

    [Fact]
    public void RecordingCapturesVisualOperation()
    {
        var s = new VimSession(Initial, caret: 0);
        s.Press("qa");
        s.Press("v");
        s.Press("ll");
        s.Press("d");
        s.Press("q");
        Assert.Equal(" bbb ccc ddd\n", s.Text);
        s.Press("@a");
        Assert.NotEqual(" bbb ccc ddd\n", s.Text);
    }

    [Fact]
    public void RecursiveMacroDoesNotInfiniteLoop()
    {
        var s = new VimSession("abcd\n", caret: 0);
        s.Press("qa");
        s.Press("x@a");
        s.Press("q");
        Assert.NotNull(s.Text);
    }
}
