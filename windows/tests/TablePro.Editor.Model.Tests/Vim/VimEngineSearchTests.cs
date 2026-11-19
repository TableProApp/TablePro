using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineSearchTests
{
    private const string Text = "hello world\nfoo bar hello\nthird hello\n";

    private static void Enter(VimSession s) => s.Key("\r");

    [Fact]
    public void ForwardSearchFindsFirstMatch()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/world");
        Enter(s);
        Assert.Equal(6, s.Caret);
    }

    [Fact]
    public void ForwardSearchSkipsCursorPosition()
    {
        var s = new VimSession(Text, caret: 12);
        s.Press("/hello");
        Enter(s);
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void ForwardSearchWrapsAroundEndOfBuffer()
    {
        var s = new VimSession(Text, caret: 32);
        s.Press("/hello");
        Enter(s);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void ForwardSearchNotFoundLeavesCursor()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/nomatch");
        Enter(s);
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void ForwardSearchEscapeCancels()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/world");
        s.Escape();
        Assert.Equal(0, s.Caret);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void BackwardSearchFindsPriorMatch()
    {
        var s = new VimSession(Text, caret: 30);
        s.Press("?hello");
        Enter(s);
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void BackwardSearchWrapsAroundStartOfBuffer()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("?hello");
        Enter(s);
        Assert.Equal(32, s.Caret);
    }

    [Fact]
    public void NRepeatsForwardSearch()
    {
        // The search starts after the caret, so the 'hello' under it at 0 is skipped.
        var s = new VimSession(Text, caret: 0);
        s.Press("/hello");
        Enter(s);
        Assert.Equal(20, s.Caret);
        s.Press("n");
        Assert.Equal(32, s.Caret);
        s.Press("n");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void NRepeatsBackwardSearch()
    {
        var s = new VimSession(Text, caret: 32);
        s.Press("?hello");
        Enter(s);
        s.Press("n");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void CapitalNReversesDirection()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/hello");
        Enter(s);
        s.Press("n");
        Assert.Equal(32, s.Caret);
        s.Press("N");
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void NWithCount()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/hello");
        Enter(s);
        s.Press("2n");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void StarSearchesWordUnderCursorForward()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("*");
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void StarMatchesWholeWordOnly()
    {
        var s = new VimSession("foo foobar foo\n", caret: 0);
        s.Press("*");
        Assert.Equal(11, s.Caret);
    }

    [Fact]
    public void HashSearchesWordUnderCursorBackward()
    {
        var s = new VimSession(Text, caret: 32);
        s.Press("#");
        Assert.Equal(20, s.Caret);
    }

    [Fact]
    public void SearchStateRetainedAfterMatch()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("/foo");
        Enter(s);
        Assert.Equal(12, s.Caret);
        // The only 'foo' is under the caret, so n wraps back onto it.
        s.Press("n");
        Assert.Equal(12, s.Caret);
    }
}
