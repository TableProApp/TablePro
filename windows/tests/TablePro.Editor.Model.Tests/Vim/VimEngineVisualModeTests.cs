using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

public sealed class VimEngineVisualModeTests
{
    // Line 0 is offsets 0..11, line 1 is 12..23, line 2 is 24..34.
    private const string Text = "hello world\nsecond line\nthird line\n";

    private static string Selected(VimSession s) => s.Text.Substring(s.Selection.Location, s.Selection.Length);

    [Fact]
    public void VEntersVisualMode()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void VSelectsSingleCharInitially()
    {
        var s = new VimSession(Text, caret: 3);
        s.Press("v");
        Assert.Equal(3, s.Selection.Location);
        Assert.Equal(1, s.Selection.Length);
        Assert.Equal("l", Selected(s));
    }

    [Fact]
    public void VOnEmptyBuffer()
    {
        var s = new VimSession("");
        s.Press("v");
        Assert.Equal(VimMode.Visual, s.Mode);
        Assert.Equal(0, s.Selection.Length);
    }

    [Fact]
    public void CapitalVEntersLinewiseVisual()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("V", shift: true);
        Assert.Equal(VimMode.VisualLine, s.Mode);
    }

    [Fact]
    public void CapitalVSelectsEntireLine()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("V", shift: true);
        Assert.Equal((0, 12), s.Selection);
    }

    [Fact]
    public void VTogglesOffToNormal()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vv");
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(0, s.Selection.Length);
    }

    [Fact]
    public void CapitalVTogglesOffToNormal()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("V", shift: true);
        s.Key("V", shift: true);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void VThenCapitalVSwitchesToLinewise()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("v");
        s.Key("V", shift: true);
        Assert.Equal(VimMode.VisualLine, s.Mode);
    }

    [Fact]
    public void CapitalVThenVSwitchesToCharacterwise()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("V", shift: true);
        s.Press("v");
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void EscapeExitsToNormal()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Escape();
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal(0, s.Selection.Length);
    }

    [Fact]
    public void LExtendsRightInclusive()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vl");
        Assert.Equal((0, 2), s.Selection);
        Assert.Equal("he", Selected(s));
    }

    [Fact]
    public void HExtendsLeftInclusive()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("vh");
        Assert.Equal((4, 2), s.Selection);
    }

    [Fact]
    public void WExtendsByWord()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vw");
        Assert.Equal(0, s.Selection.Location);
        Assert.Equal("hello w", Selected(s));
    }

    [Fact]
    public void EExtendsToWordEnd()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("ve");
        Assert.Equal((0, 5), s.Selection);
        Assert.Equal("hello", Selected(s));
    }

    [Fact]
    public void BExtendsBackwardByWord()
    {
        var s = new VimSession(Text, caret: 8);
        s.Press("vb");
        Assert.Equal(6, s.Selection.Location);
        Assert.Equal("wor", Selected(s));
    }

    [Fact]
    public void DollarExtendsToLineEnd()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v$");
        Assert.Equal((0, 12), s.Selection);
    }

    [Fact]
    public void ZeroExtendsToLineStart()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("v0");
        Assert.Equal((0, 6), s.Selection);
    }

    [Fact]
    public void CaretExtendsToFirstNonBlank()
    {
        var s = new VimSession("   hello\n", caret: 7);
        s.Press("v^");
        Assert.Equal((3, 5), s.Selection);
    }

    [Fact]
    public void JExtendsToNextLine()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vj");
        Assert.Equal(0, s.Selection.Location);
        Assert.Equal("hello world\ns", Selected(s));
    }

    [Fact]
    public void KExtendsToPreviousLine()
    {
        var s = new VimSession(Text, caret: 15);
        s.Press("vk");
        Assert.Equal((3, 13), s.Selection);
    }

    [Fact]
    public void GGExtendsToBufferStart()
    {
        var s = new VimSession(Text, caret: 15);
        s.Press("vgg");
        Assert.Equal((0, 16), s.Selection);
    }

    [Fact]
    public void CapitalGExtendsToBufferEnd()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Key("G", shift: true);
        Assert.Equal(0, s.Selection.Location);
        Assert.Equal(s.Text.Length, s.Selection.Location + s.Selection.Length);
    }

    [Fact]
    public void OSwapsAnchorAndCursor()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("vll");
        Assert.Equal((5, 3), s.Selection);
        s.Press("o");
        // After o the cursor is the left end, so h grows the selection leftward.
        s.Press("h");
        Assert.Equal(4, s.Selection.Location);
    }

    [Fact]
    public void OInLinewise()
    {
        var s = new VimSession(Text, caret: 12);
        s.Key("V", shift: true);
        s.Press("j");
        s.Press("o");
        s.Press("k");
        Assert.Equal(0, s.Selection.Location);
    }

    [Fact]
    public void AnchorStaysFixedAcrossExtendingAndShrinking()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("v");
        s.Press("lll");
        Assert.Equal((5, 4), s.Selection);
        s.Press("hhh");
        Assert.Equal((5, 1), s.Selection);
    }

    [Fact]
    public void CursorCanCrossAnchorLeftward()
    {
        var s = new VimSession(Text, caret: 5);
        s.Press("vhhh");
        Assert.Equal((2, 4), s.Selection);
    }

    [Fact]
    public void DDeletesSelection()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vlld");
        Assert.Equal("lo world\nsecond line\nthird line\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void XIsAliasForDInVisual()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vllx");
        Assert.Equal("lo world\nsecond line\nthird line\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void YYanksSelectionWithoutModifyingBuffer()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vey");
        Assert.Equal(Text, s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void YReturnsCursorToAnchor()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vey");
        Assert.Equal(0, s.Selection.Location);
    }

    [Fact]
    public void CChangesSelectionAndEntersInsert()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vlc");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("llo world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void DeleteThenPasteRoundTrip()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vlld");
        s.Key("P", shift: true);
        Assert.Equal(Text, s.Text);
    }

    [Fact]
    public void LinewiseDDeletesWholeLine()
    {
        var s = new VimSession(Text, caret: 5);
        s.Key("V", shift: true);
        s.Press("d");
        Assert.Equal("second line\nthird line\n", s.Text);
    }

    [Fact]
    public void LinewiseDMultipleLines()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("V", shift: true);
        s.Press("jd");
        Assert.Equal("third line\n", s.Text);
    }

    [Fact]
    public void LinewiseYThenP()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("V", shift: true);
        s.Press("yp");
        Assert.Equal("hello world\nhello world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void LinewiseCDeletesContentEntersInsert()
    {
        var s = new VimSession(Text, caret: 0);
        s.Key("V", shift: true);
        s.Press("c");
        Assert.Equal(VimMode.Insert, s.Mode);
        Assert.Equal("\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void TildeTogglesCaseInVisual()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("ve");
        s.Press("~");
        Assert.Equal("HELLO world\nsecond line\nthird line\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void GuLowercasesSelection()
    {
        var s = new VimSession("Hello World\n", caret: 0);
        s.Press("v$");
        s.Press("u");
        Assert.Equal("hello world\n", s.Text);
    }

    [Fact]
    public void GUUppercaseSelection()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Press("e");
        s.Key("U", shift: true);
        Assert.Equal("HELLO world\nsecond line\nthird line\n", s.Text);
    }

    [Fact]
    public void RReplacesSelectionWithSingleChar()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("ve");
        s.Press("rX");
        Assert.Equal("XXXXX world\nsecond line\nthird line\n", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void VisualAtBufferStart()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("vh");
        Assert.Equal((0, 1), s.Selection);
    }

    [Fact]
    public void VisualAtBufferEnd()
    {
        var s = new VimSession(Text, caret: 34);
        s.Press("v");
        Assert.Equal((34, 1), s.Selection);
        s.Press("l");
        Assert.Equal(34, s.Selection.Location);
    }

    [Fact]
    public void VisualDeleteAllContent()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        s.Key("G", shift: true);
        s.Press("d");
        Assert.Equal("", s.Text);
        Assert.Equal(VimMode.Normal, s.Mode);
    }

    [Fact]
    public void UnknownKeyConsumedInVisual()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("v");
        Assert.True(s.Key("z"));
        Assert.Equal(VimMode.Visual, s.Mode);
    }

    [Fact]
    public void IInVisualBlockShouldInsertAtSelectionStart()
    {
        var s = new VimSession(Text, caret: 0);
        s.Press("ve");
        s.Key("I", shift: true);
        Assert.Equal(VimMode.Insert, s.Mode);
    }

    [Fact]
    public void VisualDisplayLabel()
    {
        var s = new VimSession(Text);
        s.Press("v");
        Assert.Equal("VISUAL", s.Engine.ModeLabel);
    }

    [Fact]
    public void VisualLineDisplayLabel()
    {
        var s = new VimSession(Text);
        s.Key("V", shift: true);
        Assert.Equal("VISUAL LINE", s.Engine.ModeLabel);
    }

    [Fact]
    public void ARegisterBeforeYInVisualModeTakesTheYank()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("viw\"ay");
        Assert.Equal("abc", s.Engine.NamedRegisters["a"].Text);
    }

    [Fact]
    public void ARegisterBeforeDInVisualModeTakesTheDelete()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("viw\"bd");
        Assert.Equal(" def\n", s.Text);
        Assert.Equal("abc", s.Engine.NamedRegisters["b"].Text);
    }

    [Fact]
    public void InnerWordInVisualLineModeSelectsTheWordCharacterwise()
    {
        var s = new VimSession("hello world\nfoo\n", caret: 0);
        s.Press("Viwd");
        Assert.Equal(" world\nfoo\n", s.Text);
    }

    [Fact]
    public void PasteOverASelectionPutsTheReplacedTextInTheUnnamedRegister()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("yiwwviwp");
        Assert.Equal("abc abc\n", s.Text);
        Assert.Equal("def", s.Engine.Register.Text);
    }

    [Fact]
    public void CapitalPOverASelectionLeavesTheRegisters()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("yiwwviwP");
        Assert.Equal("abc abc\n", s.Text);
        Assert.Equal("abc", s.Engine.Register.Text);
    }

    [Fact]
    public void PasteOverASelectionFromANamedRegister()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("\"ayiwwviw\"ap");
        Assert.Equal("abc abc\n", s.Text);
        Assert.Equal("abc", s.Engine.NamedRegisters["a"].Text);
        Assert.Equal("def", s.Engine.Register.Text);
    }

    [Fact]
    public void EscapeDropsARegisterTypedInVisualMode()
    {
        var s = new VimSession("abc def\n", caret: 0);
        s.Press("v\"a");
        s.Escape();
        s.Press("yiw");
        Assert.False(s.Engine.NamedRegisters.ContainsKey("a"));
        Assert.Equal("abc", s.Engine.Register.Text);
    }
}
