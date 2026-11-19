using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

// Commands at their edges: cancelled prefixes, huge counts, registers and marks across edits, and keys the editor
// handles inside a recorded macro.
public sealed class VimCommandEdgeTests
{
    [Fact]
    public void HugeCountsOnBothSidesOfAnOperatorStayBounded()
    {
        var s = new VimSession("a\nb\nc\n", caret: 0);
        s.Press("32768d65536j");
        Assert.Equal(string.Empty, s.Text);
    }

    [Fact]
    public void EscapeCancelsAnOperatorWaitingForAFindCharacter()
    {
        var s = new VimSession("one two", caret: 0);
        s.Press("df");
        s.Escape();
        s.Press("w");
        Assert.Equal("one two", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void EscapeDropsTheCountBeforeAnOperator()
    {
        var s = new VimSession("abcdef", caret: 0);
        s.Press("3d");
        s.Escape();
        s.Press("x");
        Assert.Equal("bcdef", s.Text);
        Assert.False(s.Engine.IsPending);
    }

    [Fact]
    public void AMotionAfterAVisualTextObjectGrowsItsSelection()
    {
        var s = new VimSession("one two", caret: 1);
        s.Press("viw");
        Assert.Equal((0, 3), s.Selection);
        Assert.Equal(2, s.Engine.CursorPosition);
        s.Press("l");
        Assert.Equal((0, 4), s.Selection);
        Assert.Equal(3, s.Engine.CursorPosition);
    }

    [Fact]
    public void ACountedPasteFromARegisterPastesItEachTime()
    {
        var s = new VimSession("ab\n", caret: 0);
        s.Press("\"ayl");
        s.Press("lyl");
        Assert.Equal("b", s.Engine.Register.Text);
        s.Press("\"a2p");
        Assert.Equal("abaa\n", s.Text);
    }

    [Fact]
    public void AMarkMovesWithTextTypedBeforeIt()
    {
        var s = new VimSession("one two", caret: 4);
        s.Press("ma0i");
        s.Type("X");
        s.Escape();
        s.Press("`a");
        Assert.Equal(5, s.Caret);
    }

    [Fact]
    public void AMarkMovesBackWithAnUndo()
    {
        var s = new VimSession("one two", caret: 0);
        s.Press("x");
        s.Press("wmau`a");
        Assert.Equal("one two", s.Text);
        Assert.Equal(4, s.Caret);
    }

    [Fact]
    public void PercentAfterAnOperatorTakesTheBracketsAndWhatIsBetweenThem()
    {
        var s = new VimSession("(a) foo", caret: 0);
        s.Press("y%");
        Assert.Equal("(a)", s.Engine.Register.Text);
        s.Press("d%");
        Assert.Equal(" foo", s.Text);
    }

    [Fact]
    public void PercentWithNoBracketDropsTheOperator()
    {
        var s = new VimSession("abc", caret: 0);
        s.Press("d%");
        Assert.False(s.Engine.IsPending);
        s.Press("l");
        Assert.Equal("abc", s.Text);
        Assert.Equal(1, s.Caret);
    }

    [Fact]
    public void EnterAndPlusGoToTheNextLinesFirstCharacterAndMinusBack()
    {
        var s = new VimSession("a\n  b\n  c\n", caret: 0);
        s.Press("\r");
        Assert.Equal(4, s.Caret);
        s.Press("+");
        Assert.Equal(8, s.Caret);
        s.Press("2-");
        Assert.Equal(0, s.Caret);
        s.Press("d\r");
        Assert.Equal("  c\n", s.Text);
    }

    [Fact]
    public void AMacroReplaysTheMovesInsertModeLeftToTheEditor()
    {
        var registers = new VimRegisters();
        var s = new VimSession(string.Empty, registers: registers);
        s.Press("qqi");
        s.Type("ab");
        s.Engine.BreakInsertUndo();
        s.Model.Move(CaretMove.Left, extend: false);
        s.Engine.RecordEditorKey(new VimEditorKey(VimSession.LeftKey));
        s.Type("X");
        s.Escape();
        s.Press("q");
        Assert.Equal("aXb", s.Text);

        var replay = new VimSession(string.Empty, registers: registers);
        replay.Press("@q");
        Assert.Equal("aXb", replay.Text);
    }

    [Fact]
    public void VisualLineOnAFoldAtTheEndOfTheTextKeepsItClosed()
    {
        var s = new VimSession("x;\nselect a,\n  b,\n  c", caret: 3);
        s.Model.Rows.Folds.Fold(new FoldRegion(1, 3));
        s.Press("V");
        Assert.True(s.Model.Rows.Folds.IsFolded(1));
        Assert.Equal((3, s.Text.Length - 3), s.Selection);
        s.Press("d");
        Assert.Equal("x;\n", s.Text);
    }

    [Fact]
    public void AReplaceModeMacroReplaysItsMovesAsMoves()
    {
        var registers = new VimRegisters();
        var s = new VimSession("abcd", registers: registers);
        s.Press("qqRX");
        s.Engine.BreakInsertUndo();
        s.Model.Move(CaretMove.Left, extend: false);
        s.Engine.RecordEditorKey(new VimEditorKey(VimSession.LeftKey));
        s.Press("Y");
        s.Escape();
        s.Press("q");
        Assert.Equal("Ybcd", s.Text);

        var replay = new VimSession("abcd", registers: registers);
        replay.Press("@q");
        Assert.Equal("Ybcd", replay.Text);
    }

    [Fact]
    public void ResetDropsACommandWaitingInVisualMode()
    {
        var s = new VimSession("abcd", caret: 0);
        s.Press("vr");
        s.Engine.Reset();
        Assert.False(s.Engine.IsPending);
        s.Press("vl");
        Assert.Equal("abcd", s.Text);
        Assert.Equal((0, 2), s.Selection);
    }

    [Fact]
    public void AMacroHandsBackTheEditorKeysItRecordedWithTheirModifiers()
    {
        var registers = new VimRegisters();
        var s = new VimSession(string.Empty, registers: registers);
        var wordLeft = new VimEditorKey(VimSession.LeftKey, Control: true);
        s.Press("qqi");
        s.Type("one two");
        s.Engine.RecordEditorKey(wordLeft);
        s.Escape();
        s.Press("q");

        var replay = new VimSession(string.Empty, registers: registers);
        replay.Press("@q");
        Assert.Equal([wordLeft], replay.EditorKeys);
        Assert.Equal("one two", replay.Text);
    }

    [Fact]
    public void VisualModeEndsWhenTheSelectionMovesFromOutside()
    {
        var s = new VimSession("abcdef", caret: 0);
        s.Press("vl");
        Assert.Equal(VimMode.Visual, s.Mode);
        s.Model.Type("X");
        Assert.Equal(VimMode.Normal, s.Mode);
        Assert.Equal("Xcdef", s.Text);
        s.Press("l");
        Assert.Equal((2, 0), s.Selection);
    }

    // A line wrapped over rows 0 to 10 with rows 10 to 19 on screen: the middle row is 14, line 4.
    [Fact]
    public void MiddleReadsTheRowsOnScreenWhenTheFirstOneContinuesALine()
    {
        var text = new string('a', 86) + "\n" + string.Concat(Enumerable.Range(1, 12).Select(line => $"l{line}\n"));
        var s = new VimSession(text, caret: 0);
        s.Model.Rows.SetWrap(8, 4);
        Assert.Equal(0, s.Model.Rows.LineAtRow(10));
        Assert.Equal(1, s.Model.Rows.LineAtRow(11));
        s.Visible = (10, 19);
        s.Press("M");
        Assert.Equal(4, s.Model.Document.GetLineFromOffset(s.Caret));
    }
}
