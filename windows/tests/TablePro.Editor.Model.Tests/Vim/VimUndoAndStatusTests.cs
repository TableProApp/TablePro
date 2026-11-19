using TablePro.Editor.Model.Vim;

namespace TablePro.Editor.Model.Tests.Vim;

// What the Windows engine adds around the macOS one: Vim's undo steps over the model's history, the status the
// editor shows, registers shared by every editor and macros that type what Insert mode typed.
public sealed class VimUndoAndStatusTests
{
    [Fact]
    public void AChangeAndTheTextTypedAfterItUndoAsOneStep()
    {
        var s = new VimSession("select name from t\n", caret: 7);
        // cw takes the space after the word, as the macOS engine's does.
        s.Press("cw");
        s.Type("id, title ");
        s.Escape();
        Assert.Equal("select id, title from t\n", s.Text);
        s.Press("u");
        Assert.Equal("select name from t\n", s.Text);
        s.Press("\u0012");
        Assert.Equal("select id, title from t\n", s.Text);
    }

    [Fact]
    public void AnInsertOverSeveralLinesUndoesAsOneStep()
    {
        var s = new VimSession("a\n", caret: 0);
        s.Press("o");
        s.Type("one two");
        s.Key("\r");
        s.Model.NewLine();
        s.Type("three");
        s.Escape();
        Assert.Equal("a\none two\nthree\n", s.Text);
        s.Press("u");
        Assert.Equal("a\n", s.Text);
    }

    [Fact]
    public void MovingTheCaretInsideAnInsertSplitsItsUndoStep()
    {
        var s = new VimSession("x\n", caret: 0);
        s.Press("i");
        s.Type("ab");
        s.Engine.BreakInsertUndo();
        s.Type("c");
        s.Escape();
        Assert.Equal("abcx\n", s.Text);
        s.Press("u");
        Assert.Equal("abx\n", s.Text);
        s.Press("u");
        Assert.Equal("x\n", s.Text);
    }

    [Fact]
    public void ACountedCommandIsOneStep()
    {
        var s = new VimSession("1\n2\n3\n4\n", caret: 0);
        s.Press("3dd");
        Assert.Equal("4\n", s.Text);
        s.Press("u");
        Assert.Equal("1\n2\n3\n4\n", s.Text);
    }

    [Fact]
    public void AnUndoInsideTheInsertKeepsTheStepsApart()
    {
        var s = new VimSession("x\n", caret: 0);
        s.Press("i");
        s.Type("ab");
        s.Model.Undo();
        s.Type("c");
        s.Escape();
        Assert.Equal("cx\n", s.Text);
        s.Press("u");
        Assert.Equal("x\n", s.Text);
    }

    [Fact]
    public void AMacroTypesWhatItsInsertTyped()
    {
        var s = new VimSession("a\nb\n", caret: 0);
        s.Press("qq");
        s.Press("A");
        s.Type(";");
        s.Escape();
        s.Press("jq");
        s.Press("@q");
        Assert.Equal("a;\nb;\n", s.Text);
        s.Press("u");
        Assert.Equal("a;\nb\n", s.Text);
    }

    [Fact]
    public void PendingKeysShowWhileACommandIsTyped()
    {
        var s = new VimSession("one two\n");
        s.Press("2");
        Assert.Equal("2", s.Engine.PendingKeys);
        s.Press("\"a");
        Assert.Equal("2\"a", s.Engine.PendingKeys);
        s.Press("d");
        Assert.Equal("2\"ad", s.Engine.PendingKeys);
        Assert.True(s.Engine.IsPending);
        s.Press("w");
        Assert.Equal(string.Empty, s.Engine.PendingKeys);
        Assert.False(s.Engine.IsPending);
    }

    [Fact]
    public void EscapeClearsThePendingKeys()
    {
        var s = new VimSession("1\n");
        s.Press("3g");
        Assert.Equal("3g", s.Engine.PendingKeys);
        s.Escape();
        Assert.Equal(string.Empty, s.Engine.PendingKeys);
        Assert.False(s.Engine.IsPending);
    }

    [Fact]
    public void StatusChangesOnceForEachVisibleChange()
    {
        var s = new VimSession("abc\n");
        var changes = 0;
        s.Engine.StatusChanged += (_, _) => changes++;
        s.Press("l");
        Assert.Equal(0, changes);
        s.Press("i");
        Assert.Equal(1, changes);
        Assert.Equal("INSERT", s.Engine.ModeLabel);
        s.Escape();
        Assert.Equal(2, changes);
        s.Press(":w");
        Assert.Equal(VimMode.CommandLine, s.Mode);
        Assert.Equal(":w", s.Engine.ModeLabel);
        Assert.Equal(4, changes);
    }

    [Fact]
    public void RecordingShowsItsRegister()
    {
        var s = new VimSession("abc\n");
        s.Press("qa");
        Assert.Equal("a", s.Engine.RecordingRegister);
        s.Press("q");
        Assert.Null(s.Engine.RecordingRegister);
    }

    [Fact]
    public void RegistersAreSharedByEveryEditor()
    {
        var registers = new VimRegisters();
        var first = new VimSession("first line\n", registers: registers);
        var second = new VimSession("second\n", registers: registers);
        first.Press("yy");
        second.Press("p");
        Assert.Equal("second\nfirst line\n", second.Text);
        first.Press("qmxq");
        second.Press("@m");
        Assert.Equal("second\nirst line\n", second.Text);
    }

    [Fact]
    public void LinewisePasteOnALastLineWithNoBreakGoesBelowIt()
    {
        var s = new VimSession("one\ntwo", caret: 4);
        s.Press("yyp");
        Assert.Equal("one\ntwo\ntwo", s.Text);
        Assert.Equal(8, s.Caret);
    }

    [Fact]
    public void NewTextForgetsTheMarks()
    {
        var s = new VimSession("one\ntwo\n", caret: 4);
        s.Press("ma");
        s.Model.Document.SetText("three\nfour\n");
        s.Press("`a");
        Assert.Equal(0, s.Caret);
    }

    [Fact]
    public void TheBlockCaretSitsOnTheVisualCursor()
    {
        var s = new VimSession("abcdef\n", caret: 4);
        s.Press("vhh");
        Assert.Equal(2, s.Engine.CursorPosition);
        Assert.Equal((2, 3), s.Engine.CursorCharacter);
        Assert.Equal((2, 3), s.Selection);
        Assert.Equal(2, s.Model.Primary.Active);
    }

    [Fact]
    public void ClipboardTakesEveryYankAndDelete()
    {
        var s = new VimSession("abc\n");
        s.Press("x");
        s.Press("yy");
        Assert.Equal(["a", "bc\n"], s.Clipboard);
    }
}
