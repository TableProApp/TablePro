namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineScrollTests
{
    // Thirty lines, all on screen, so half a page is 15 lines.
    private static readonly string Text = string.Concat(Enumerable.Range(0, 30).Select(i => $"line{i}\n"));

    private static VimSession OnLine(int line)
    {
        var s = new VimSession(Text);
        s.SetCaret(s.Engine.Buffer.Offset(line, 0));
        return s;
    }

    private static bool Ctrl(VimSession s, char c) => s.Key(((char)(c & 0x1F)).ToString());

    private static int Line(VimSession s) => s.Engine.Buffer.LineAndColumn(s.Caret).Line;

    [Fact]
    public void CtrlDScrollsHalfPageDown()
    {
        var s = OnLine(0);
        Ctrl(s, 'd');
        Assert.Equal(15, Line(s));
    }

    [Fact]
    public void CtrlUScrollsHalfPageUp()
    {
        var s = OnLine(25);
        Ctrl(s, 'u');
        Assert.Equal(10, Line(s));
    }

    [Fact]
    public void CtrlFScrollsFullPageDown()
    {
        var s = OnLine(0);
        Ctrl(s, 'f');
        Assert.Equal(29, Line(s));
    }

    [Fact]
    public void CtrlBScrollsFullPageUp()
    {
        var s = OnLine(29);
        Ctrl(s, 'b');
        Assert.Equal(0, Line(s));
    }

    [Fact]
    public void CtrlEScrollsViewportDown()
    {
        var s = OnLine(0);
        Assert.True(Ctrl(s, 'e'), "Ctrl+E should be consumed by the engine even when nothing scrolls");
    }

    [Fact]
    public void CtrlYScrollsViewportUp()
    {
        var s = OnLine(0);
        Assert.True(Ctrl(s, 'y'));
    }

    [Fact]
    public void ZtPlacesCursorLineAtTop()
    {
        var s = OnLine(10);
        s.Press("zt");
        Assert.Equal(10, Line(s));
    }

    [Fact]
    public void ZzCentersCursorLine()
    {
        var s = OnLine(5);
        s.Press("zz");
        Assert.Equal(5, Line(s));
    }

    [Fact]
    public void ZbPlacesCursorLineAtBottom()
    {
        var s = OnLine(20);
        s.Press("zb");
        Assert.Equal(20, Line(s));
    }

    [Fact]
    public void GJMovesByDisplayLine()
    {
        var s = OnLine(0);
        s.Press("gj");
        Assert.Equal(1, Line(s));
    }

    [Fact]
    public void GKMovesByDisplayLine()
    {
        var s = OnLine(5);
        s.Press("gk");
        Assert.Equal(4, Line(s));
    }
}
