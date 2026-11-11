using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class TableEditsTests
{
    private static readonly IReadOnlyList<EditColumn> Columns =
    [
        Column("id", editable: false, CellEdit.ServerDefault.Instance, nullable: false, primaryKey: true),
        Column("name", editable: true, CellEdit.Null.Instance, nullable: false),
        Column("total", editable: false, CellEdit.ServerDefault.Instance, nullable: true),
    ];

    // A child row naming its parent by key: the order the save sends them in decides whether the key holds.
    private static readonly IReadOnlyList<EditColumn> Children =
    [
        Column("id", editable: false, CellEdit.ServerDefault.Instance, nullable: false, primaryKey: true),
        Column("name", editable: true, CellEdit.Null.Instance, nullable: true),
        Column("parent", editable: true, CellEdit.Null.Instance, nullable: true),
    ];

    [Fact]
    public void ACellEditedBackToItsStoredValueIsNoChange()
    {
        var edits = new TableEdits(Columns, dataRows: 3);

        edits.SetCell(1, 1, new CellEdit.Text("Grace Hopper"), stored: "Grace");
        var changed = edits.HasChanges;
        edits.SetCell(1, 1, new CellEdit.Text("Grace"), stored: "Grace");

        Assert.True(changed);
        Assert.False(edits.HasChanges);
        Assert.Null(edits.GetCell(1, 1));
    }

    [Fact]
    public void NullOnAStoredNullIsNoChangeAndOnAValueIsOne()
    {
        var edits = new TableEdits(Columns, dataRows: 2);

        edits.SetCell(0, 2, CellEdit.Null.Instance, stored: null);
        var onNull = edits.HasChanges;
        edits.SetCell(1, 2, CellEdit.Null.Instance, stored: "10");

        Assert.False(onNull);
        Assert.Equal(CellEdit.Null.Instance, edits.GetCell(1, 2));
    }

    [Fact]
    public void ANewRowStartsWithTheServersValuesAndFollowsTheDataRows()
    {
        var edits = new TableEdits(Columns, dataRows: 2);

        var row = edits.AddRow();
        edits.SetCell(row, 1, new CellEdit.Text("Edsger"), stored: null);

        Assert.Equal(2, row);
        Assert.True(edits.IsAdded(row));
        Assert.Equal(3, edits.RowCount);
        Assert.Equal(CellEdit.ServerDefault.Instance, edits.GetCell(row, 0));
        Assert.Equal(new CellEdit.Text("Edsger"), edits.GetCell(row, 1));
    }

    [Fact]
    public void ADuplicateCopiesValuesButStartsTheKeyAndComputedColumnsAsANewRow()
    {
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.SetCell(0, 1, new CellEdit.Text("Ada Lovelace"), stored: "Ada");

        var copy = edits.DuplicateRow(0, column => new CellEdit.Text("stored " + column));

        Assert.Equal(CellEdit.ServerDefault.Instance, edits.GetCell(copy, 0));
        Assert.Equal(new CellEdit.Text("Ada Lovelace"), edits.GetCell(copy, 1));
        Assert.Equal(CellEdit.ServerDefault.Instance, edits.GetCell(copy, 2));
    }

    [Fact]
    public void DeletingANewRowRemovesItAndADataRowIsMarkedWithoutItsEdits()
    {
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.SetCell(1, 1, new CellEdit.Text("changed"), stored: "Grace");
        var first = edits.AddRow();
        var second = edits.AddRow();
        edits.SetCell(second, 1, new CellEdit.Text("kept"), stored: null);

        edits.DeleteRows([1, first]);

        Assert.True(edits.IsDeleted(1));
        Assert.Null(edits.GetCell(1, 1));
        Assert.Equal(1, edits.AddedRows);
        Assert.Equal(new CellEdit.Text("kept"), edits.GetCell(2, 1));
    }

    [Fact]
    public void ARestoredRowIsNoLongerDeletedAndDiscardForgetsEverything()
    {
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.DeleteRows([0]);

        edits.RestoreRows([0]);
        var restored = edits.HasChanges;
        edits.AddRow();
        edits.Discard();

        Assert.False(restored);
        Assert.False(edits.HasChanges);
        Assert.Equal(2, edits.RowCount);
    }

    [Fact]
    public void TheRowEditsNameTheGridRowEachCameFromWithEachRowAtItsLatestChange()
    {
        var edits = new TableEdits(Columns, dataRows: 3);
        edits.SetCell(2, 1, new CellEdit.Text("third"), stored: "Linus");
        edits.DeleteRows([0]);
        var added = edits.AddRow();
        edits.SetCell(2, 1, new CellEdit.Text("third again"), stored: "Linus");

        var planned = edits.ToRowEdits();

        Assert.Equal(
            [
                new RowEdit.Delete(0),
                new RowEdit.Insert([CellEdit.ServerDefault.Instance, CellEdit.Null.Instance, CellEdit.ServerDefault.Instance]),
                new RowEdit.Update(2, [new CellChange(1, new CellEdit.Text("third again"))]),
            ],
            planned.Edits,
            RowEditComparer.Instance);
        Assert.Equal([0, added, 2], planned.Rows);
    }

    [Fact]
    public void ANewParentRowSavesBeforeTheChildPointedAtIt()
    {
        var edits = new TableEdits(Children, dataRows: 2);

        var parent = edits.AddRow();
        edits.SetCell(1, 2, new CellEdit.Text("new parent"), stored: "0");

        Assert.Equal(
            [
                new RowEdit.Insert([CellEdit.ServerDefault.Instance, CellEdit.Null.Instance, CellEdit.Null.Instance]),
                new RowEdit.Update(1, [new CellChange(2, new CellEdit.Text("new parent"))]),
            ],
            edits.ToRowEdits().Edits,
            RowEditComparer.Instance);
        Assert.Equal([parent, 1], edits.ToRowEdits().Rows);
    }

    [Fact]
    public void AChildEditedBeforeItsNewParentWasAddedSavesAfterThatParentOnceItPointsAtIt()
    {
        var edits = new TableEdits(Children, dataRows: 2);

        edits.SetCell(1, 1, new CellEdit.Text("renamed child"), stored: "child");
        edits.AddRow();
        edits.SetCell(1, 2, new CellEdit.Text("new parent"), stored: "0");

        Assert.Equal(
            [
                new RowEdit.Insert([CellEdit.ServerDefault.Instance, CellEdit.Null.Instance, CellEdit.Null.Instance]),
                new RowEdit.Update(
                    1,
                    [
                        new CellChange(1, new CellEdit.Text("renamed child")),
                        new CellChange(2, new CellEdit.Text("new parent")),
                    ]),
            ],
            edits.ToRowEdits().Edits,
            RowEditComparer.Instance);
    }

    [Fact]
    public void ChildrenPointedAwaySaveBeforeTheirParentIsDeleted()
    {
        var edits = new TableEdits(Children, dataRows: 3);

        edits.SetCell(1, 2, new CellEdit.Text("2"), stored: "0");
        edits.SetCell(2, 2, CellEdit.Null.Instance, stored: "0");
        edits.DeleteRows([0]);

        Assert.Equal(
            [
                new RowEdit.Update(1, [new CellChange(2, new CellEdit.Text("2"))]),
                new RowEdit.Update(2, [new CellChange(2, CellEdit.Null.Instance)]),
                new RowEdit.Delete(0),
            ],
            edits.ToRowEdits().Edits,
            RowEditComparer.Instance);
    }

    [Fact]
    public void ARowWhoseChangesAreUndoneLeavesTheOrderAndComesBackAtItsNextChange()
    {
        var edits = new TableEdits(Children, dataRows: 3);
        edits.SetCell(1, 2, new CellEdit.Text("changed"), stored: "0");
        edits.DeleteRows([2]);

        edits.SetCell(1, 2, new CellEdit.Text("0"), stored: "0");
        edits.RestoreRows([2]);
        edits.DeleteRows([2]);
        edits.SetCell(1, 2, new CellEdit.Text("later"), stored: "0");

        Assert.Equal([2, 1], edits.ToRowEdits().Rows);
    }

    [Fact]
    public void DeletingEveryRowOfALargePageTakesOnePass()
    {
        var edits = new TableEdits(Children, dataRows: 100_000);
        for (var row = 0; row < 100_000; row += 2)
        {
            edits.SetCell(row, 1, new CellEdit.Text("edited"), stored: "stored");
        }

        edits.DeleteRows(Enumerable.Range(0, 100_000));
        var planned = edits.ToRowEdits();

        Assert.Equal(100_000, planned.Edits.Count);
        Assert.All(planned.Edits, edit => Assert.IsType<RowEdit.Delete>(edit));
        Assert.Null(edits.GetCell(0, 1));
    }

    [Fact]
    public void TheSnapshotShowsEachChangeAndStaysTheSameUntilTheNext()
    {
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.SetCell(0, 1, new CellEdit.Text("Ada Lovelace"), stored: "Ada");
        edits.DeleteRows([1]);
        edits.AddRow();

        var snapshot = edits.Snapshot();

        Assert.Same(snapshot, edits.Snapshot());
        Assert.True(snapshot.IsModified(0));
        Assert.True(snapshot.TryGetCell(0, 1, out var cell));
        Assert.Equal(new PendingCell(PendingKind.Value, "Ada Lovelace"), cell);
        Assert.True(snapshot.IsDeleted(1));
        Assert.Equal(1, snapshot.AddedRows);
        Assert.Equal(PendingKind.Default, snapshot.GetAddedCell(0, 0).Kind);
        edits.AddRow();
        Assert.NotSame(snapshot, edits.Snapshot());
    }

    // A saved row edits where `editable` says; a new row takes a value wherever the server does not fill it.
    private static EditColumn Column(string name, bool editable, CellEdit newRow, bool nullable, bool primaryKey = false) =>
        new(
            name,
            editable,
            EditableInNewRow: newRow is not CellEdit.ServerDefault,
            newRow,
            nullable,
            primaryKey,
            TakesEmpty: editable,
            TakesDefault: false);

    // Records holding lists compare the lists by reference.
    private sealed class RowEditComparer : IEqualityComparer<RowEdit>
    {
        public static RowEditComparer Instance { get; } = new();

        public bool Equals(RowEdit? x, RowEdit? y) => (x, y) switch
        {
            (RowEdit.Update a, RowEdit.Update b) => a.Row == b.Row && a.Cells.SequenceEqual(b.Cells),
            (RowEdit.Insert a, RowEdit.Insert b) => a.Cells.SequenceEqual(b.Cells),
            _ => object.Equals(x, y),
        };

        public int GetHashCode(RowEdit obj) => 0;
    }
}
