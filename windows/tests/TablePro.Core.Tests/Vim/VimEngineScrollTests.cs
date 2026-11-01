namespace TablePro.Core.Tests.Vim;

/// <summary>Scroll commands and viewport-relative commands over a 30-line buffer the fake shows in full.</summary>
public sealed class VimEngineScrollTests
{
    private static readonly string ThirtyLines = string.Concat(Enumerable.Range(0, 30).Select(i => $"line{i}\n"));

    private static VimHarness AtLine(int line)
    {
        var h = new VimHarness(ThirtyLines);
        h.Select(h.Buffer.OffsetForLine(line, 0));
        return h;
    }

    private static bool Ctrl(VimHarness h, char letter) => h.Key((char)(letter & 0x1F));

    private static int LineOf(VimHarness h) => h.Buffer.LineAndColumn(h.Pos).Line;

    [Fact]
    public void CtrlDScrollsHalfPageDown()
    {
        // Lines 0 to 29 are visible, so half a page is 15 lines.
        var h = AtLine(0);
        Ctrl(h, 'd');
        Assert.Equal(15, LineOf(h));
    }

    [Fact]
    public void CtrlUScrollsHalfPageUp()
    {
        var h = AtLine(25);
        Ctrl(h, 'u');
        Assert.Equal(10, LineOf(h));
    }

    [Fact]
    public void CtrlFScrollsFullPageDown()
    {
        var h = AtLine(0);
        Ctrl(h, 'f');
        Assert.Equal(29, LineOf(h));
    }

    [Fact]
    public void CtrlBScrollsFullPageUp()
    {
        var h = AtLine(29);
        Ctrl(h, 'b');
        Assert.Equal(0, LineOf(h));
    }

    [Fact]
    public void CtrlEScrollsViewportDown()
    {
        // Nothing can scroll when the whole buffer is visible, but the key is still the engine's.
        var h = AtLine(0);
        Assert.True(Ctrl(h, 'e'));
    }

    [Fact]
    public void CtrlYScrollsViewportUp()
    {
        var h = AtLine(0);
        Assert.True(Ctrl(h, 'y'));
    }

    [Fact]
    public void ZtPlacesCursorLineAtTop()
    {
        // z commands move the viewport, never the caret.
        var h = AtLine(10);
        h.Keys("zt");
        Assert.Equal(10, LineOf(h));
    }

    [Fact]
    public void ZzCentersCursorLine()
    {
        var h = AtLine(5);
        h.Keys("zz");
        Assert.Equal(5, LineOf(h));
    }

    [Fact]
    public void ZbPlacesCursorLineAtBottom()
    {
        var h = AtLine(20);
        h.Keys("zb");
        Assert.Equal(20, LineOf(h));
    }

    [Fact]
    public void GjMovesByDisplayLine()
    {
        // Without wrapping, a display line is a buffer line.
        var h = AtLine(0);
        h.Keys("gj");
        Assert.Equal(1, LineOf(h));
    }

    [Fact]
    public void GkMovesByDisplayLine()
    {
        var h = AtLine(5);
        h.Keys("gk");
        Assert.Equal(4, LineOf(h));
    }
}
