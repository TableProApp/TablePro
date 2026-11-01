using TablePro.Core.Editing;
using TablePro.Core.Results;

namespace TablePro.Core.Tests.Editing;

public sealed class TableEditBufferTests
{
    private static ResultSet People() => new(
        [new ResultColumn("id", "integer", typeof(int)), new ResultColumn("name", "text", typeof(string)), new ResultColumn("age", "integer", typeof(int))],
        [[1, "Ana", 30], [2, "Binh", null], [3, "Chen", 41]]);

    [Fact]
    public void EditedCellsShowTheNewValueAndBuildOneKeyedUpdate()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);

        buffer.SetValue(1, 2, 25);
        buffer.SetValue(1, 1, "Binh N.");

        Assert.Equal(25, buffer.GetValue(1, 2));
        Assert.Equal(RowEditState.Modified, buffer.GetRowState(1));
        Assert.True(buffer.IsCellModified(1, 1));
        var update = Assert.IsType<RowUpdate>(Assert.Single(buffer.BuildChanges()));
        Assert.Equal(new Dictionary<string, object?> { ["id"] = 2 }, update.Key);
        Assert.Equal(new Dictionary<string, object?> { ["age"] = 25, ["name"] = "Binh N." }, update.Values);
    }

    [Fact]
    public void SettingACellBackToItsOriginalValueDropsTheEdit()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);

        buffer.SetValue(0, 1, "Anna");
        buffer.SetValue(0, 1, "Ana");

        Assert.False(buffer.HasChanges);
        Assert.Equal(RowEditState.Unchanged, buffer.GetRowState(0));
    }

    [Fact]
    public void ChangesRunDeletesThenUpdatesThenInserts()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);

        var inserted = buffer.InsertRow();
        buffer.SetValue(inserted, 1, "Dara");
        buffer.SetValue(0, 2, 31);
        buffer.ToggleDelete([2]);

        var changes = buffer.BuildChanges();

        Assert.Collection(
            changes,
            c => Assert.Equal(new Dictionary<string, object?> { ["id"] = 3 }, Assert.IsType<RowDelete>(c).Key),
            c => Assert.IsType<RowUpdate>(c),
            c => Assert.Equal(new Dictionary<string, object?> { ["name"] = "Dara" }, Assert.IsType<RowInsert>(c).Values));
    }

    [Fact]
    public void AnUpdateOnADeletedRowIsNotSent()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);

        buffer.SetValue(0, 1, "Anna");
        buffer.ToggleDelete([0]);

        Assert.IsType<RowDelete>(Assert.Single(buffer.BuildChanges()));
    }

    [Fact]
    public void UndoAndRedoReplayEveryKindOfEdit()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);
        buffer.SetValue(0, 1, "Anna");
        buffer.InsertRow();
        buffer.ToggleDelete([1]);
        Assert.Equal(3, buffer.ChangeCount);

        buffer.Undo();
        buffer.Undo();
        buffer.Undo();

        Assert.False(buffer.HasChanges);
        Assert.Equal(3, buffer.RowCount);
        Assert.Equal("Ana", buffer.GetValue(0, 1));

        buffer.Redo();
        buffer.Redo();
        buffer.Redo();

        Assert.Equal(3, buffer.ChangeCount);
        Assert.Equal(4, buffer.RowCount);
        Assert.Equal(RowEditState.Deleted, buffer.GetRowState(1));
    }

    [Fact]
    public void DeletingAnInsertedRowRemovesItInsteadOfMarkingIt()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);
        var row = buffer.InsertRow();

        buffer.ToggleDelete([row]);

        Assert.Equal(3, buffer.RowCount);
        Assert.False(buffer.HasChanges);
    }

    [Fact]
    public void DuplicateLeavesTheKeyEmptySoTheDatabaseAssignsIt()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);

        var copy = buffer.DuplicateRow(2);

        Assert.Null(buffer.GetValue(copy, 0));
        Assert.Equal("Chen", buffer.GetValue(copy, 1));
        Assert.Equal(new Dictionary<string, object?> { ["name"] = "Chen", ["age"] = 41 }, Assert.IsType<RowInsert>(Assert.Single(buffer.BuildChanges())).Values);
    }

    [Fact]
    public void WithoutAPrimaryKeyEveryColumnIdentifiesTheRow()
    {
        var buffer = new TableEditBuffer(People(), []);

        buffer.SetValue(1, 1, "B");

        Assert.False(buffer.HasPrimaryKey);
        var update = Assert.IsType<RowUpdate>(Assert.Single(buffer.BuildChanges()));
        Assert.Equal(new Dictionary<string, object?> { ["id"] = 2, ["name"] = "Binh", ["age"] = null }, update.Key);
    }

    [Fact]
    public void DiscardClearsEditsAndHistory()
    {
        var buffer = new TableEditBuffer(People(), ["id"]);
        buffer.SetValue(0, 1, "Anna");

        buffer.Discard();

        Assert.False(buffer.HasChanges);
        Assert.False(buffer.CanUndo);
        Assert.False(buffer.CanRedo);
    }
}
