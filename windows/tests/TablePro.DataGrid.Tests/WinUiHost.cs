using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using TablePro.DataGrid.Model;
using TablePro.Testing;

[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]

namespace TablePro.DataGrid.Tests;

// The grid's side of the shared WinUI app in tests/Shared/WinUiApp.cs.
internal static class WinUiHost
{
    public static Window Window => WinUiApp.Window;

    public static Task RunAsync(Func<Task> body) => WinUiApp.RunAsync(body);

    public static Task NextFrameAsync() => WinUiApp.NextFrameAsync();

    // A grid with data in the window, laid out and drawn.
    public static async Task<DataGridView> ShowAsync(IGridData data, int frozen = 0, bool sizeToContent = false)
    {
        var grid = new DataGridView { DefaultColumnWidth = 140, SizeColumnsToContent = sizeToContent };
        Window.Content = new Microsoft.UI.Xaml.Controls.Grid
        {
            Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"],
            Children = { grid },
        };
        grid.SetData(data);
        grid.FrozenColumnCount = frozen;
        for (var i = 0; i < 300 && grid.RealizedRows.Count == 0; i++)
        {
            await NextFrameAsync();
        }
        await NextFrameAsync();
        return grid;
    }
}

// Column 3 is NULL every seventh row, column 5 past the cap, column 7 Arabic and column 9 an emoji.
internal sealed class SyntheticData(int rows = 1_000_000, int columns = 200) : IGridData
{
    public int RowCount { get; set; } = rows;

    public int ColumnCount => columns;

    // As a result set the app has released: a reader that reads it after this fails, as a disposed cursor does.
    public bool IsReleased { get; private set; }

    public void Release() => IsReleased = true;

    public string GetColumnName(int column) => string.Create(CultureInfo.InvariantCulture, $"column_{column}");

    public IGridReader OpenReader() => new Reader(this);

    public static string? Value(int row, int column) => column switch
    {
        3 when row % 7 == 0 => null,
        5 => new string('x', 300) + row.ToString(CultureInfo.InvariantCulture),
        7 => string.Create(CultureInfo.InvariantCulture, $"مرحبا {row}"),
        9 => string.Create(CultureInfo.InvariantCulture, $"😀 {row}"),
        _ => string.Create(CultureInfo.InvariantCulture, $"r{row}c{column}"),
    };

    private sealed class Reader(SyntheticData data) : IGridReader
    {
        private bool _disposed;

        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
            ObjectDisposedException.ThrowIf(_disposed || data.IsReleased, this);
            var rows = Math.Max(0, Math.Min(rowCount, data.RowCount - firstRow));
            var columns = Math.Max(0, Math.Min(columnCount, data.ColumnCount - firstColumn));
            block.Reset(firstRow, rows, firstColumn, columns, maxCharacters);
            for (var column = firstColumn; column < firstColumn + columns; column++)
            {
                for (var row = firstRow; row < firstRow + rows; row++)
                {
                    var value = Value(row, column);
                    if (value is null)
                    {
                        block.AddNull();
                    }
                    else if (value.Length > maxCharacters)
                    {
                        block.Add(value.AsSpan(0, maxCharacters), truncated: true);
                    }
                    else
                    {
                        block.Add(value, truncated: false);
                    }
                }
            }
        }

        public string? ReadWhole(int row, int column) => Value(row, column);

        public void Dispose() => _disposed = true;
    }
}
