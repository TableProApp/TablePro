using TablePro.DataGrid.Model;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class SessionRecoveryTests : IDisposable
{
    private static readonly IReadOnlyList<EditColumn> Columns =
    [
        Column("id", editable: false, CellEdit.ServerDefault.Instance, nullable: false, primaryKey: true),
        Column("name", editable: true, CellEdit.Null.Instance, nullable: true),
        Column("note", editable: true, CellEdit.Null.Instance, nullable: true),
    ];

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-recovery-").FullName;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public void PendingEditsComeBackFromTheSessionFileByKeyAndColumnName()
    {
        var store = new SessionStore(Path.Combine(_directory, "session.json"));
        var saved = SavedEdits.From(Edited(), Page("10", "20", "30"));

        store.Save(WithTab(new SessionTab { Kind = TabKind.Table, Title = "people", Table = "people", Edits = saved }));
        var loaded = Assert.Single(store.Load().Connections).Tabs[0].Edits;

        Assert.NotNull(loaded);
        Assert.Equal(4, loaded.Rows.Count);
        var (named, cleared, deleted, added) = (loaded.Rows[0], loaded.Rows[1], loaded.Rows[2], loaded.Rows[3]);
        Assert.Equal(Id("20"), Assert.Single(named.Key!).Value);
        Assert.Equal(new SavedCell { Kind = "Text", Text = "Grace Hopper" }, named.Cells["name"]);
        Assert.Equal(new SavedCell { Kind = "Null" }, cleared.Cells["note"]);
        Assert.Equal(Id("10"), cleared.Key!["id"]);
        Assert.True(deleted.Deleted);
        Assert.Equal(Id("30"), deleted.Key!["id"]);
        Assert.Null(added.Key);
        Assert.Equal(new SavedCell { Kind = "ServerDefault" }, added.Cells["id"]);
        Assert.Equal(new SavedCell { Kind = "Text", Text = "Ada" }, added.Cells["name"]);
        Assert.Equal(4, loaded.Changes);
        Assert.All(loaded.Rows, row => Assert.False(row.Uncertain));
        Assert.DoesNotContain("\"uncertain\"", File.ReadAllText(store.Path), StringComparison.Ordinal);
    }

    [Fact]
    public void ATabWithNothingPendingWritesNoneOfIt()
    {
        var path = Path.Combine(_directory, "session.json");

        var tab = new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "SELECT 1" };
        new SessionStore(path).Save(WithTab(tab));
        var text = File.ReadAllText(path);

        Assert.DoesNotContain("\"edits\"", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\"heldTransaction\"", text, StringComparison.Ordinal);
        Assert.DoesNotContain("\"hasRecoveredWork\"", text, StringComparison.Ordinal);
    }

    [Fact]
    public void RowsAreFoundByTheirKeyAfterThePageReordersThem()
    {
        var saved = SavedEdits.From(Edited(), Page("10", "20", "30"))!;
        var edits = new TableEdits(Columns, dataRows: 3);

        var (restored, _, waiting) = saved.RestoreTo(edits, Page("30", "10", "20"), Typed(edits));

        Assert.Equal(4, restored);
        Assert.Null(waiting);
        Assert.Equal(new CellEdit.Text("Grace Hopper"), edits.GetCell(2, 1));
        Assert.Equal(CellEdit.Null.Instance, edits.GetCell(1, 2));
        Assert.True(edits.IsDeleted(0));
        Assert.Equal(4, edits.RowCount);
        Assert.Equal(new CellEdit.Text("Ada"), edits.GetCell(3, 1));
        // Each row at its latest change, as the save before the end would have sent them.
        Assert.Equal<int>([2, 1, 0, 3], edits.ToRowEdits().Rows);
    }

    [Fact]
    public void KeysThatReadAlikeAreToldApartByTheirKind()
    {
        var bytes = new StoredValue(ValueKind.Bytes, "0x01");
        var text = new StoredValue(ValueKind.Text, "0x01");
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.SetCell(1, 1, new CellEdit.Text("the blob's row"), stored: "a");
        var saved = SavedEdits.From(edits, Keys(text, bytes))!;
        Assert.Equal(new SavedKeyPart { Kind = "Bytes", Text = "0x01" }, saved.Rows[0].Key!["id"]);

        var restoring = new TableEdits(Columns, dataRows: 2);
        var (restored, _, waiting) = saved.RestoreTo(restoring, Keys(bytes, text), Typed(restoring));

        Assert.Equal(1, restored);
        Assert.Null(waiting);
        Assert.Equal(new CellEdit.Text("the blob's row"), restoring.GetCell(0, 1));
        Assert.Null(restoring.GetCell(1, 1));
    }

    [Fact]
    public void AKeyTwoRowsOfThePageShareFindsNeitherAndTheChangeWaits()
    {
        var saved = new SavedEdits
        {
            Rows = [Update("10", ("name", Text("x"))), new SavedRowEdit { Key = Key("10"), Deleted = true }],
        };
        var edits = new TableEdits(Columns, dataRows: 3);

        var (restored, _, waiting) = saved.RestoreTo(edits, Page("10", "20", "10"), Typed(edits));

        Assert.Equal(0, restored);
        Assert.False(edits.HasChanges);
        Assert.Equal(2, waiting!.Rows.Count);
    }

    [Fact]
    public void ANullKeyMatchesANullKeyWhateverKindItsColumnGaveIt()
    {
        var key = new Dictionary<string, SavedKeyPart> { ["id"] = new() { Kind = "Text" } };
        var saved = new SavedEdits { Rows = [new SavedRowEdit { Key = key, Cells = Cells(("name", Text("x"))) }] };
        var edits = new TableEdits(Columns, dataRows: 2);
        var page = Keys(Integer("1"), new StoredValue(ValueKind.Integer, null));

        var (restored, _, _) = saved.RestoreTo(edits, page, Typed(edits));

        Assert.Equal(1, restored);
        Assert.Equal(new CellEdit.Text("x"), edits.GetCell(1, 1));
    }

    [Fact]
    public void ChangesThisPageCannotTakeWaitWithTheirKeys()
    {
        var saved = new SavedEdits
        {
            Rows =
            [
                Update("20", ("name", Text("Grace Hopper")), ("note", Text("left"))),
                Update("10", ("gone", Text("x")), ("name", Text("Alan")), ("note", new SavedCell { Kind = "Later" })),
                new SavedRowEdit { Key = Key("40"), Deleted = true },
                new SavedRowEdit
                {
                    Key = new Dictionary<string, SavedKeyPart> { ["other"] = Id("10") },
                    Cells = Cells(("name", Text("y"))),
                },
            ],
        };
        var edits = new TableEdits(Columns, dataRows: 2);

        var (restored, _, waiting) = saved.RestoreTo(edits, Page("10", "30"), Typed(edits));

        Assert.Equal(1, restored);
        Assert.Equal(new CellEdit.Text("Alan"), edits.GetCell(0, 1));
        Assert.Null(edits.GetCell(1, 1));
        Assert.False(edits.IsDeleted(1));
        // Row 20 whole, row 10's gone column and unknown kind, row 40's delete, and a key of other columns.
        Assert.NotNull(waiting);
        Assert.Equal(2 + 2 + 1 + 1, waiting.Changes);
        Assert.Same(saved.Rows[0], waiting.Rows[0]);
        Assert.Equal<string>(["gone", "note"], waiting.Rows[1].Cells.Keys);
        Assert.Equal(Id("10"), waiting.Rows[1].Key!["id"]);
        Assert.Same(saved.Rows[2], waiting.Rows[2]);
        Assert.Same(saved.Rows[3], waiting.Rows[3]);
    }

    [Fact]
    public void ACellTheTableRefusesNowWaitsAndANewRowWaitsWhole()
    {
        var saved = SavedEdits.From(Edited(), Page("10", "20", "30"))!;
        var edits = new TableEdits(Columns, dataRows: 3);

        var (restored, _, waiting) = saved.RestoreTo(edits, Page("10", "20", "30"), (row, column, edit) =>
            column != 1 && Typed(edits)(row, column, edit));

        // The note's NULL and the delete went back; the edited name and the new row, whose name is refused, wait.
        Assert.Equal(2, restored);
        Assert.Null(edits.GetCell(1, 1));
        Assert.Equal(CellEdit.Null.Instance, edits.GetCell(0, 2));
        Assert.Equal(3, edits.RowCount);
        Assert.NotNull(waiting);
        Assert.Equal<string?>(["20", null], waiting.Rows.Select(row => row.Key?["id"].Text));
        Assert.Equal<string>(["name"], waiting.Rows[0].Cells.Keys);
        Assert.Same(saved.Rows[3], waiting.Rows[1]);
    }

    [Fact]
    public void WaitingChangesGoFirstThenThePendingOnes()
    {
        var waiting = new SavedEdits { Rows = [Update("40", ("name", Text("w")))] };
        var pending = new SavedEdits { Rows = [Update("10", ("name", Text("p")))] };

        var joined = SavedEdits.Join(waiting, pending);

        Assert.Equal<string?>(["40", "10"], joined!.Rows.Select(row => row.Key!["id"].Text));
        Assert.Same(waiting, SavedEdits.Join(waiting, null));
        Assert.Same(pending, SavedEdits.Join(null, pending));
        Assert.Null(SavedEdits.Join(null, null));
    }

    [Fact]
    public void ATableThatLostItsKeyLeavesKeyedChangesWaiting()
    {
        IReadOnlyList<EditColumn> keyless =
        [
            Column("id", editable: true, CellEdit.Null.Instance, nullable: false),
            Column("name", editable: true, CellEdit.Null.Instance, nullable: true),
        ];
        var saved = new SavedEdits { Rows = [Update("10", ("name", Text("x")))] };
        var edits = new TableEdits(keyless, dataRows: 2);

        var (restored, _, waiting) = saved.RestoreTo(edits, Page("10", "20"), Typed(edits));

        Assert.Equal(0, restored);
        Assert.Same(saved.Rows[0], Assert.Single(waiting!.Rows));
    }

    [Fact]
    public void ATableWithoutAKeyKeepsNothing()
    {
        IReadOnlyList<EditColumn> keyless =
        [
            Column("name", editable: true, CellEdit.Null.Instance, nullable: true),
            Column("note", editable: true, CellEdit.Null.Instance, nullable: true),
        ];
        var edits = new TableEdits(keyless, dataRows: 2);
        edits.SetCell(0, 0, new CellEdit.Text("x"), stored: "a");
        edits.AddRow();

        Assert.True(edits.HasChanges);
        Assert.Null(SavedEdits.From(edits, (_, _, count) => [.. Enumerable.Repeat(Integer("1"), count)]));
        Assert.Null(SavedEdits.From(new TableEdits(Columns, dataRows: 2), Page("10", "20")));
    }

    [Fact]
    public void ARowWhoseKeyCannotBeReadIsNotKept()
    {
        var edits = new TableEdits(Columns, dataRows: 2);
        edits.SetCell(0, 1, new CellEdit.Text("x"), stored: "a");
        edits.SetCell(1, 1, new CellEdit.Text("y"), stored: "b");

        var unreadable = new TableProException(Errors.Of("ffi.out_of_range"));
        var saved = SavedEdits.From(edits, (column, first, count) =>
            first == 0 ? throw unreadable : Page("10", "20")(column, first, count));

        Assert.Equal(Id("20"), Assert.Single(saved!.Rows).Key!["id"]);
    }

    [Fact]
    public void AnOlderSessionFileStillReads()
    {
        var path = Path.Combine(_directory, "session.json");
        File.WriteAllText(path, """
            {
              "connections": [
                {
                  "filePath": "C:\\data\\app.sqlite",
                  "name": "app",
                  "tabs": [
                    { "kind": "Table", "title": "people", "table": "people", "pageSize": 100 },
                    { "kind": "Query", "title": "Query 1", "sql": "SELECT 1" }
                  ]
                }
              ],
              "front": 0
            }
            """);

        var tabs = Assert.Single(new SessionStore(path).Load().Connections).Tabs;

        Assert.Equal(2, tabs.Count);
        Assert.All(tabs, tab => Assert.False(tab.HasRecoveredWork));
        Assert.Null(tabs[0].Edits);
        Assert.Equal(100, tabs[0].PageSize);
        Assert.Equal("SELECT 1", tabs[1].Sql);
    }

    // An older build reads with the same settings: a property it does not know is passed over, never a broken file.
    [Fact]
    public void AFileWithWhatALaterBuildAddsStillReads()
    {
        var path = Path.Combine(_directory, "session.json");
        File.WriteAllText(path, """
            {
              "connections": [
                {
                  "filePath": "C:\\data\\app.sqlite",
                  "name": "app",
                  "tabs": [
                    {
                      "kind": "Table",
                      "title": "people",
                      "table": "people",
                      "laterProperty": { "anything": [1, 2] },
                      "edits": {
                        "rows": [
                          {
                            "key": { "id": { "kind": "Integer", "text": "10" } },
                            "cells": { "name": { "kind": "LaterKind", "text": "x" } },
                            "later": true
                          }
                        ]
                      }
                    }
                  ]
                }
              ]
            }
            """);

        var tab = Assert.Single(Assert.Single(new SessionStore(path).Load().Connections).Tabs);
        var edits = new TableEdits(Columns, dataRows: 1);

        var (restored, _, waiting) = tab.Edits!.RestoreTo(edits, Page("10"), Typed(edits));

        // A kind this build does not know waits, for a build that does or for Discard.
        Assert.True(tab.HasRecoveredWork);
        Assert.Equal(0, restored);
        Assert.Equal("LaterKind", waiting!.Rows[0].Cells["name"].Kind);
        Assert.False(edits.HasChanges);
    }

    [Fact]
    public void ALaunchWithReopenOffBringsBackOnlyTheTabsHoldingRecoveredWork()
    {
        var plain = new SessionTab { Kind = TabKind.Query, Title = "Query 1", Sql = "SELECT 1" };
        var held = new SessionTab { Kind = TabKind.Query, Title = "Query 2", HeldTransaction = true };
        var edited = new SessionTab
        {
            Kind = TabKind.Table,
            Title = "people",
            Table = "people",
            Edits = SavedEdits.From(Edited(), Page("10", "20", "30")),
        };
        var state = new SessionState
        {
            Connections =
            [
                new SessionConnection { FilePath = "a.sqlite", Name = "a", Tabs = [plain] },
                new SessionConnection
                {
                    FilePath = "b.sqlite",
                    Name = "b",
                    Tabs = [plain, edited, held],
                    SelectedTab = 2,
                },
                new SessionConnection { FilePath = "c.sqlite", Name = "c", Tabs = [plain, held], SelectedTab = 0 },
            ],
            Front = 0,
            ObjectPaneWidth = 300,
            TabWindows =
            [
                new TabWindowState { Connection = new SessionConnection { FilePath = "a.sqlite", Tabs = [plain] } },
                new TabWindowState { Connection = new SessionConnection { FilePath = "a.sqlite", Tabs = [edited] } },
            ],
        };

        var recovered = state.Recovered();

        Assert.Equal<string>(["b", "c"], [.. recovered.Connections.Select(connection => connection.Name)]);
        Assert.Equal<string>(["people", "Query 2"], [.. recovered.Connections[0].Tabs.Select(tab => tab.Title)]);
        Assert.Equal(1, recovered.Connections[0].SelectedTab);
        Assert.Equal(0, recovered.Connections[1].SelectedTab);
        Assert.Equal(0, recovered.Front);
        Assert.Equal(300, recovered.ObjectPaneWidth);
        Assert.Same(edited, Assert.Single(Assert.Single(recovered.TabWindows).Connection.Tabs));
        var nothing = new SessionState { Connections = [new SessionConnection { Tabs = [plain] }] };
        Assert.Empty(nothing.Recovered().Connections);
        Assert.Equal(-1, SessionState.Empty.Recovered().Front);
    }

    [Fact]
    public void TheFrontStaysWhenItHoldsRecoveredWork()
    {
        var held = new SessionTab { Kind = TabKind.Query, Title = "Query 1", HeldTransaction = true };
        var state = new SessionState
        {
            Connections =
            [
                new SessionConnection { FilePath = "a.sqlite", Name = "a", Tabs = [held] },
                new SessionConnection { FilePath = "b.sqlite", Name = "b", Tabs = [held] },
            ],
            Front = 1,
        };

        Assert.Equal(1, state.Recovered().Front);
    }

    private static TableEdits Edited()
    {
        var edits = new TableEdits(Columns, dataRows: 3);
        edits.SetCell(1, 1, new CellEdit.Text("Grace Hopper"), stored: "Grace");
        edits.SetCell(0, 2, CellEdit.Null.Instance, stored: "kept");
        edits.DeleteRows([2]);
        var added = edits.AddRow();
        edits.SetCell(added, 1, new CellEdit.Text("Ada"), stored: null);
        return edits;
    }

    // A page whose rows hold these integer ids, in this order, and other cells that read "r{row}c{column}".
    private static StoredValueReader Page(params string[] ids) =>
        Keys([.. ids.Select(Integer)]);

    private static StoredValueReader Keys(params StoredValue[] keys) => (column, first, count) =>
    [
        .. Enumerable.Range(first, count).Select(row =>
            column == 0 ? keys[row] : new StoredValue(ValueKind.Text, FakeTableEditor.Stored(row, column))),
    ];

    private static StoredValue Integer(string id) => new(ValueKind.Integer, id);

    private static SavedKeyPart Id(string id) => new() { Kind = "Integer", Text = id };

    // As the tab keeps a typed edit, against the page's stored text.
    private static Func<int, int, CellEdit, bool> Typed(TableEdits edits) => (row, column, edit) =>
    {
        edits.SetCell(row, column, edit, stored: edits.IsAdded(row) ? null : FakeTableEditor.Stored(row, column));
        return true;
    };

    private static SessionState WithTab(SessionTab tab) => new()
    {
        Connections = [new SessionConnection { FilePath = @"C:\data\app.sqlite", Name = "app", Tabs = [tab] }],
        Front = 0,
    };

    private static Dictionary<string, SavedKeyPart> Key(string id) => new() { ["id"] = Id(id) };

    private static SavedCell Text(string text) => new() { Kind = "Text", Text = text };

    private static Dictionary<string, SavedCell> Cells(params (string Column, SavedCell Cell)[] cells) =>
        cells.ToDictionary(cell => cell.Column, cell => cell.Cell);

    private static SavedRowEdit Update(string id, params (string Column, SavedCell Cell)[] cells) =>
        new() { Key = Key(id), Cells = Cells(cells) };

    private static EditColumn Column(
        string name, bool editable, CellEdit newRow, bool nullable, bool primaryKey = false) =>
        new(
            name,
            editable,
            EditableInNewRow: newRow is not CellEdit.ServerDefault,
            newRow,
            nullable,
            primaryKey,
            TakesEmpty: editable,
            TakesDefault: false);
}
