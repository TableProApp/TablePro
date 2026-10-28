using TablePro.Core.Editing.MultiCursor;
using static TablePro.Core.Tests.MultiCursor.CaretMarkup;

namespace TablePro.Core.Tests.MultiCursor;

public sealed class MultiCursorEditingTests
{
    [Fact]
    public void TypingInsertsAtEveryCaretAsOneUndoStep()
    {
        var (buffer, model) = Create("SELECT |a, |b, |c");
        model.Type("t.");
        Assert.Equal("SELECT t.|a, t.|b, t.|c", Render(buffer, model));
        Assert.Single(buffer.UndoSteps);
        Assert.Equal(MultiCursorEditKind.Typing, buffer.Kinds[0]);

        buffer.Undo();
        Assert.Equal("SELECT a, b, c", buffer.Text);
    }

    [Fact]
    public void TypingReplacesEverySelection()
    {
        var (buffer, model) = Create("[id], [id], [id]");
        model.Type("key");
        Assert.Equal("key|, key|, key|", Render(buffer, model));
    }

    [Fact]
    public void ThePrimaryStaysWithItsCaretThroughAnEdit()
    {
        var (_, model) = Create("|a |b |c", primary: 1);
        model.Type("xx");
        Assert.Equal(1, model.PrimaryIndex);
        Assert.Equal(Caret.At(6), model.Primary);
    }

    [Fact]
    public void BackspaceDeletesBeforeEachCaretOrEachSelection()
    {
        var (buffer, model) = Create("ab|c a[bc] a|bc");
        model.Backspace();
        Assert.Equal("a|c a| |bc", Render(buffer, model));
        Assert.Single(buffer.UndoSteps);
    }

    [Fact]
    public void DeleteRemovesAfterEachCaret()
    {
        var (buffer, model) = Create("|abc |abc abc|");
        model.Delete();
        Assert.Equal("|bc |bc abc|", Render(buffer, model));
    }

    [Fact]
    public void WordDeletionsThatMeetJoinIntoOneEdit()
    {
        var (buffer, model) = Create("one two| three|");
        model.Backspace(word: true);
        Assert.Equal("one | |", Render(buffer, model));
        model.Backspace(word: true);
        Assert.Equal("|", Render(buffer, model));
        Assert.Equal(MultiCursorEditKind.Command, buffer.Kinds[^1]);
    }

    [Fact]
    public void BackspaceAtTheStartIsNotAnUndoStep()
    {
        var (buffer, model) = Create("|abc");
        model.Backspace();
        Assert.Empty(buffer.UndoSteps);
        Assert.Equal("|abc", Render(buffer, model));
    }

    [Fact]
    public void ASurrogatePairIsOneCharacter()
    {
        var (buffer, model) = Create("a\U0001F600|b");
        model.Backspace();
        Assert.Equal("a|b", Render(buffer, model));
    }

    [Fact]
    public void LineBreakKeepsEachCaretsIndentation()
    {
        var (buffer, model) = Create("  a|\n    b|");
        model.InsertLineBreak("    ");
        Assert.Equal("  a\n  |\n    b\n    |", Render(buffer, model));
    }

    [Fact]
    public void LineBreakIndentsAfterAnOpeningBlock()
    {
        var (buffer, model) = Create("f(|\ng(|");
        model.InsertLineBreak("  ", before => before.EndsWith('('));
        Assert.Equal("f(\n  |\ng(\n  |", Render(buffer, model));
    }

    [Fact]
    public void PasteWithOneLinePerCaretSpreadsTheLines()
    {
        var (buffer, model) = Create("|, |, |");
        model.Paste("a\nb\nc\n");
        Assert.Equal("a|, b|, c|", Render(buffer, model));
        Assert.Equal(MultiCursorEditKind.Command, buffer.Kinds[0]);
    }

    [Fact]
    public void PasteWithOtherLineCountsGoesWholeToEveryCaret()
    {
        var (buffer, model) = Create("|-|");
        model.Paste("x\ny\nz");
        Assert.Equal("x\ny\nz|-x\ny\nz|", Render(buffer, model));
    }

    [Fact]
    public void CopyJoinsTheSelections()
    {
        var (_, model) = Create("[one] two [three] |four");
        Assert.Equal("one\nthree", model.Copy());
    }

    [Fact]
    public void CopyWithBareCaretsTakesEachLineOnce()
    {
        var (_, model) = Create("o|n|e\ntwo\nth|ree");
        Assert.Equal("one\nthree", model.Copy());
    }

    [Fact]
    public void CutRemovesTheSelectionsAsOneStep()
    {
        var (buffer, model) = Create("[a]b[c]d");
        Assert.Equal("a\nc", model.Cut());
        Assert.Equal("|b|d", Render(buffer, model));
        Assert.Single(buffer.UndoSteps);
    }

    [Fact]
    public void CutWithBareCaretsRemovesTheirLines()
    {
        var (buffer, model) = Create("o|ne\ntwo\nthr|ee");
        Assert.Equal("one\nthree", model.Cut());
        Assert.Equal("|two|", Render(buffer, model));
    }

    [Fact]
    public void CopyThenPasteAtTheSameCaretsPutsEachPieceBack()
    {
        var (buffer, model) = Create("[a1] [b2] [c3]");
        var copied = model.Copy();
        model.Type(string.Empty);
        model.Paste(copied);
        Assert.Equal("a1| b2| c3|", Render(buffer, model));
    }

    [Fact]
    public void InsertSelectsThePiecesWhenAsked()
    {
        var (buffer, model) = Create("|x|");
        var inserted = model.Insert(["ab", "cd"], select: true);
        Assert.Equal("[ab]x[cd]", Render(buffer, model));
        Assert.Equal(new (int, int)[] { (0, 2), (3, 2) }, inserted);
    }

    [Fact]
    public void AnEditAnInputMethodMadeAtThePrimaryRepeatsAtTheOthers()
    {
        // A dead key typed 'e' then turned it into 'é': the edit replaces one character before the caret.
        var (buffer, model) = Create("e| e| e|");
        Assert.True(model.CanReplaceBeforeCarets("e"));
        Assert.False(model.CanReplaceBeforeCarets("x"));
        model.ReplaceAroundCarets(1, "é");
        Assert.Equal("é| é| é|", Render(buffer, model));
        Assert.Single(buffer.UndoSteps);
    }

    [Fact]
    public void TheBufferSeesSortedEditsInOriginalOffsets()
    {
        var (buffer, model) = Create("|a\n|b\n|c");
        model.Type(">");
        Assert.Equal(">a\n>b\n>c", buffer.Text);
    }

    [Fact]
    public void DeleteSelectionsLeavesBareCaretsAlone()
    {
        var (buffer, model) = Create("[ab]c|d");
        Assert.Equal("ab,", string.Join(',', model.DeleteSelections()));
        Assert.Equal("|c|d", Render(buffer, model));
    }

    [Fact]
    public void KillToLineEndTakesTheBreakAtTheEnd()
    {
        var (buffer, model) = Create("ab|c\nde|\nf");
        Assert.Equal("c,\n", string.Join(',', model.KillToLineEnd()));
        Assert.Equal("ab|\nde|f", Render(buffer, model));
    }
}
