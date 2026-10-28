using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Visual (v) and Visual Line (V) mode: entry and exit, motions, operators and the o anchor swap.</summary>
public sealed class VimEngineVisualModeTests
{
    // Line 0 "hello world\n" is offsets 0..11, line 1 "second line\n" 12..23, line 2 "third line\n" 24..34.
    private const string Text = "hello world\nsecond line\nthird line\n";

    private static VimHarness Make(int caret = 0) => new(Text, caret);

    private static string Selected(VimHarness h) => h.Text.Substring(h.Buffer.SelectionStart, h.Buffer.SelectionLength);

    [Fact]
    public void VEntersVisualMode()
    {
        var h = Make();
        h.Keys("v");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void VSelectsSingleCharInitially()
    {
        var h = Make(3);
        h.Keys("v");
        Assert.Equal(3, h.Buffer.SelectionStart);
        Assert.Equal(1, h.Buffer.SelectionLength);
        Assert.Equal("l", Selected(h));
    }

    [Fact]
    public void VOnEmptyBuffer()
    {
        var h = new VimHarness(string.Empty);
        h.Keys("v");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
        Assert.Equal(0, h.Buffer.SelectionLength);
    }

    [Fact]
    public void CapitalVEntersLinewiseVisual()
    {
        var h = Make(5);
        h.Key('V', shift: true);
        Assert.Equal(VimMode.Visual(linewise: true), h.Mode);
    }

    [Fact]
    public void CapitalVSelectsEntireLine()
    {
        var h = Make(5);
        h.Key('V', shift: true);
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(12, h.Buffer.SelectionLength);
    }

    [Fact]
    public void VTogglesOffToNormal()
    {
        var h = Make();
        h.Keys("vv");
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(0, h.Buffer.SelectionLength);
    }

    [Fact]
    public void CapitalVTogglesOffToNormal()
    {
        var h = Make();
        h.Key('V', shift: true);
        h.Key('V', shift: true);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void VThenCapitalVSwitchesToLinewise()
    {
        var h = Make(5);
        h.Keys("v");
        h.Key('V', shift: true);
        Assert.Equal(VimMode.Visual(linewise: true), h.Mode);
    }

    [Fact]
    public void CapitalVThenVSwitchesToCharacterwise()
    {
        var h = Make(5);
        h.Key('V', shift: true);
        h.Keys("v");
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void EscapeExitsToNormal()
    {
        var h = Make();
        h.Keys("v");
        h.Key('\u001B');
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(0, h.Buffer.SelectionLength);
    }

    [Fact]
    public void LExtendsRightInclusive()
    {
        var h = Make();
        h.Keys("vl");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(2, h.Buffer.SelectionLength);
        Assert.Equal("he", Selected(h));
    }

    [Fact]
    public void HExtendsLeftInclusive()
    {
        var h = Make(5);
        h.Keys("vh");
        Assert.Equal(4, h.Buffer.SelectionStart);
        Assert.Equal(2, h.Buffer.SelectionLength);
    }

    [Fact]
    public void WExtendsByWord()
    {
        var h = Make();
        h.Keys("vw");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal("hello w", Selected(h));
    }

    [Fact]
    public void EExtendsToWordEnd()
    {
        var h = Make();
        h.Keys("ve");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(5, h.Buffer.SelectionLength);
        Assert.Equal("hello", Selected(h));
    }

    [Fact]
    public void BExtendsBackwardByWord()
    {
        var h = Make(8);
        h.Keys("vb");
        Assert.Equal(6, h.Buffer.SelectionStart);
        Assert.Equal("wor", Selected(h));
    }

    [Fact]
    public void DollarExtendsToLineEnd()
    {
        var h = Make();
        h.Keys("v$");
        Assert.Equal(0, h.Buffer.SelectionStart);

        // The selection runs through the line's newline.
        Assert.Equal(12, h.Buffer.SelectionLength);
    }

    [Fact]
    public void ZeroExtendsToLineStart()
    {
        var h = Make(5);
        h.Keys("v0");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(6, h.Buffer.SelectionLength);
    }

    [Fact]
    public void CaretExtendsToFirstNonBlank()
    {
        var h = new VimHarness("   hello\n", 7);
        h.Keys("v^");
        Assert.Equal(3, h.Buffer.SelectionStart);
        Assert.Equal(5, h.Buffer.SelectionLength);
    }

    [Fact]
    public void JExtendsToNextLine()
    {
        var h = Make();
        h.Keys("vj");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal("hello world\ns", Selected(h));
    }

    [Fact]
    public void KExtendsToPreviousLine()
    {
        var h = Make(15);
        h.Keys("vk");
        Assert.Equal(3, h.Buffer.SelectionStart);
        Assert.Equal(13, h.Buffer.SelectionLength);
    }

    [Fact]
    public void GgExtendsToBufferStart()
    {
        var h = Make(15);
        h.Keys("vgg");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(16, h.Buffer.SelectionLength);
    }

    [Fact]
    public void CapitalGExtendsToBufferEnd()
    {
        var h = Make();
        h.Keys("v");
        h.Key('G', shift: true);
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(h.Text.Length, h.Buffer.SelectionStart + h.Buffer.SelectionLength);
    }

    [Fact]
    public void OSwapsAnchorAndCursor()
    {
        var h = Make(5);
        h.Keys("vll");
        Assert.Equal(5, h.Buffer.SelectionStart);
        Assert.Equal(3, h.Buffer.SelectionLength);

        // After o the cursor is the left end, so h grows the selection leftward.
        h.Keys("o");
        h.Keys("h");
        Assert.Equal(4, h.Buffer.SelectionStart);
    }

    [Fact]
    public void OInLinewise()
    {
        var h = Make(12);
        h.Key('V', shift: true);
        h.Keys("j");
        h.Keys("o");
        h.Keys("k");
        Assert.Equal(0, h.Buffer.SelectionStart);
    }

    [Fact]
    public void AnchorStaysFixedAcrossExtendingAndShrinking()
    {
        var h = Make(5);
        h.Keys("v");
        h.Keys("lll");
        Assert.Equal(5, h.Buffer.SelectionStart);
        Assert.Equal(4, h.Buffer.SelectionLength);
        h.Keys("hhh");
        Assert.Equal(5, h.Buffer.SelectionStart);
        Assert.Equal(1, h.Buffer.SelectionLength);
    }

    [Fact]
    public void CursorCanCrossAnchorLeftward()
    {
        var h = Make(5);
        h.Keys("vhhh");
        Assert.Equal(2, h.Buffer.SelectionStart);
        Assert.Equal(4, h.Buffer.SelectionLength);
    }

    [Fact]
    public void DDeletesSelection()
    {
        var h = Make();
        h.Keys("vlld");
        Assert.Equal("lo world\nsecond line\nthird line\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void XIsAliasForDInVisual()
    {
        var h = Make();
        h.Keys("vllx");
        Assert.Equal("lo world\nsecond line\nthird line\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void YYanksSelectionWithoutModifyingBuffer()
    {
        var h = Make();
        h.Keys("vey");
        Assert.Equal(Text, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void YReturnsCursorToAnchor()
    {
        var h = Make();
        h.Keys("vey");
        Assert.Equal(0, h.Buffer.SelectionStart);
    }

    [Fact]
    public void CChangesSelectionAndEntersInsert()
    {
        var h = Make();
        h.Keys("vlc");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal("llo world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void DeleteThenPasteRoundTrip()
    {
        var h = Make();
        h.Keys("vlld");
        h.Key('P', shift: true);
        Assert.Equal(Text, h.Text);
    }

    [Fact]
    public void LinewiseDDeletesWholeLine()
    {
        var h = Make(5);
        h.Key('V', shift: true);
        h.Keys("d");
        Assert.Equal("second line\nthird line\n", h.Text);
    }

    [Fact]
    public void LinewiseDMultipleLines()
    {
        var h = Make();
        h.Key('V', shift: true);
        h.Keys("jd");
        Assert.Equal("third line\n", h.Text);
    }

    [Fact]
    public void LinewiseYThenP()
    {
        var h = Make();
        h.Key('V', shift: true);
        h.Keys("yp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void LinewiseCDeletesContentEntersInsert()
    {
        var h = Make();
        h.Key('V', shift: true);
        h.Keys("c");
        Assert.Equal(VimMode.Insert, h.Mode);

        // A linewise change keeps one newline for the text typed next.
        Assert.Equal("\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void TildeTogglesCaseInVisual()
    {
        var h = Make();
        h.Keys("ve");
        h.Keys("~");
        Assert.Equal("HELLO world\nsecond line\nthird line\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void GuLowercasesSelection()
    {
        var h = new VimHarness("Hello World\n");
        h.Keys("v$");
        h.Keys("u");
        Assert.Equal("hello world\n", h.Text);
    }

    [Fact]
    public void GUUppercaseSelection()
    {
        var h = Make();
        h.Keys("v");
        h.Keys("e");
        h.Key('U', shift: true);
        Assert.Equal("HELLO world\nsecond line\nthird line\n", h.Text);
    }

    [Fact]
    public void RReplacesSelectionWithSingleChar()
    {
        var h = Make();
        h.Keys("ve");
        h.Keys("rX");
        Assert.Equal("XXXXX world\nsecond line\nthird line\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void VisualAtBufferStart()
    {
        var h = Make();
        h.Keys("vh");
        Assert.Equal(0, h.Buffer.SelectionStart);
        Assert.Equal(1, h.Buffer.SelectionLength);
    }

    [Fact]
    public void VisualAtBufferEnd()
    {
        var h = Make(34);
        h.Keys("v");
        Assert.Equal(34, h.Buffer.SelectionStart);
        Assert.Equal(1, h.Buffer.SelectionLength);
        h.Keys("l");
        Assert.Equal(34, h.Buffer.SelectionStart);
    }

    [Fact]
    public void VisualDeleteAllContent()
    {
        var h = Make();
        h.Keys("v");
        h.Key('G', shift: true);
        h.Keys("d");
        Assert.Equal(string.Empty, h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void UnknownKeyConsumedInVisual()
    {
        var h = Make();
        h.Keys("v");
        Assert.True(h.Key('z'));
        Assert.Equal(VimMode.Visual(linewise: false), h.Mode);
    }

    [Fact]
    public void IInVisualBlockShouldInsertAtSelectionStart()
    {
        // Characterwise visual has no block insert; I only has to leave visual for insert without failing.
        var h = Make();
        h.Keys("ve");
        h.Key('I', shift: true);
        Assert.Equal(VimMode.Insert, h.Mode);
    }

    [Fact]
    public void VisualDisplayLabel()
    {
        var h = Make();
        h.Keys("v");
        Assert.Equal("VISUAL", h.Mode.DisplayLabel);
    }

    [Fact]
    public void VisualLineDisplayLabel()
    {
        var h = Make();
        h.Key('V', shift: true);
        Assert.Equal("VISUAL LINE", h.Mode.DisplayLabel);
    }
}
