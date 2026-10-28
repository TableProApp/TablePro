using static TablePro.Core.Tests.MultiCursor.CaretMarkup;

namespace TablePro.Core.Tests.MultiCursor;

public sealed class MultiCursorSelectionTests
{
    [Fact]
    public void NextOccurrenceFirstSelectsTheWordAtTheCaret()
    {
        var (buffer, model) = Create("SELECT i|d, idx, id FROM t WHERE id = 1");
        Assert.True(model.AddNextOccurrence());
        Assert.Equal("SELECT [id], idx, id FROM t WHERE id = 1", Render(buffer, model));
        Assert.Equal(1, model.Count);
    }

    [Fact]
    public void NextOccurrenceOfAWordMatchesWholeWordsOnly()
    {
        var (buffer, model) = Create("SELECT i|d, idx, id FROM t WHERE id = 1");
        model.AddNextOccurrence();
        model.AddNextOccurrence();
        model.AddNextOccurrence();
        Assert.Equal("SELECT [id], idx, [id] FROM t WHERE [id] = 1", Render(buffer, model));
        Assert.Equal(2, model.PrimaryIndex);
        Assert.False(model.AddNextOccurrence());
    }

    [Fact]
    public void NextOccurrenceOfASelectionMatchesAnywhere()
    {
        var (buffer, model) = Create("SELECT [id], idx, id");
        model.AddNextOccurrence();
        Assert.Equal("SELECT [id], [id]x, id", Render(buffer, model));
    }

    [Fact]
    public void NextOccurrenceWrapsToTheStart()
    {
        var (buffer, model) = Create("ab ab [ab]");
        model.AddNextOccurrence();
        Assert.Equal("[ab] ab [ab]", Render(buffer, model));
        Assert.Equal(0, model.PrimaryIndex);
        model.AddNextOccurrence();
        Assert.Equal("[ab] [ab] [ab]", Render(buffer, model));
    }

    [Fact]
    public void NextOccurrenceIsCaseSensitive()
    {
        var (buffer, model) = Create("[id] ID Id id");
        model.AddNextOccurrence();
        Assert.Equal("[id] ID Id [id]", Render(buffer, model));
    }

    [Fact]
    public void ACaretOutsideAnyWordFindsNothing()
    {
        var (_, model) = Create("a + | b");
        Assert.False(model.AddNextOccurrence());
        Assert.False(model.SelectAllOccurrences());
    }

    [Fact]
    public void SelectAllOccurrencesOfTheWordAtTheCaret()
    {
        var (buffer, model) = Create("id, idx, i|d, id");
        Assert.True(model.SelectAllOccurrences());
        Assert.Equal("[id], idx, [id], [id]", Render(buffer, model));
        Assert.Equal(1, model.PrimaryIndex);
    }

    [Fact]
    public void SelectAllOccurrencesOfASelection()
    {
        var (buffer, model) = Create("a.[b] a.bc");
        model.SelectAllOccurrences();
        Assert.Equal("a.[b] a.[b]c", Render(buffer, model));
    }

    [Fact]
    public void ColumnSelectionTakesTheSameColumnsOnEveryLine()
    {
        var (buffer, model) = Create("|alpha\nbeta\ngamma");
        model.SelectColumns(0, 1, 2, 3);
        Assert.Equal("a[lp]ha\nb[et]a\ng[am]ma", Render(buffer, model));
        Assert.Equal(2, model.PrimaryIndex);
    }

    [Fact]
    public void ColumnSelectionLeavesOutLinesThatEndBeforeIt()
    {
        var (buffer, model) = Create("|abcdef\nab\n\nabcdef");
        model.SelectColumns(0, 3, 3, 5);
        Assert.Equal("abc[de]f\nab\n\nabc[de]f", Render(buffer, model));
    }

    [Fact]
    public void ColumnSelectionStopsAtShortLineEnds()
    {
        var (buffer, model) = Create("|abcdef\nabcd\nabcdef");
        model.SelectColumns(0, 2, 2, 5);
        Assert.Equal("ab[cde]f\nab[cd]\nab[cde]f", Render(buffer, model));
    }

    [Fact]
    public void ColumnSelectionDraggedLeftAndUpIsReversed()
    {
        var (buffer, model) = Create("|abcd\nabcd");
        model.SelectColumns(1, 3, 0, 1);
        Assert.Equal("a{bc}d\na{bc}d", Render(buffer, model));
        Assert.Equal(0, model.PrimaryIndex);
    }

    [Fact]
    public void AZeroWidthColumnIsACaretOnEveryLine()
    {
        var (buffer, model) = Create("|ab\n\nabc");
        model.SelectColumns(0, 2, 2, 2);
        Assert.Equal("ab|\n|\nab|c", Render(buffer, model));
    }

    [Fact]
    public void ColumnLinesAreClampedToTheText()
    {
        var (buffer, model) = Create("|ab\ncd");
        model.SelectColumns(-3, 0, 9, 1);
        Assert.Equal("[a]b\n[c]d", Render(buffer, model));
    }
}
