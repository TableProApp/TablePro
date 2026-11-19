using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineVisualReselectionTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    [Fact]
    public void GVReselectsLastCharacterwiseVisual()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Press("lll");
        var original = s.Selection;
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        s.Press("0");
        s.Press("j");
        s.Press("gv");
        Assert.Equal(VimMode.Visual, s.Mode);
        Assert.Equal(original, s.Selection);
    }

    [Fact]
    public void GVReselectsLastLinewiseVisual()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("V", shift: true);
        s.Press("j");
        var original = s.Selection;
        s.Escape();
        s.Press("G");
        s.Press("gv");
        Assert.Equal(VimMode.VisualLine, s.Mode);
        Assert.Equal(original, s.Selection);
    }

    [Fact]
    public void GVAfterDeleteOperationStillReselectable()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vlll");
        s.Press("d");
        Assert.Equal(VimMode.Normal, s.Mode);
        s.Press("gv");
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void JumpToLastSelectionStart()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Press("lll");
        var start = s.Selection.Location;
        s.Escape();
        s.Press("G");
        s.Press("`<");
        Assert.Equal(start, s.Selection.Location);
    }

    [Fact]
    public void JumpToLastSelectionEnd()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Press("lll");
        var inclusiveEnd = s.Selection.Location + Math.Max(0, s.Selection.Length - 1);
        s.Escape();
        s.Press("G");
        s.Press("`>");
        Assert.Equal(inclusiveEnd, s.Selection.Location);
    }

    [Fact]
    public void GVWithNoPriorSelectionIsNoOp()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("gv");
        Assert.Equal(VimMode.Normal, s.Mode);
    }
}
