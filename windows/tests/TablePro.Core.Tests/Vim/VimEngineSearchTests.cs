using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Search: / forward, ? backward, n and N to repeat, * and # for the word under the cursor.</summary>
public sealed class VimEngineSearchTests
{
    // "hello" starts at 0, 20 and 32; "foo" only at 12.
    private const string Text = "hello world\nfoo bar hello\nthird hello\n";

    private static VimHarness Make(int caret = 0) => new(Text, caret);

    private static void Search(VimHarness h, string command)
    {
        h.Keys(command);
        h.Key('\r');
    }

    [Fact]
    public void ForwardSearchFindsFirstMatch()
    {
        var h = Make();
        Search(h, "/world");
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void ForwardSearchSkipsCursorPosition()
    {
        var h = Make(12);
        Search(h, "/hello");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void ForwardSearchWrapsAroundEndOfBuffer()
    {
        var h = Make(32);
        Search(h, "/hello");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void ForwardSearchNotFoundLeavesCursor()
    {
        var h = Make();
        Search(h, "/nomatch");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void ForwardSearchEscapeCancels()
    {
        var h = Make();
        h.Keys("/world");
        h.Key('\u001B');
        Assert.Equal(0, h.Pos);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void BackwardSearchFindsPriorMatch()
    {
        var h = Make(30);
        Search(h, "?hello");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void BackwardSearchWrapsAroundStartOfBuffer()
    {
        var h = Make();
        Search(h, "?hello");
        Assert.Equal(32, h.Pos);
    }

    [Fact]
    public void NRepeatsForwardSearch()
    {
        // The match under the caret at 0 is skipped, so the search lands on 20; n then reaches 32 and wraps to 0.
        var h = Make();
        Search(h, "/hello");
        Assert.Equal(20, h.Pos);
        h.Keys("n");
        Assert.Equal(32, h.Pos);
        h.Keys("n");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void NRepeatsBackwardSearch()
    {
        var h = Make(32);
        Search(h, "?hello");
        h.Keys("n");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void CapitalNReversesDirection()
    {
        var h = Make();
        Search(h, "/hello");
        h.Keys("n");
        Assert.Equal(32, h.Pos);
        h.Keys("N");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void NWithCount()
    {
        // From 20, two more matches are 32 and then 0 after wrapping.
        var h = Make();
        Search(h, "/hello");
        h.Keys("2n");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void StarSearchesWordUnderCursorForward()
    {
        var h = Make();
        h.Keys("*");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void StarMatchesWholeWordOnly()
    {
        var h = new VimHarness("foo foobar foo\n");
        h.Keys("*");
        Assert.Equal(11, h.Pos);
    }

    [Fact]
    public void HashSearchesWordUnderCursorBackward()
    {
        var h = Make(32);
        h.Keys("#");
        Assert.Equal(20, h.Pos);
    }

    [Fact]
    public void SearchStateRetainedAfterMatch()
    {
        var h = Make();
        Search(h, "/foo");
        Assert.Equal(12, h.Pos);

        // The only "foo" is the one under the caret, so wrapping comes back to it.
        h.Keys("n");
        Assert.Equal(12, h.Pos);
    }
}
