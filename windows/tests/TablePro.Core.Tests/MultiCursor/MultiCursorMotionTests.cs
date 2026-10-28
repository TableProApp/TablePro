using TablePro.Core.Editing.MultiCursor;
using static TablePro.Core.Tests.MultiCursor.CaretMarkup;

namespace TablePro.Core.Tests.MultiCursor;

public sealed class MultiCursorMotionTests
{
    private static string After(string markup, CaretMotion motion, bool extend = false)
    {
        var (buffer, model) = Create(markup);
        model.Move(motion, extend);
        return Render(buffer, model);
    }

    [Fact]
    public void EveryCaretMovesByACharacter()
    {
        Assert.Equal("a|bc a|bc", After("ab|c ab|c", CaretMotion.Left));
        Assert.Equal("abc| abc|", After("ab|c ab|c", CaretMotion.Right));
    }

    [Fact]
    public void LeftAndRightOnASelectionLandOnItsEdge()
    {
        Assert.Equal("a|bcd", After("a[bc]d", CaretMotion.Left));
        Assert.Equal("abc|d", After("a[bc]d", CaretMotion.Right));
    }

    [Fact]
    public void ExtendingMovesTheActiveEndOnly()
    {
        Assert.Equal("a[bcd]", After("a[bc]d", CaretMotion.Right, extend: true));
        Assert.Equal("a[b]cd", After("a[bc]d", CaretMotion.Left, extend: true));
    }

    [Fact]
    public void ExtendingBackPastTheAnchorReverses()
    {
        var (buffer, model) = Create("ab|cd");
        model.Move(CaretMotion.Left, extend: true);
        model.Move(CaretMotion.Left, extend: true);
        Assert.Equal("{ab}cd", Render(buffer, model));
    }

    [Fact]
    public void UpAndDownKeepTheColumnAcrossShortLines()
    {
        var (buffer, model) = Create("abcdef|\nab\nabcdefgh");
        model.Move(CaretMotion.Down, extend: false);
        Assert.Equal("abcdef\nab|\nabcdefgh", Render(buffer, model));
        model.Move(CaretMotion.Down, extend: false);
        Assert.Equal("abcdef\nab\nabcdef|gh", Render(buffer, model));
    }

    [Fact]
    public void UpOnTheFirstLineGoesToTheStartAndDownOnTheLastToTheEnd()
    {
        Assert.Equal("|abc\nde", After("ab|c\nde", CaretMotion.Up));
        Assert.Equal("abc\nde|", After("abc\n|de", CaretMotion.Down));
    }

    [Fact]
    public void CaretsThatMeetMerge()
    {
        var (buffer, model) = Create("a|b|c");
        model.Move(CaretMotion.LineStart, extend: false);
        Assert.Equal("|abc", Render(buffer, model));
        Assert.Equal(1, model.Count);
    }

    [Fact]
    public void HomeGoesToTheFirstTextThenToColumnZero()
    {
        Assert.Equal("    |abc", After("    ab|c", CaretMotion.SmartLineStart));
        Assert.Equal("|    abc", After("    |abc", CaretMotion.SmartLineStart));
    }

    [Fact]
    public void EndAndDocumentMotions()
    {
        Assert.Equal("a|b\nc|d", After("|ab\n|cd", CaretMotion.Right));
        Assert.Equal("ab|\ncd|", After("|ab\n|cd", CaretMotion.LineEnd));
        Assert.Equal("ab\ncd|", After("|ab\n|cd", CaretMotion.DocumentEnd));
        Assert.Equal("|ab\ncd", After("a|b\nc|d", CaretMotion.DocumentStart));
    }

    [Fact]
    public void WordMotions()
    {
        Assert.Equal("SELECT |id FROM t", After("SELECT id| FROM t", CaretMotion.WordLeft));
        Assert.Equal("SELECT id |FROM t", After("SELECT |id FROM t", CaretMotion.WordRight));
        Assert.Equal("SELECT id| FROM t", After("SELECT |id FROM t", CaretMotion.WordEnd));
        Assert.Equal("SELECT| id FROM t", After("|SELECT id FROM t", CaretMotion.WordEnd));
        Assert.Equal("a.b(|c)", After("a.b|(c)", CaretMotion.WordRight));
    }

    [Fact]
    public void WordLeftCrossesLineBreaks()
    {
        Assert.Equal("one |two\nthree", After("one two\n|three", CaretMotion.WordLeft));
    }
}
