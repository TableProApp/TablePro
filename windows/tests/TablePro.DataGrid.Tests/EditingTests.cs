using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using TablePro.DataGrid.Automation;
using TablePro.DataGrid.Model;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using Windows.System;

namespace TablePro.DataGrid.Tests;

// The in-place editor and the marks of pending changes. The host's checks and saves are the app's.
public sealed class EditingTests
{
    [Fact]
    public Task F2OpensATextBoxOverTheCellWithTheHostsText() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var starts = new List<(int Row, int Column)>();
        grid.CellEditStarting += (_, e) =>
        {
            starts.Add((e.Row, e.Column));
            Assert.Equal("r2c3", e.Text);
            e.Text = "host text";
        };
        grid.SelectCell(2, 3, extend: false);

        Assert.True(grid.HandleKey(VirtualKey.F2, control: false, shift: false));
        Assert.False(grid.IsEditing);
        await SettleAsync(grid);

        var editor = Assert.IsType<TextBox>(grid.Editor);
        Assert.True(grid.IsEditing);
        Assert.Equal((2, 3), Assert.Single(starts));
        Assert.Equal("host text", editor.Text);
        Assert.Equal("host text", editor.SelectedText);
        Assert.Equal(grid.Painter.FamilyName, editor.FontFamily.Source);
        Assert.Equal(grid.Columns.Width(3), editor.ActualWidth, 1);
        var at = editor.TransformToVisual(grid.ScrollingPane).TransformPoint(default);
        Assert.Equal(grid.Columns.PaneX(3), at.X, 1);
        Assert.Equal(2 * grid.RowHeight, at.Y, 1);
        grid.CancelEdit();
    });

    [Fact]
    public Task AnEditorInAFrozenColumnSitsInTheFrozenPane() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData(), frozen: 1);
        grid.SelectCell(5, 0, extend: false);

        grid.BeginEdit();
        await SettleAsync(grid);

        var editor = grid.Editor!;
        Assert.Equal("r5c0", editor.Text);
        var at = editor.TransformToVisual(grid.FrozenPane).TransformPoint(default);
        Assert.Equal(grid.Columns.PaneX(0), at.X, 1);
        Assert.Equal(5 * grid.RowHeight, at.Y, 1);
        grid.CancelEdit();
    });

    [Fact]
    public Task EnterRaisesCellEditCommittingWithTheTypedText() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = new List<(int Row, int Column, string Text)>();
        grid.CellEditCommitting += (_, e) => commits.Add((e.Row, e.Column, e.Text));
        grid.SelectCell(4, 1, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);

        var editor = grid.Editor!;
        editor.Text = "typed";
        Assert.True(grid.HandleEditorKey(VirtualKey.Enter, control: false, shift: false));

        Assert.Equal((4, 1, "typed"), Assert.Single(commits));
        Assert.False(grid.IsEditing);
        Assert.Equal(Visibility.Collapsed, editor.Visibility);
        Assert.Equal((4, 1), (grid.FocusedRow, grid.FocusedColumn));
    });

    // A NULL cell opened and left as it was stays NULL: the text it opened with is no change.
    [Fact]
    public Task EnterOnUnchangedTextRaisesNothing() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = 0;
        grid.CellEditCommitting += (_, _) => commits++;
        grid.SelectCell(0, 3, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);

        Assert.Equal("", grid.Editor!.Text);
        Assert.True(grid.HandleEditorKey(VirtualKey.Enter, control: false, shift: false));

        Assert.Equal(0, commits);
        Assert.False(grid.IsEditing);
    });

    [Fact]
    public Task EscapeCancelsWithoutAnEvent() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = 0;
        grid.CellEditCommitting += (_, _) => commits++;
        grid.SelectCell(4, 1, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);

        grid.Editor!.Text = "typed";
        Assert.True(grid.HandleEditorKey(VirtualKey.Escape, control: false, shift: false));

        Assert.Equal(0, commits);
        Assert.False(grid.IsEditing);
        Assert.True(grid.CommitEdit());
        Assert.Equal(0, commits);
    });

    [Fact]
    public Task AnErrorFromTheHostKeepsTheEditorOpenAndShowsIt() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        grid.CellEditCommitting += (_, e) => e.Error = "Not a number";
        grid.SelectCell(1, 2, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);

        var editor = grid.Editor!;
        editor.Text = "abc";
        Assert.True(grid.HandleEditorKey(VirtualKey.Enter, control: false, shift: false));

        Assert.True(grid.IsEditing);
        Assert.Equal(Visibility.Visible, editor.Visibility);
        Assert.Equal("abc", editor.Text);
        Assert.Equal("Not a number", AutomationProperties.GetFullDescription(editor));
        Assert.Equal("Not a number", Assert.IsType<ToolTip>(ToolTipService.GetToolTip(editor)).Content);
        Assert.False(grid.CommitEdit());
        Assert.True(grid.IsEditing);

        grid.CancelEdit();
        Assert.False(grid.IsEditing);
        Assert.Equal("", AutomationProperties.GetFullDescription(editor));
        Assert.Null(ToolTipService.GetToolTip(editor));
    });

    [Fact]
    public Task TabCommitsAndEditsTheNextCell() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = new List<(int Row, int Column, string Text)>();
        grid.CellEditCommitting += (_, e) => commits.Add((e.Row, e.Column, e.Text));
        grid.SelectCell(3, 4, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);

        var editor = grid.Editor!;
        editor.Text = "four";
        Assert.True(grid.HandleEditorKey(VirtualKey.Tab, control: false, shift: false));
        await SettleAsync(grid);

        Assert.Equal((3, 4, "four"), Assert.Single(commits));
        Assert.True(grid.IsEditing);
        Assert.Equal((3, 5), (grid.FocusedRow, grid.FocusedColumn));
        Assert.Equal(SyntheticData.Value(3, 5), editor.Text);
        Assert.True(grid.HandleEditorKey(VirtualKey.Tab, control: false, shift: true));
        Assert.Equal((3, 4), (grid.FocusedRow, grid.FocusedColumn));
        Assert.False(grid.IsEditing);
        await SettleAsync(grid);

        Assert.True(grid.IsEditing);
        Assert.Equal("r3c4", editor.Text);
        Assert.Single(commits);
        grid.CancelEdit();
    });

    [Fact]
    public Task AValueWithNulOpensNothing() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        grid.CellEditStarting += (_, e) => e.Text = "a\0b";

        grid.BeginEdit();
        await SettleAsync(grid);

        Assert.False(grid.IsEditing);
    });

    [Fact]
    public Task AValueWithMixedLineBreaksOpenedAndLeftRaisesNothing() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = new List<string>();
        grid.CellEditStarting += (_, e) => e.Text = "a\nb\r\nc";
        grid.CellEditCommitting += (_, e) => commits.Add(e.Text);
        grid.BeginEdit();
        await SettleAsync(grid);

        var editor = grid.Editor!;
        Assert.True(editor.AcceptsReturn);
        Assert.True(grid.HandleEditorKey(VirtualKey.Enter, control: true, shift: false));
        Assert.Empty(commits);
        Assert.False(grid.IsEditing);

        grid.BeginEdit();
        await SettleAsync(grid);
        editor.Text = "a\rb";
        Assert.True(grid.HandleEditorKey(VirtualKey.Enter, control: true, shift: false));
        Assert.Equal("a\r\nb", Assert.Single(commits));
    });

    // The editor's row index outlives the host's change only on a data row.
    [Fact]
    public Task RowsThatComeOrGoCloseAnOpenEditor() => WinUiHost.RunAsync(async () =>
    {
        var edited = new EditedGridData(new SyntheticData(rows: 100, columns: 10), NewRows(2));
        var grid = await ShowEditableAsync(edited);
        var commits = new List<(int Row, int Column, string Text)>();
        grid.CellEditCommitting += (_, e) => commits.Add((e.Row, e.Column, e.Text));

        grid.SelectCell(101, 0, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);
        grid.Editor!.Text = "typed";
        edited.Edits = NewRows(1);
        grid.EditsChanged();

        Assert.False(grid.IsEditing);
        Assert.Empty(commits);
        Assert.Equal(101, grid.RowCount);

        grid.SelectCell(3, 2, extend: false);
        grid.BeginEdit();
        await SettleAsync(grid);
        grid.Editor!.Text = "typed";
        edited.Edits = GridEdits.None;
        grid.EditsChanged();

        Assert.False(grid.IsEditing);
        Assert.Equal((3, 2, "typed"), Assert.Single(commits));
        Assert.Equal(100, grid.RowCount);
    });

    [Fact]
    public Task AGridThatIsNotEditableOpensNothing() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var events = 0;
        grid.CellEditStarting += (_, _) => events++;
        grid.DeleteRequested += (_, _) => events++;

        Assert.False(grid.IsEditable);
        Assert.False(grid.HandleKey(VirtualKey.F2, control: false, shift: false));
        Assert.False(grid.HandleKey(VirtualKey.Enter, control: false, shift: false));
        Assert.False(grid.HandleKey(VirtualKey.Delete, control: false, shift: false));
        grid.BeginEdit();

        Assert.False(grid.IsEditing);
        Assert.Null(grid.Editor);
        Assert.Equal(0, events);
    });

    [Fact]
    public Task DeleteRaisesDeleteRequestedOnlyWithNoEditorOpen() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var deletes = 0;
        grid.DeleteRequested += (_, _) => deletes++;

        Assert.True(grid.HandleKey(VirtualKey.Delete, control: false, shift: false));
        Assert.Equal(1, deletes);

        grid.BeginEdit();
        Assert.False(grid.HandleKey(VirtualKey.Delete, control: false, shift: false));
        Assert.Equal(1, deletes);
        grid.CancelEdit();
        Assert.False(grid.HandleKey(VirtualKey.Delete, control: true, shift: false));
        Assert.Equal(1, deletes);
    });

    [Fact]
    public Task NewDataCancelsAnOpenEditor() => WinUiHost.RunAsync(async () =>
    {
        var grid = await ShowEditableAsync(new SyntheticData());
        var commits = 0;
        grid.CellEditCommitting += (_, _) => commits++;
        grid.BeginEdit();
        await SettleAsync(grid);
        grid.Editor!.Text = "typed";

        grid.SetData(new SyntheticData(rows: 10, columns: 4));

        Assert.False(grid.IsEditing);
        Assert.Equal(0, commits);
    });

    // The host swaps the edits and calls EditsChanged: rows, marks, names and ItemStatus follow, with no stale cell.
    [Fact]
    public Task PendingChangesAreDrawnAndReadByUiAutomation() => WinUiHost.RunAsync(async () =>
    {
        var edited = new EditedGridData(new SyntheticData(rows: 100, columns: 10), GridEdits.None);
        var grid = await ShowEditableAsync(edited, frozen: 1);
        var peer = (DataGridAutomationPeer)FrameworkElementAutomationPeer.CreatePeerForElement(grid);
        var changed = peer.Cell(1, 1);
        Assert.Equal("", changed.GetItemStatus());

        edited.Edits = new GridEdits(
            new Dictionary<(int Row, int Column), PendingCell> { [(1, 1)] = new(PendingKind.Value, "pending") },
            new HashSet<int> { 2 },
            [new PendingCell[] { new(PendingKind.Value, "new"), new(PendingKind.Default, "") }]);
        grid.EditsChanged();
        await SettleAsync(grid);

        Assert.Equal(101, grid.RowCount);
        Assert.Equal("pending", changed.GetName());
        Assert.Equal(grid.EditedStatus, changed.GetItemStatus());
        Assert.Equal("", peer.Cell(1, 0).GetItemStatus());
        Assert.Equal(grid.DeletedStatus, peer.Cell(2, 4).GetItemStatus());
        Assert.Equal("r2c4", peer.Cell(2, 4).GetName());
        Assert.Equal(grid.NewRowStatus, peer.Cell(100, 0).GetItemStatus());
        Assert.Equal(grid.DefaultText, peer.Cell(100, 1).GetName());
        var problems = GridChecks.Check(grid, edited);
        Assert.True(problems.None, problems.ToString());
        AssertMarks(grid);

        grid.SelectCell(100, 1, extend: false);
        edited.Edits = GridEdits.None;
        grid.EditsChanged();
        await SettleAsync(grid);

        Assert.Equal(100, grid.RowCount);
        Assert.Equal(99, grid.FocusedRow);
        Assert.Equal("", changed.GetItemStatus());
        Assert.Equal("r1c1", changed.GetName());
        problems = GridChecks.Check(grid, edited);
        Assert.True(problems.None, problems.ToString());
    });

    private static unsafe void AssertMarks(DataGridView grid)
    {
        var painter = grid.Painter;
        var modified = grid.Cell(1, 1);
        var layout = painter.CreateLayout(modified.Text, modified.State, 116, 32, out var ink);
        BOOL underline;
        layout->GetUnderline(0, &underline, null);
        layout->Release();
        Assert.Equal(CellInk.Text, ink);
        Assert.Equal(BOOL.TRUE, underline);

        var deleted = grid.Cell(2, 4);
        layout = painter.CreateLayout(deleted.Text, deleted.State, 116, 32, out ink);
        BOOL strikethrough;
        layout->GetStrikethrough(0, &strikethrough, null);
        layout->Release();
        Assert.Equal(CellInk.Deleted, ink);
        Assert.Equal(BOOL.TRUE, strikethrough);

        var server = grid.Cell(100, 1);
        Assert.True(server.IsDefault);
        layout = painter.CreateLayout(server.Text, server.State, 116, 32, out ink);
        DWRITE_FONT_WEIGHT weight;
        layout->GetFontWeight(0, &weight, null);
        layout->GetUnderline(0, &underline, null);
        layout->Release();
        Assert.Equal(CellInk.Default, ink);
        Assert.Equal(DWRITE_FONT_WEIGHT.DWRITE_FONT_WEIGHT_SEMI_BOLD, weight);
        Assert.Equal(BOOL.TRUE, underline);
    }

    private static GridEdits NewRows(int count) => new(
        new Dictionary<(int Row, int Column), PendingCell>(),
        new HashSet<int>(),
        [.. Enumerable.Range(0, count).Select(_ => (IReadOnlyList<PendingCell>)new[] { new PendingCell(PendingKind.Value, "new") })]);

    private static async Task<DataGridView> ShowEditableAsync(IGridData data, int frozen = 0)
    {
        var grid = await WinUiHost.ShowAsync(data, frozen);
        grid.IsEditable = true;
        return grid;
    }

    private static async Task SettleAsync(DataGridView grid)
    {
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        await WinUiHost.NextFrameAsync();
    }
}
