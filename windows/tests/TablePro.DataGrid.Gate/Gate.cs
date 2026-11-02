using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.DataGrid.Model;
using TablePro.Interop;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;

namespace TablePro.DataGrid.Gate;

// The spike's phases and measures (lane wingates2, GridGate/GridBench.cs) over the product control and the core.
internal sealed partial class Gate(RunContext ctx)
{
    private readonly Report _report = ctx.Report;
    private Microsoft.UI.Xaml.Controls.Grid _root = null!;
    private TextBlock _status = null!;
    private DataGridView _grid = null!;
    private BenchData _bench = null!;
    private ResultSet _set = null!;
    private WideData _wide = null!;
    private CellCache _expected = null!;

    public async Task RunAsync()
    {
        var args = ctx.Args;
        var rows = args.GetInt("rows", 1_000_000);
        var rounds = args.GetInt("rounds", 10);
        _status = new TextBlock { Margin = new Thickness(8), Text = "loading" };
        _root = new Microsoft.UI.Xaml.Controls.Grid
        {
            Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"],
        };
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.Children.Add(_status);
        ctx.Window.Content = _root;
        await Frames.SkipAsync(10);
        _report.Line("raster_scale", _root.XamlRoot.RasterizationScale);
        _report.Line("memory_before_core", Mem.Snapshot());

        var t = Clock.Now();
        _bench = await BenchData.CreateAsync();
        _report.Line("pool_ms", Clock.MsSince(t));
        t = Clock.Now();
        var (run, set, data) = await _bench.QueryAsync(BenchData.WideQuery(rows), rows);
        _set = set;
        _report.Line("core_query_ms", Clock.MsSince(t));
        _report.Line("core_rows", data.RowCount);
        _report.Line("memory_after_core", Mem.Snapshot());
        _wide = new WideData(data, rounds);
        _expected = new CellCache(_wide.OpenReader(), capacity: 1024);

        t = Clock.Now();
        _grid = new DataGridView { DefaultColumnWidth = 140 };
        Microsoft.UI.Xaml.Controls.Grid.SetRow(_grid, 1);
        _root.Children.Add(_grid);
        _grid.SetData(_wide);
        _grid.FrozenColumnCount = args.GetInt("frozen", 1);
        for (var frames = 0; frames < 600 && _grid.RealizedRows.Count == 0; frames++)
        {
            await Frames.NextAsync();
        }
        await Frames.NextAsync();
        _report.Line("first_cells_ms_since_control_created", Clock.MsSince(t));
        _report.Line("first_cells_ms_since_process_start", Clock.SinceProcessStart());
        await DataGridView.FontWarmupTask;
        _report.Line("font_warmup_background_ms", DataGridView.FontWarmupMilliseconds);
        await Task.Delay(1000);

        var sv = _grid.Scroller;
        _report.Line("viewport", $"width={sv.ViewportWidth:F0} height={sv.ViewportHeight:F0} extent={sv.ExtentWidth:F0}x{sv.ExtentHeight:F0} grid={_grid.ActualWidth:F0}x{_grid.ActualHeight:F0}");
        _report.Line("insets", $"left={_grid.Insets.Left:F1} top={_grid.Insets.Top:F1} visible={_grid.VisibleArea()}");
        _report.Line("rendering", $"software={DataGridView.IsSoftwareRendering} font={_grid.Painter.FamilyName} size={_grid.Painter.FontSize} row_height={_grid.RowHeight}");
        State("idle");
        await Native.SaveScreenAsync(ctx.Shot("idle-light"));

        if (!args.Has("checks-only"))
        {
            await PerfAsync();
        }
        if (!args.Has("perf-only"))
        {
            await ChecksAsync();
        }
        _report.Line("memory_end", Mem.Snapshot());
        _report.Line("data_end", $"blocks_fetched={_expected.BlocksFetched}");
        _grid.SetData(null);
        set.Dispose();
        run.Dispose();
        await _bench.DisposeAsync();
    }

    private async Task PerfAsync()
    {
        var sv = _grid.Scroller;
        var rh = _grid.RowHeight;
        double MaxY() => Math.Max(0, sv.ScrollableHeight);
        double MaxX() => Math.Max(0, sv.ScrollableWidth);
        double y = 0, x = 0;
        var random = new Random(7);
        using var heartbeat = new Heartbeat(ctx.Window.DispatcherQueue);
        await Phase(heartbeat, "v_smooth", 600, _ => (0, y = Math.Min(MaxY(), y + (rh * 3))), check: false);
        await Phase(heartbeat, "v_page", 200, _ => (0, y = Math.Min(MaxY(), y + sv.ViewportHeight)), check: false);
        await Phase(heartbeat, "v_random", 200, _ => (0, y = random.NextDouble() * MaxY()), check: false);
        y = MaxY() / 2;
        await Phase(heartbeat, "h_smooth", 400, _ => (x = x + 48 > MaxX() ? 0 : x + 48, y), check: false);
        await Phase(heartbeat, "h_page", 100, _ => (x = x + sv.ViewportWidth > MaxX() ? 0 : x + sv.ViewportWidth, y), check: false);
        await Phase(heartbeat, "xy_random", 200, _ => (random.NextDouble() * MaxX(), random.NextDouble() * MaxY()), check: false);
        await Phase(heartbeat, "v_page_verify", 100, _ => (x, y = y + sv.ViewportHeight > MaxY() ? 0 : y + sv.ViewportHeight), check: true);
        await Phase(heartbeat, "xy_random_verify", 200, _ => (random.NextDouble() * MaxX(), random.NextDouble() * MaxY()), check: true);
        await Native.SaveScreenAsync(ctx.Shot("after-random-jumps"));
    }

    private async Task Phase(Heartbeat heartbeat, string name, int frames, Func<int, (double X, double Y)> next, bool check)
    {
        _status.Text = name;
        await Task.Delay(300);
        heartbeat.Take();
        var bound = _grid.Counters.CellsBound;
        var elements = DrawnRow.Instances + HeaderCell.Instances;
        _grid.Counters.Reset();
        var verify = new Verifier(this);
        int notApplied = 0;
        int[] gcStart = [GC.CollectionCount(0), GC.CollectionCount(1), GC.CollectionCount(2)];
        var pauseStart = GC.GetTotalPauseDuration();
        var worst = "";
        var worstMs = -1.0;
        var gcSteps = 0;
        var allocated = new List<double>(frames);
        var samples = await Frames.LoopAsync(frames, i =>
        {
            if (check && i > 0)
            {
                verify.Check(afterFrame: true);
            }
            var (x, y) = next(i);
            int gen0 = GC.CollectionCount(0), gen2 = GC.CollectionCount(2);
            var bytes = GC.GetAllocatedBytesForCurrentThread();
            var fetch = _grid.FetchMilliseconds;
            var blocks = _grid.BlocksFetched;
            var draw = _grid.Counters.DrawMilliseconds;
            var drawn = _grid.Counters.RowsDrawn;
            var measure = _grid.Counters.Layout.MeasureMilliseconds + _grid.Counters.FrozenLayout.MeasureMilliseconds;
            var s = Clock.Now();
            _grid.ScrollTo(x, y);
            _grid.UpdateLayout();
            var ms = Clock.MsSince(s);
            allocated.Add(GC.GetAllocatedBytesForCurrentThread() - bytes);
            var gcs = GC.CollectionCount(0) - gen0;
            gcSteps += gcs > 0 ? 1 : 0;
            if (ms > worstMs)
            {
                worstMs = ms;
                worst = string.Create(CultureInfo.InvariantCulture,
                    $"i={i} ms={ms:F1} x={x:F0} y={y:F0} columns={_grid.ColumnWindow} gen0_gcs={gcs} gen2_gcs={GC.CollectionCount(2) - gen2} " +
                    $"fetch_ms={_grid.FetchMilliseconds - fetch:F1} blocks={_grid.BlocksFetched - blocks} draw_ms={_grid.Counters.DrawMilliseconds - draw:F1} " +
                    $"rows_drawn={_grid.Counters.RowsDrawn - drawn} measure_ms={_grid.Counters.Layout.MeasureMilliseconds + _grid.Counters.FrozenLayout.MeasureMilliseconds - measure:F1}");
            }
            var sv = _grid.Scroller;
            var applied = Math.Abs(sv.HorizontalOffset - Math.Min(x, sv.ScrollableWidth)) < 1 && Math.Abs(sv.VerticalOffset - Math.Min(y, sv.ScrollableHeight)) < 2;
            notApplied += applied ? 0 : 1;
            if (check)
            {
                verify.Check(afterFrame: false);
            }
            return ms;
        });
        if (check)
        {
            await Frames.NextAsync();
            verify.Check(afterFrame: true);
        }
        Frames.Report(_report, name, samples);
        _report.Line($"{name}.worst_block", heartbeat.Worst() + string.Create(CultureInfo.InvariantCulture,
            $" gc_pause_ms={(GC.GetTotalPauseDuration() - pauseStart).TotalMilliseconds:F1}"));
        _report.Stats($"{name}.heartbeat_wait_ms", heartbeat.Take());
        _report.Line($"{name}.cells_bound", _grid.Counters.CellsBound - bound);
        _report.Line($"{name}.elements_created", DrawnRow.Instances + HeaderCell.Instances - elements);
        var c = _grid.Counters;
        _report.Line($"{name}.layout", string.Create(CultureInfo.InvariantCulture,
            $"measures={c.Layout.Measures} measure_ms={c.Layout.MeasureMilliseconds:F0} get_element_ms={c.Layout.GetElementMilliseconds:F0} elements_requested={c.Layout.ElementsRequested} frozen_measure_ms={c.FrozenLayout.MeasureMilliseconds:F0} draw_ms={c.DrawMilliseconds:F0} rows_drawn={c.RowsDrawn} text_layouts={_grid.Painter.LayoutsCreated} steps={frames} offset_not_applied={notApplied}"));
        _report.Line($"{name}.gc", $"gen0={GC.CollectionCount(0) - gcStart[0]} gen1={GC.CollectionCount(1) - gcStart[1]} gen2={GC.CollectionCount(2) - gcStart[2]} steps_with_gc={gcSteps}");
        _report.Line($"{name}.worst_step", worst);
        _report.Stats($"{name}.allocated_bytes_per_step", allocated);
        if (check)
        {
            _report.Line($"{name}.verify", verify.Summary());
        }
        await Task.Delay(400);
        State(name);
    }

    private void State(string phase)
    {
        var view = _grid.VisibleArea();
        var rh = _grid.RowHeight;
        var visibleRows = (int)Math.Ceiling(view.Height / rh) + 1;
        var (c0, c1) = _grid.Columns.ScrollRange(view.X, view.Width);
        var visibleColumns = Math.Max(0, c1 - c0 + 1) + _grid.Columns.FrozenCount;
        var cells = 0;
        foreach (var (_, row) in _grid.RealizedRows)
        {
            cells += ((DrawnRow)row).CellCount;
        }
        foreach (var (_, row) in _grid.RealizedFrozenRows)
        {
            cells += ((DrawnRow)row).CellCount;
        }
        _report.Line($"{phase}.realized", new JsonObject
        {
            ["cells"] = cells,
            ["bound_cells"] = visibleRows * visibleColumns,
            ["rows"] = _grid.RealizedRows.Count,
            ["frozen_rows"] = _grid.RealizedFrozenRows.Count,
            ["visible_rows_bound"] = visibleRows,
            ["visible_columns"] = visibleColumns,
            ["headers"] = _grid.RealizedHeaders.Count,
            ["row_elements_created"] = _grid.RowElementsCreated,
            ["header_elements_created"] = HeaderCell.Instances,
            ["duplicate_recycles"] = _grid.DuplicateRecycles,
            ["visual_elements_in_grid"] = Visuals.Count(_grid),
            ["within_bound"] = cells <= visibleRows * visibleColumns,
        });
        _report.Line($"{phase}.memory", Mem.Snapshot());
    }

    // The expected text comes from a cache over a reader of its own, not the grid's.
    private sealed class Verifier(Gate gate)
    {
        private readonly long[] _checks = new long[2];
        private readonly long[] _stale = new long[2];
        private readonly long[] _missing = new long[2];
        private readonly long[] _misplaced = new long[2];
        private readonly long[] _headers = new long[2];
        private readonly string[] _first = ["", ""];
        private long _cells;

        public void Check(bool afterFrame)
        {
            var k = afterFrame ? 1 : 0;
            _checks[k]++;
            var grid = gate._grid;
            foreach (var (row, element) in grid.RealizedRows)
            {
                CheckRow(k, row, (DrawnRow)element, grid.ScrollingPane);
            }
            foreach (var (row, element) in grid.RealizedFrozenRows)
            {
                CheckRow(k, row, (DrawnRow)element, grid.FrozenPane);
            }
            var view = grid.VisibleArea();
            var rh = grid.RowHeight;
            var r0 = (int)Math.Floor(view.Top / rh);
            var r1 = Math.Min(grid.RowCount - 1, (int)Math.Ceiling(view.Bottom / rh) - 1);
            var (c0, c1) = grid.Columns.ScrollRange(view.X, view.Width);
            for (var row = r0; row <= r1; row++)
            {
                if (!grid.RealizedRows.TryGetValue(row, out var element) || !grid.RealizedFrozenRows.ContainsKey(row))
                {
                    _missing[k] += c1 - c0 + 1;
                    Note(k, $"missing row {row} of {r0}..{r1}");
                    continue;
                }
                var drawn = (DrawnRow)element;
                for (var column = c0; column <= c1; column++)
                {
                    if (!drawn.TryGetDrawn(column, out _, out _))
                    {
                        _missing[k]++;
                        Note(k, $"missing ({row},{column}) drawn {drawn.DrawnFirst}..{drawn.DrawnLast} window {grid.ColumnWindow}");
                    }
                }
            }
            for (var column = c0; column <= c1; column++)
            {
                if (grid.HeaderCell(column) is not { } header || header.Title != gate._wide.GetColumnName(column))
                {
                    _headers[k]++;
                    Note(k, $"header {column}");
                }
            }
        }

        public JsonObject Summary()
        {
            JsonObject Part(int k) => new()
            {
                ["checks"] = _checks[k],
                ["stale"] = _stale[k],
                ["missing"] = _missing[k],
                ["misplaced"] = _misplaced[k],
                ["header_problems"] = _headers[k],
                ["first"] = _first[k],
            };
            return new JsonObject { ["cells_checked"] = _cells, ["right_after_step"] = Part(0), ["one_frame_later"] = Part(1) };
        }

        private void CheckRow(int k, int row, DrawnRow drawn, UIElement pane)
        {
            var grid = gate._grid;
            if (drawn.Row != row || drawn.DrawnRowIndex != row)
            {
                _misplaced[k]++;
                Note(k, $"row element for {row} holds {drawn.Row}, drew {drawn.DrawnRowIndex}");
                return;
            }
            var at = drawn.TransformToVisual(pane).TransformPoint(default);
            // Float has a 2 px step at 32M px.
            if (Math.Abs(at.Y - (row * grid.RowHeight)) > 4 || Math.Abs(at.X) > 0.5)
            {
                _misplaced[k]++;
                Note(k, $"row {row} at {at.X:F1},{at.Y:F1}");
            }
            if (!drawn.IsFrozen && drawn.DrawnLast >= drawn.DrawnFirst
                && Math.Abs(drawn.SpriteX - grid.Columns.PaneX(drawn.DrawnFirst)) > 0.5)
            {
                _misplaced[k]++;
                Note(k, $"row {row} surface at {drawn.SpriteX} for column {drawn.DrawnFirst}");
            }
            for (var column = drawn.DrawnFirst; column <= drawn.DrawnLast; column++)
            {
                _cells++;
                if (!drawn.TryGetDrawn(column, out var hash, out var length))
                {
                    continue;
                }
                var cell = gate._expected.Get(row, column, grid.CapFor(column));
                if (cell.Text.Length != length || string.GetHashCode(cell.Text) != hash)
                {
                    _stale[k]++;
                    Note(k, $"stale ({row},{column})");
                }
            }
        }

        private void Note(int k, string problem)
        {
            if (_first[k].Length == 0)
            {
                _first[k] = problem;
            }
        }
    }

    // The TSV a selection should copy, from the core's whole values one cell at a time: not the grid's path.
    private string ExpectedTsv(CellRange range)
    {
        var physical = _wide.Inner.ColumnCount;
        var tsv = new StringBuilder();
        for (var row = range.FirstRow; row <= range.LastRow; row++)
        {
            for (var column = range.FirstColumn; column <= range.LastColumn; column++)
            {
                if (column > range.FirstColumn)
                {
                    tsv.Append('\t');
                }
                GridCopy.AppendValue(tsv, _set.GetCellText(row, column % physical));
            }
            tsv.Append("\r\n");
        }
        return tsv.ToString();
    }

    private static async Task<string> ClipboardTextAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            return content.Contains(StandardDataFormats.Text) ? await content.GetTextAsync() : "<no text>";
        }
        catch (Exception ex)
        {
            return "<error " + ex.Message + ">";
        }
    }

    private (int X, int Y) CellCenterOnScreen(int row, int column)
    {
        _grid.UpdateLayout();
        var frozen = column < _grid.Columns.FrozenCount;
        var pane = frozen ? _grid.FrozenPane : _grid.ScrollingPane;
        var x = _grid.Columns.PaneX(column) + (_grid.Columns.Width(column) / 2);
        var y = (row * _grid.RowHeight) + (_grid.RowHeight / 2);
        return Native.ToScreen(ctx.Window, pane, new Point(x, y));
    }

    // The cell's rectangle in the screen capture, in physical pixels.
    private (int X, int Y, int Width, int Height) CellOnScreen(int row, int column)
    {
        _grid.UpdateLayout();
        var pane = column < _grid.Columns.FrozenCount ? _grid.FrozenPane : _grid.ScrollingPane;
        var (x, y) = Native.ToScreen(ctx.Window, pane, new Point(_grid.Columns.PaneX(column), row * _grid.RowHeight));
        var scale = _grid.XamlRoot.RasterizationScale;
        return (x, y, (int)(_grid.Columns.Width(column) * scale), (int)(_grid.RowHeight * scale));
    }
}
