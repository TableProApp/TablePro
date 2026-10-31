using TablePro.Core.Vim;

namespace TablePro.Core.Tests.Vim;

/// <summary>Behaviour the Windows engine adds to the macOS one: undo groups, the status line, and fuller dot repeat.</summary>
public sealed class VimEngineWindowsBehaviorTests
{
    [Fact]
    public void EveryKeyClosesItsUndoGroupOutsideInsertMode()
    {
        var h = new VimHarness("one two three\n");

        h.Keys("dwx");

        Assert.Equal(0, h.Buffer.UndoGroupDepth);
        Assert.Equal(3, h.Buffer.ClosedUndoGroups);
    }

    [Fact]
    public void AChangeAndItsTypingStayOneUndoGroupUntilEscape()
    {
        var h = new VimHarness("one two\n");

        h.Keys("cw");
        Assert.Equal(VimMode.Insert, h.Mode);
        Assert.Equal(1, h.Buffer.UndoGroupDepth);

        // Typing in insert mode passes through to the editor inside the open group.
        Assert.False(h.Key('x'));
        Assert.Equal(1, h.Buffer.UndoGroupDepth);

        // The c key closes a group of its own with no edit in it; w opens the one that spans the change.
        h.Key('\u001B');
        Assert.Equal(0, h.Buffer.UndoGroupDepth);
        Assert.Equal(2, h.Buffer.ClosedUndoGroups);
    }

    [Fact]
    public void OperatorsWorkWithCharacterMotions()
    {
        var h = new VimHarness("abcd\n", 3);

        h.Keys("dl");
        Assert.Equal("abc\n", h.Text);

        h.Keys("0ylP");
        Assert.Equal("aabc\n", h.Text);

        h.Keys("$dh");
        Assert.Equal("aac\n", h.Text);
    }

    [Fact]
    public void ResetClosesAnOpenInsertGroup()
    {
        var h = new VimHarness("one\n");
        h.Keys("i");

        h.Engine.Reset();

        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(0, h.Buffer.UndoGroupDepth);
    }

    [Fact]
    public void StatusShowsModeAndPendingKeys()
    {
        var h = new VimHarness("one two\n");
        var changes = 0;
        h.Engine.StatusChanged += (_, _) => changes++;

        h.Keys("2d");
        Assert.Equal("NORMAL  2d", h.Engine.Status);
        Assert.Equal("2d", h.Engine.PendingKeys);

        h.Keys("w");
        Assert.Equal("NORMAL", h.Engine.Status);
        Assert.Equal(string.Empty, h.Engine.PendingKeys);
        Assert.Equal(3, changes);
    }

    [Fact]
    public void StatusShowsInsertVisualAndCommandLine()
    {
        var h = new VimHarness("one\n");

        h.Keys("i");
        Assert.Equal("INSERT", h.Engine.Status);
        h.Keys("\u001BV");
        Assert.Equal("VISUAL LINE", h.Engine.Status);
        h.Keys("\u001B:w");
        Assert.Equal(":w", h.Engine.Status);
    }

    [Fact]
    public void StatusShowsMacroRecording()
    {
        var h = new VimHarness("one\n");

        h.Keys("qa");

        Assert.Equal('a', h.Engine.RecordingMacro);
        Assert.Equal("NORMAL  recording @a", h.Engine.Status);
        h.Keys("q");
        Assert.Equal("NORMAL", h.Engine.Status);
    }

    [Fact]
    public void PendingControlKeysShowWithACaret()
    {
        var h = new VimHarness("one\n");

        h.Keys("\"a");

        Assert.Equal("\"a", h.Engine.PendingKeys);
        h.Keys("\u001B");
        Assert.Equal(string.Empty, h.Engine.PendingKeys);
    }

    [Fact]
    public void DotRepeatsAChangeWithItsTypedText()
    {
        var h = new VimHarness("one two three\n");
        h.Keys("ce");

        // The editor types insert-mode text; the fake stands in for it.
        h.Buffer.Replace(h.Pos, 0, "ONE");
        h.Keys("\u001Bw.");

        Assert.Equal("ONE ONE three\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
        Assert.Equal(6, h.Pos);
    }

    [Fact]
    public void DotRepeatsDeleteLine()
    {
        var h = new VimHarness("a\nb\nc\nd\n");

        h.Keys("dd.");

        Assert.Equal("c\nd\n", h.Text);
    }

    [Fact]
    public void DotRepeatsDeleteToLineEndMotion()
    {
        var h = new VimHarness("abc def\nghi jkl\n", 4);

        h.Keys("d$j.");

        Assert.Equal("abc \nghi \n", h.Text);
    }

    [Fact]
    public void DotRepeatsReplaceChar()
    {
        var h = new VimHarness("abcd\n");

        h.Keys("rxl.");

        Assert.Equal("xxcd\n", h.Text);
    }

    [Fact]
    public void DotRepeatsJoin()
    {
        var h = new VimHarness("a\nb\nc\n");

        h.Keys("J.");

        Assert.Equal("a b c\n", h.Text);
    }

    [Fact]
    public void YankIsNotRepeatedByDot()
    {
        var h = new VimHarness("one two\n");
        h.Keys("xyw");

        h.Keys(".");

        Assert.Equal("e two\n", h.Text);
    }

    [Fact]
    public void ReplayedMacroTypesInsertModeKeys()
    {
        var h = new VimHarness("a\nb\n");
        h.Keys("qaI-");
        h.Buffer.Replace(h.Pos, 0, "-");
        h.Keys("\u001Bjq");

        h.Keys("@a");

        Assert.Equal("-a\n-b\n", h.Text);
    }

    [Fact]
    public void CommaDoesNotFlipTheDirectionSemicolonRepeats()
    {
        var h = new VimHarness("xoxoxoxo\n");

        h.Keys("fofo,;");

        Assert.Equal(3, h.Pos);
    }

    [Fact]
    public void SearchNextAfterStarMatchesWholeWords()
    {
        var h = new VimHarness("id idx id\n");

        h.Keys("*");

        Assert.Equal(7, h.Pos);
        h.Keys("n");
        Assert.Equal(0, h.Pos);
    }

    [Fact]
    public void FailedFindCancelsThePendingOperator()
    {
        var h = new VimHarness("abc\n");

        h.Keys("dfz");

        Assert.Null(h.Engine.PendingOperator);
        Assert.Equal("abc\n", h.Text);
    }

    [Fact]
    public void LinewisePasteBelowALastLineWithoutNewline()
    {
        var h = new VimHarness("one\ntwo", 4);

        h.Keys("kyyjp");

        Assert.Equal("one\ntwo\none", h.Text);
        Assert.Equal(8, h.Pos);
    }

    [Fact]
    public void CountedPasteFromANamedRegisterUsesItEveryTime()
    {
        var h = new VimHarness("ab\n");
        h.Keys("\"ayl");
        h.Keys("x");

        h.Keys("\"a2P");

        Assert.Equal("aab\n", h.Text);
    }

    [Fact]
    public void VisualIndentShiftsTheSelectedLines()
    {
        var h = new VimHarness("a\nb\nc\n");

        h.Keys("Vj>");

        Assert.Equal("    a\n    b\nc\n", h.Text);
        Assert.Equal(VimMode.Normal, h.Mode);
    }

    [Fact]
    public void VisualDeleteLeavesTheCaretOnACharacter()
    {
        var h = new VimHarness("abc\n", 2);

        h.Keys("vd");

        Assert.Equal("ab\n", h.Text);
        Assert.Equal(1, h.Pos);
    }

    [Fact]
    public void YankRaisesRegisterWritten()
    {
        var h = new VimHarness("one\n");
        VimRegister? written = null;
        h.Engine.RegisterWritten += (_, r) => written = r;

        h.Keys("yy");

        Assert.Equal(new VimRegister("one\n", true), written);
    }

    [Fact]
    public void CursorOffsetFollowsTheVisualCursorEnd()
    {
        var h = new VimHarness("hello\n");

        h.Keys("vll");

        Assert.Equal(2, h.Engine.CursorOffset);
        Assert.Equal((0, 3), (h.Buffer.SelectionStart, h.Buffer.SelectionLength));
    }
}
