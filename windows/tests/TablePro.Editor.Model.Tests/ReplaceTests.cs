namespace TablePro.Editor.Model.Tests;

// What a format applies: the text it wrote in place of a range, as one undo step.
public sealed class ReplaceTests
{
    [Fact]
    public void AReplaceIsOneUndoStepThatLeavesTheGivenSelection()
    {
        var model = Carets.Model("select a,b from t|");
        model.Type(" ");
        const string Formatted = "select\n    a,\n    b\nfrom\n    t ";

        model.ReplaceRange(0, model.Document.Length, Formatted, Selection.Caret(Formatted.Length));

        Assert.Equal(Formatted + "|", Carets.Show(model));
        model.Undo();
        Assert.Equal("select a,b from t |", Carets.Show(model));
        model.Redo();
        Assert.Equal(Formatted + "|", Carets.Show(model));
    }

    [Fact]
    public void OnlyThePartThatDiffersIsReplaced()
    {
        var model = Carets.Model("-- keep\nselect a,b|\n-- keep");
        var changes = new List<TextChange>();
        model.Document.Changed += (_, change) => changes.Add(change);

        model.ReplaceRange(0, model.Document.Length, "-- keep\nselect a, b\n-- keep", Selection.Caret(19));

        var change = Assert.Single(changes);
        Assert.Equal((17, string.Empty, " "), (change.Offset, change.RemovedText, change.InsertedText));
        Assert.Equal("-- keep\nselect a, b|\n-- keep", Carets.Show(model));
    }

    [Fact]
    public void AReplacedSelectionLeavesTheCaretAfterItsText()
    {
        var model = Carets.Model("x; select a,b; y");
        model.SetSelection(3, 13);

        model.ReplaceRange(3, 13, "select\n    a,\n    b", Selection.Caret(22));

        Assert.Equal("x; select\n    a,\n    b|; y", Carets.Show(model));
    }

    [Fact]
    public void TheSameTextLeavesNoUndoStep()
    {
        var model = Carets.Model("select 1|");

        model.ReplaceRange(0, model.Document.Length, "select 1", Selection.Caret(3));

        Assert.False(model.Document.Undo.CanUndo);
        Assert.Equal("sel|ect 1", Carets.Show(model));
    }

    [Fact]
    public void ASurrogatePairIsNeverSplit()
    {
        var model = Carets.Model("'😀'|");
        var changes = new List<TextChange>();
        model.Document.Changed += (_, change) => changes.Add(change);

        model.ReplaceRange(0, model.Document.Length, "'😁'", Selection.Caret(4));

        var change = Assert.Single(changes);
        Assert.Equal(("😀", "😁"), (change.RemovedText, change.InsertedText));
    }
}
