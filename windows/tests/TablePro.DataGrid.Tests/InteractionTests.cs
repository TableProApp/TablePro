using System.Runtime.InteropServices;
using System.Text;
using TablePro.DataGrid.Model;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.System;

namespace TablePro.DataGrid.Tests;

public sealed class InteractionTests
{
    [Fact]
    public Task KeysMoveTheFocusedCellAndKeepItInView() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var page = GridNavigation.PageRows(grid.VisibleArea().Height, grid.RowHeight);
        (VirtualKey Key, bool Control, int Row, int Column)[] steps =
        [
            (VirtualKey.Down, false, 1, 0),
            (VirtualKey.Right, false, 1, 1),
            (VirtualKey.PageDown, false, 1 + page, 1),
            (VirtualKey.PageDown, false, 1 + (2 * page), 1),
            (VirtualKey.PageUp, false, 1 + page, 1),
            (VirtualKey.End, false, 1 + page, 199),
            (VirtualKey.Home, false, 1 + page, 0),
            (VirtualKey.End, true, 999_999, 199),
            (VirtualKey.Up, false, 999_998, 199),
            (VirtualKey.Left, true, 999_998, 0),
            (VirtualKey.Home, true, 0, 0),
        ];
        foreach (var (key, control, row, column) in steps)
        {
            Assert.True(grid.HandleKey(key, control, shift: false));
            grid.UpdateLayout();
            await WinUiHost.NextFrameAsync();
            Assert.Equal((row, column), (grid.FocusedRow, grid.FocusedColumn));
            Assert.True(grid.IsCellVisible(row, column), $"{key} left ({row},{column}) out of view");
            var view = grid.VisibleArea();
            Assert.InRange(row * grid.RowHeight, view.Top - 0.5, view.Bottom - grid.RowHeight + 0.5);
        }
    });

    [Fact]
    public Task ShiftExtendsTheSelectionAndControlASelectsEverything() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.SelectCell(10, 4, extend: false);
        grid.HandleKey(VirtualKey.Down, control: false, shift: true);
        grid.HandleKey(VirtualKey.Down, control: false, shift: true);
        grid.HandleKey(VirtualKey.Right, control: false, shift: true);
        Assert.Equal(new CellRange(10, 4, 12, 5), grid.SelectionRange);
        Assert.True(grid.HandleKey(VirtualKey.A, control: true, shift: false));
        Assert.Equal(SelectionKind.All, grid.SelectionKind);
        Assert.Equal(new CellRange(0, 0, 999_999, 199), grid.SelectionRange);
        Assert.False(grid.HandleKey(VirtualKey.Q, control: false, shift: false));
    });

    [Fact]
    public Task AClickPicksACellShiftClickARangeAndTheRowNumbersPickRows() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData(), frozen: 1);
        var rh = grid.RowHeight;
        grid.HandlePress(frozen: false, new Point(grid.Columns.PaneX(3) + 5, (4 * rh) + 5), shift: false);
        Assert.Equal((4, 3), (grid.FocusedRow, grid.FocusedColumn));
        grid.HandlePress(frozen: false, new Point(grid.Columns.PaneX(5) + 5, (8 * rh) + 5), shift: true);
        Assert.Equal(new CellRange(4, 3, 8, 5), grid.SelectionRange);
        grid.HandlePress(frozen: true, new Point(grid.Columns.PaneX(0) + 5, (2 * rh) + 5), shift: false);
        Assert.Equal((2, 0), (grid.FocusedRow, grid.FocusedColumn));
        grid.HandlePress(frozen: true, new Point(4, (6 * rh) + 5), shift: false);
        grid.HandlePress(frozen: true, new Point(4, (9 * rh) + 5), shift: true);
        Assert.Equal(SelectionKind.Rows, grid.SelectionKind);
        Assert.Equal(new CellRange(6, 0, 9, 199), grid.SelectionRange);
    });

    [Fact]
    public Task CopyPutsExcelStyleTsvWithWholeValuesOnTheClipboard() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.SelectCell(6, 2, extend: false);
        grid.SelectCell(7, 5, extend: true);
        Assert.True(await grid.CopySelectionAsync());
        var expected = Expected(new CellRange(6, 2, 7, 5));
        Assert.Equal(expected, await ClipboardTextAsync());
        Assert.Contains(new string('x', 300) + "6", expected, StringComparison.Ordinal);
    });

    [Fact]
    public Task ASelectionLargerThanTheScreenCopiesEveryCellFromTheModel() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.SelectCell(100, 0, extend: false);
        grid.SelectCell(2_099, 11, extend: true);
        Assert.True(await grid.CopySelectionAsync());
        var copied = await ClipboardTextAsync();
        Assert.Equal(2_001, copied.Split("\r\n").Length);
        Assert.Equal(Expected(new CellRange(100, 0, 2_099, 11)), copied);
    });

    [Fact]
    public Task ACopyWhileAnotherProgramHoldsTheClipboardFailsAndTheNextOneCopies() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        grid.SelectCell(3, 2, extend: false);
        using (var held = HeldClipboard.Hold())
        {
            Assert.True(held.IsHeld);
            Assert.False(await grid.CopySelectionAsync());
        }

        Assert.True(await grid.CopySelectionAsync());
        Assert.Equal(Expected(new CellRange(3, 2, 3, 2)), await ClipboardTextAsync());
    });

    [Fact]
    public Task ACopyOfDataTheGridNoLongerShowsIsDropped() => WinUiHost.RunAsync(async () =>
    {
        var old = new SyntheticData(columns: 4);
        var grid = await WinUiHost.ShowAsync(old);
        var before = new DataPackage();
        before.SetText("before the copy");
        Clipboard.SetContent(before);
        grid.SelectAll();

        // As a refresh or a closing tab gives the grid new data and then lets the old set go.
        var copy = grid.CopySelectionAsync();
        grid.SetData(new SyntheticData(rows: 10, columns: 2));
        old.Release();

        Assert.False(await copy);
        Assert.Equal("before the copy", await ClipboardTextAsync());
    });

    [Fact]
    public Task AHeaderClickAsksForASortAndARepeatFlipsIt() => WinUiHost.RunAsync(async () =>
    {
        var grid = await WinUiHost.ShowAsync(new SyntheticData());
        var requests = new List<GridSort>();
        grid.SortRequested += (_, sort) => requests.Add(sort);
        grid.SortBy(4);
        grid.SortBy(4);
        grid.SortBy(6);
        Assert.Equal([new GridSort(4, SortDirection.Ascending), new GridSort(4, SortDirection.Descending), new GridSort(6, SortDirection.Ascending)], requests);
        grid.UpdateLayout();
        Assert.Equal(SortDirection.Ascending, grid.HeaderCell(6)!.SortDirection);
        Assert.Equal(SortDirection.None, grid.HeaderCell(4)!.SortDirection);
    });

    [Fact]
    public Task ResizingAndFittingAColumnRedrawsTheRows() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data);
        grid.ResizeColumn(2, 300);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.Equal(300, grid.Columns.Width(2));
        Assert.Equal(580, grid.Columns.PaneX(3));
        Assert.True(GridChecks.Check(grid, data).None);
        grid.FitColumn(5);
        Assert.True(grid.Columns.Width(5) > 1000);
        grid.FitColumn(0);
        Assert.InRange(grid.Columns.Width(0), GridColumns.MinimumWidth, 140);
        grid.UpdateLayout();
        await WinUiHost.NextFrameAsync();
        Assert.True(GridChecks.Check(grid, data).None);
    });

    [Fact]
    public Task FrozenColumnsStayInViewWhileTheRestScrolls() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData();
        var grid = await WinUiHost.ShowAsync(data, frozen: 2);
        await GridChecks.JumpAsync(grid, 9_000, 50_000);
        Assert.True(grid.IsCellVisible(grid.RowWindow.First + 1, 0));
        Assert.True(grid.IsCellVisible(grid.RowWindow.First + 1, 1));
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
        var row = (DrawnRow)grid.RealizedFrozenRows[grid.RowWindow.First + 1];
        Assert.Equal((0, 1), (row.DrawnFirst, row.DrawnLast));
        grid.SelectCell(grid.RowWindow.First + 2, 1, extend: false);
        grid.HandleKey(VirtualKey.Right, control: false, shift: false);
        Assert.Equal(2, grid.FocusedColumn);
    });

    [Fact]
    public Task RowsThatArriveLaterAreShownWithoutLosingTheView() => WinUiHost.RunAsync(async () =>
    {
        var data = new SyntheticData(rows: 30);
        var grid = await WinUiHost.ShowAsync(data);
        Assert.Equal(30, grid.RowCount);
        data.RowCount = 5_000;
        grid.RowsChanged();
        await GridChecks.JumpAsync(grid, 0, 4_000 * grid.RowHeight);
        Assert.Equal(5_000, grid.RowCount);
        var problems = GridChecks.Check(grid, data);
        Assert.True(problems.None, problems.ToString());
    });

    private static string Expected(CellRange range)
    {
        var tsv = new StringBuilder();
        for (var row = range.FirstRow; row <= range.LastRow; row++)
        {
            for (var column = range.FirstColumn; column <= range.LastColumn; column++)
            {
                if (column > range.FirstColumn)
                {
                    tsv.Append('\t');
                }
                tsv.Append(SyntheticData.Value(row, column));
            }
            tsv.Append("\r\n");
        }
        return tsv.ToString();
    }

    private static async Task<string> ClipboardTextAsync()
    {
        var content = Clipboard.GetContent();
        return content.Contains(StandardDataFormats.Text) ? await content.GetTextAsync() : "";
    }
}

// Another program with the clipboard open, as a clipboard manager or a remote desktop session has it for a moment.
internal sealed partial class HeldClipboard : IDisposable
{
    private readonly ManualResetEventSlim _release = new();
    private readonly Thread _thread;

    private HeldClipboard(ManualResetEventSlim opened)
    {
        _thread = new Thread(() =>
        {
            IsHeld = OpenClipboard(IntPtr.Zero);
            opened.Set();
            _release.Wait();
            if (IsHeld)
            {
                _ = CloseClipboard();
            }
        })
        {
            IsBackground = true,
            Name = "Clipboard holder",
        };
        _thread.Start();
    }

    public bool IsHeld { get; private set; }

    public static HeldClipboard Hold()
    {
        using var opened = new ManualResetEventSlim();
        var held = new HeldClipboard(opened);
        opened.Wait();
        return held;
    }

    public void Dispose()
    {
        _release.Set();
        _thread.Join();
        _release.Dispose();
    }

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool OpenClipboard(IntPtr owner);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseClipboard();
}
