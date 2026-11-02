using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.XamlTypeInfo;
using TablePro.DataGrid.Model;
using Windows.Graphics;

[assembly: CollectionBehavior(CollectionBehavior.CollectionPerAssembly)]

namespace TablePro.DataGrid.Tests;

// One WinUI app per test run, on an STA thread of its own, in the gate's 1440 x 900 window.
internal static class WinUiHost
{
    private static readonly Lazy<Task<DispatcherQueue>> s_queue = new(StartAsync);

    public static Window Window { get; private set; } = null!;

    public static async Task RunAsync(Func<Task> body)
    {
        var queue = await s_queue.Value.WaitAsync(TimeSpan.FromSeconds(90));
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        queue.TryEnqueue(async () =>
        {
            try
            {
                await body();
                done.SetResult();
            }
            catch (Exception ex)
            {
                done.SetException(ex);
            }
        });
        await done.Task.WaitAsync(TimeSpan.FromMinutes(5));
    }

    // A grid with data in the window, laid out and drawn.
    public static async Task<DataGridView> ShowAsync(IGridData data, int frozen = 0)
    {
        var grid = new DataGridView { DefaultColumnWidth = 140 };
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

    public static Task NextFrameAsync()
    {
        var tcs = new TaskCompletionSource();
        EventHandler<object>? handler = null;
        handler = (_, _) =>
        {
            CompositionTarget.Rendering -= handler;
            tcs.TrySetResult();
        };
        CompositionTarget.Rendering += handler;
        return tcs.Task;
    }

    private static Task<DispatcherQueue> StartAsync()
    {
        var ready = new TaskCompletionSource<DispatcherQueue>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                WinRT.ComWrappersSupport.InitializeComWrappers();
                Application.Start(callback =>
                {
                    var queue = DispatcherQueue.GetForCurrentThread();
                    SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(queue));
                    _ = new TestApp(window =>
                    {
                        Window = window;
                        ready.TrySetResult(queue);
                    }, error => ready.TrySetException(error));
                });
            }
            catch (Exception ex)
            {
                ready.TrySetException(ex);
            }
        })
        {
            IsBackground = true,
            Name = "WinUI",
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return ready.Task;
    }
}

// An app with no XAML files, so the WinUI controls' types come from their own metadata provider.
internal sealed partial class TestApp : Application, IXamlMetadataProvider
{
    private readonly XamlControlsXamlMetaDataProvider _provider;
    private readonly Action<Window> _ready;
    private readonly Action<Exception> _failed;

    public TestApp(Action<Window> ready, Action<Exception> failed)
    {
        _ready = ready;
        _failed = failed;
        XamlControlsXamlMetaDataProvider.Initialize();
        _provider = new XamlControlsXamlMetaDataProvider();
    }

    public IXamlType GetXamlType(Type type) => _provider.GetXamlType(type);

    public IXamlType GetXamlType(string fullName) => _provider.GetXamlType(fullName);

    public XmlnsDefinition[] GetXmlnsDefinitions() => _provider.GetXmlnsDefinitions();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            Resources.MergedDictionaries.Add(new XamlControlsResources());
            var window = new Window { Title = "TablePro.DataGrid.Tests" };
            window.AppWindow.MoveAndResize(new RectInt32(40, 40, 1440, 900));
            window.Activate();
            _ready(window);
        }
        catch (Exception ex)
        {
            _failed(ex);
        }
    }
}

// Column 3 is NULL every seventh row, column 5 past the cap, column 7 Arabic and column 9 an emoji.
internal sealed class SyntheticData(int rows = 1_000_000, int columns = 200) : IGridData
{
    public int RowCount { get; set; } = rows;

    public int ColumnCount => columns;

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
        public void Read(int firstRow, int rowCount, int firstColumn, int columnCount, int maxCharacters, CellBlock block)
        {
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

        public void Dispose()
        {
        }
    }
}
