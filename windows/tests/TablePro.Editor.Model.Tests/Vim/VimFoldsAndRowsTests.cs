using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

// Motions over the folds and wrapped rows of windows/docs/decisions/0002-sql-editor-control.md, as Vim moves over its
// own closed folds and screen lines.
public sealed class VimFoldsAndRowsTests
{
    // Lines 1 to 3 fold under line 1: "select a," stays on screen and "b," and "c" hide.
    private const string Script = "x;\nselect a,\n  b,\n  c\nfrom t;\nlast;\n";

    private static VimSession Folded(int caret)
    {
        var s = new VimSession(Script, caret);
        s.Model.Rows.Folds.Fold(new FoldRegion(1, 3));
        return s;
    }

    private static int LineStart(VimSession s, int line) => s.Model.Document.GetLineStart(line);

    [Fact]
    public void JStepsOverAClosedFoldAsOneLine()
    {
        var s = Folded(caret: 0);
        s.Press("j");
        Assert.Equal(LineStart(s, 1), s.Caret);
        s.Press("j");
        Assert.Equal(LineStart(s, 4), s.Caret);
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void KLandsOnTheFoldsFirstLine()
    {
        var s = Folded(caret: Script.IndexOf("from", StringComparison.Ordinal));
        s.Press("k");
        Assert.Equal(LineStart(s, 1), s.Caret);
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void ACountCountsAClosedFoldOnce()
    {
        var s = Folded(caret: 0);
        s.Press("2j");
        Assert.Equal(LineStart(s, 4), s.Caret);
    }

    [Fact]
    public void DdOnAClosedFoldDeletesEveryLineItHides()
    {
        var s = Folded(caret: LineStart(new VimSession(Script), 1));
        s.Press("dd");
        Assert.Equal("x;\nfrom t;\nlast;\n", s.Text);
        Assert.Equal("select a,\n  b,\n  c\n", s.Engine.Register.Text);
        Assert.True(s.Engine.Register.IsLinewise);
    }

    [Fact]
    public void DjFromAboveAFoldTakesTheFoldWhole()
    {
        var s = Folded(caret: 0);
        s.Press("dj");
        Assert.Equal("from t;\nlast;\n", s.Text);
    }

    [Fact]
    public void YyOnAFoldYanksItsLinesAndPPastesBelowIt()
    {
        var s = Folded(caret: Script.IndexOf("select", StringComparison.Ordinal));
        s.Press("yyp");
        Assert.Equal("x;\nselect a,\n  b,\n  c\nselect a,\n  b,\n  c\nfrom t;\nlast;\n", s.Text);
        Assert.Equal(LineStart(s, 4), s.Caret);
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void OOnAFoldOpensALineBelowIt()
    {
        var s = Folded(caret: Script.IndexOf("select", StringComparison.Ordinal));
        s.Press("o");
        s.Type("y;");
        Assert.Equal("x;\nselect a,\n  b,\n  c\ny;\nfrom t;\nlast;\n", s.Text);
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void VisualLineOnAFoldSelectsItWhole()
    {
        var s = Folded(caret: Script.IndexOf("select", StringComparison.Ordinal));
        s.Press("V");
        Assert.Equal((LineStart(s, 1), "select a,\n  b,\n  c\n".Length), s.Selection);
    }

    [Fact]
    public void VisualJStepsOverAFold()
    {
        var s = Folded(caret: 0);
        s.Press("vjj");
        Assert.Equal(LineStart(s, 4), s.Engine.CursorPosition);
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void ASearchIntoAFoldOpensIt()
    {
        var s = Folded(caret: 0);
        s.Press("/  c\r");
        Assert.Equal(Script.IndexOf("  c", StringComparison.Ordinal), s.Caret);
        Assert.False(s.Model.Rows.Folds.IsFolded(1));
    }

    [Fact]
    public void GjMovesByWrappedRowsAndJByLines()
    {
        var s = new VimSession("abcdefghij klmnop\nnext\n", caret: 1);
        s.Model.Rows.SetWrap(8, 4);
        s.Press("gj");
        Assert.Equal(1, s.Model.Rows.RowOf(s.Caret));
        Assert.Equal(0, s.Model.Document.GetLineFromOffset(s.Caret));
        s.Press("gk");
        Assert.Equal(1, s.Caret);
        s.Press("j");
        Assert.Equal(1, s.Model.Document.GetLineFromOffset(s.Caret));
    }

    [Fact]
    public void GjKeepsItsColumnAcrossAShortRow()
    {
        var s = new VimSession("abcdefgh\nab\nabcdefgh\n", caret: 5);
        s.Press("gj");
        Assert.Equal(10, s.Caret);
        s.Press("gj");
        Assert.Equal(17, s.Caret);
    }

    [Fact]
    public void HmlReadTheRowsOnScreen()
    {
        var s = Folded(caret: 0);
        s.Visible = (0, 3);
        s.Press("L");
        Assert.Equal(LineStart(s, 5), s.Caret);
        s.Press("H");
        Assert.Equal(0, s.Caret);
        s.Press("M");
        Assert.Equal(LineStart(s, 1), s.Caret);
    }

    [Theory]
    [InlineData("zo", VimFold.Open)]
    [InlineData("zc", VimFold.Close)]
    [InlineData("za", VimFold.Toggle)]
    [InlineData("zR", VimFold.OpenAll)]
    [InlineData("zM", VimFold.CloseAll)]
    public void ZFoldCommandsGoToTheEditor(string keys, VimFold command)
    {
        var s = new VimSession(Script);
        s.Press(keys);
        Assert.Equal([command], s.Folds);
        Assert.Equal(Script, s.Text);
        Assert.Equal(string.Empty, s.Engine.PendingKeys);
    }

    [Theory]
    [InlineData("zz", VimScroll.Middle)]
    [InlineData("zt", VimScroll.Top)]
    [InlineData("zb", VimScroll.Bottom)]
    public void ZScrollCommandsGoToTheEditor(string keys, VimScroll position)
    {
        var s = new VimSession(Script, caret: 3);
        s.Press(keys);
        Assert.Equal([position], s.Scrolls);
        Assert.Equal(3, s.Caret);
    }

    [Fact]
    public void ControlEScrollsAndKeepsTheCaretOnScreen()
    {
        var s = new VimSession("a\nb\nc\nd\ne\nf\n", caret: 0);
        s.Visible = (0, 2);
        s.Press("\u0005");
        Assert.Equal([1], s.ScrolledRows);
        Assert.Equal(2, s.Caret);
        s.Press("2\u0019");
        Assert.Equal([1, -2], s.ScrolledRows);
        Assert.Equal(2, s.Caret);
    }
}
