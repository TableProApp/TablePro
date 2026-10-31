using TablePro.Core.Editing.MultiCursor;
using static TablePro.Core.Tests.MultiCursor.CaretMarkup;

namespace TablePro.Core.Tests.MultiCursor;

public sealed class MultiCursorCaretTests
{
    [Fact]
    public void AddCaretBelowKeepsTheColumnAndBecomesPrimary()
    {
        var (buffer, model) = Create("SEL|ECT a\nFROM b\nWHERE c");
        Assert.True(model.AddCaretBelow());
        Assert.True(model.AddCaretBelow());
        Assert.Equal("SEL|ECT a\nFRO|M b\nWHE|RE c", Render(buffer, model));
        Assert.Equal(2, model.PrimaryIndex);
        Assert.False(model.AddCaretBelow());
    }

    [Fact]
    public void AddCaretAboveStacksFromTheTopmostCaret()
    {
        var (buffer, model) = Create("one\ntwo\nthr|ee");
        Assert.True(model.AddCaretAbove());
        Assert.True(model.AddCaretAbove());
        Assert.Equal("one|\ntwo|\nthr|ee", Render(buffer, model));
        Assert.Equal(0, model.PrimaryIndex);
        Assert.False(model.AddCaretAbove());
    }

    [Fact]
    public void AddingCaretsPastAShortLineReturnsToTheColumn()
    {
        var (buffer, model) = Create("abcdef|\nab\nabcdefgh");
        model.AddCaretBelow();
        model.AddCaretBelow();
        Assert.Equal("abcdef|\nab|\nabcdef|gh", Render(buffer, model));
    }

    [Fact]
    public void ToggleCaretAddsThenRemoves()
    {
        var (buffer, model) = Create("|SELECT a FROM b");
        Assert.True(model.ToggleCaret(8));
        Assert.Equal("|SELECT a| FROM b", Render(buffer, model));
        Assert.Equal(1, model.PrimaryIndex);

        Assert.False(model.ToggleCaret(8));
        Assert.Equal("|SELECT a FROM b", Render(buffer, model));
        Assert.False(model.HasMultipleCarets);
    }

    [Fact]
    public void TheOnlyCaretIsNeverRemoved()
    {
        var (buffer, model) = Create("ab|c");
        model.ToggleCaret(2);
        Assert.Equal("ab|c", Render(buffer, model));
        Assert.Equal(1, model.Count);
    }

    [Fact]
    public void OverlappingSelectionsMerge()
    {
        var (buffer, model) = Create("abcdef");
        model.SetCarets([Caret.Over(0, 3), Caret.Over(2, 5)], 1);
        Assert.Equal("[abcde]f", Render(buffer, model));
        Assert.Equal(0, model.PrimaryIndex);
    }

    [Fact]
    public void ACaretAtASelectionsEdgeJoinsIt()
    {
        var (buffer, model) = Create("abcdef");
        model.SetCarets([Caret.Over(1, 3), Caret.At(3), Caret.At(1)], 0);
        Assert.Equal("a[bc]def", Render(buffer, model));
    }

    [Fact]
    public void SelectionsThatOnlyTouchStayApart()
    {
        var (buffer, model) = Create("aaaa");
        model.SetCarets([Caret.Over(0, 2), Caret.Over(2, 4)], 0);
        Assert.Equal("[aa][aa]", Render(buffer, model));
    }

    [Fact]
    public void DuplicateCaretsCollapseIntoOne()
    {
        var (_, model) = Create("abc");
        model.SetCarets([Caret.At(1), Caret.At(1), Caret.At(1)], 2);
        Assert.Equal(1, model.Count);
        Assert.Equal(0, model.PrimaryIndex);
    }

    [Fact]
    public void CollapseToPrimaryKeepsItsSelection()
    {
        var (buffer, model) = Create("[ab] [ab] [ab]", primary: 1);
        Assert.True(model.CollapseToPrimary());
        Assert.Equal("ab [ab] ab", Render(buffer, model));
        Assert.False(model.CollapseToPrimary());
    }

    [Fact]
    public void ResetWithTheSameCaretChangesNothing()
    {
        var (_, model) = Create("ab|c");
        var version = model.Version;
        model.Reset(2, 2);
        Assert.Equal(version, model.Version);
        model.Touch();
        Assert.Equal(version + 1, model.Version);
    }

    [Fact]
    public void CaretsPastTheEndOfShrunkTextAreClamped()
    {
        var (buffer, model) = Create("abcdef|");
        buffer.Text = "ab";
        model.Move(CaretMotion.Left, extend: false);
        Assert.Equal("a|b", Render(buffer, model));
    }

    [Fact]
    public void ChangedIsRaisedForEveryCaretChange()
    {
        var (_, model) = Create("a|bc");
        var raised = 0;
        model.Changed += (_, _) => raised++;
        model.AddCaretBelow();
        model.ToggleCaret(0);
        model.Reset(1, 1);
        Assert.Equal(2, raised);
    }

    [Fact]
    public void LineHelpersReadTheBuffer()
    {
        var (_, model) = Create("ab\ncde\n|f");
        Assert.Equal(2, model.LineOf(7));
        Assert.Equal((3, 6), model.LineSpan(1));
    }
}
