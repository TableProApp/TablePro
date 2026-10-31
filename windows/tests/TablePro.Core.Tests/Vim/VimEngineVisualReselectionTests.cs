using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>gv, which reselects the last visual selection, and the `&lt; and `&gt; marks that bracket it.</summary>
public sealed class VimEngineVisualReselectionTests
{
    private const string Text = "hello world\nsecond line\nthird line\n";

    private static VimHarness Make() => new(Text);

    [Fact]
    public void GvReselectsLastCharacterwiseVisual()
    {
        var h = Make();
        h.Keys("v");
        h.Keys("lll");
        var original = (h.Buffer.SelectionStart, h.Buffer.SelectionLength);
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
        h.Keys("0");
        h.Keys("j");
        h.Keys("gv");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
        Assert.Equal(original, (h.Buffer.SelectionStart, h.Buffer.SelectionLength));
    }

    [Fact]
    public void GvReselectsLastLinewiseVisual()
    {
        var h = Make();
        h.Key('V', shift: true);
        h.Keys("j");
        var original = (h.Buffer.SelectionStart, h.Buffer.SelectionLength);
        h.Key('\u001B');
        h.Keys("G");
        h.Keys("gv");
        Assert.Equal(VimMode.Visual(linewise: true), h.Mode);
        Assert.Equal(original, (h.Buffer.SelectionStart, h.Buffer.SelectionLength));
    }

    [Fact]
    public void GvAfterDeleteOperationStillReselectable()
    {
        // The bounds may have moved with the edit, but there is still a region to reselect.
        var h = Make();
        h.Keys("vlll");
        h.Keys("d");
        Assert.Equal(VimMode.Normal, h.Mode);
        h.Keys("gv");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void JumpToLastSelectionStart()
    {
        var h = Make();
        h.Keys("v");
        h.Keys("lll");
        var start = h.Buffer.SelectionStart;
        h.Key('\u001B');
        h.Keys("G");
        h.Keys("`<");
        Assert.Equal(start, h.Pos);
    }

    [Fact]
    public void JumpToLastSelectionEnd()
    {
        var h = Make();
        h.Keys("v");
        h.Keys("lll");
        var inclusiveEnd = h.Buffer.SelectionStart + Math.Max(0, h.Buffer.SelectionLength - 1);
        h.Key('\u001B');
        h.Keys("G");
        h.Keys("`>");
        Assert.Equal(inclusiveEnd, h.Pos);
    }

    [Fact]
    public void GvWithNoPriorSelectionIsNoOp()
    {
        var h = new VimHarness(Text, 5);
        h.Keys("gv");
        Assert.Equal(VimMode.Normal, h.Mode);
    }
}
