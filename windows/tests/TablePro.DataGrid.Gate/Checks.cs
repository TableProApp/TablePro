using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using TablePro.DataGrid.Model;
using Windows.UI;

namespace TablePro.DataGrid.Gate;

// Real input through SendInput, and what drawing the text ourselves owes that XAML gives a TextBlock.
internal sealed partial class Gate
{
    private async Task ChecksAsync()
    {
        await KeyboardAsync();
        await SelectionAsync();
        await LargeCopyAsync();
        await HeaderAsync();
        await UiaAsync();
        await ThemeAsync();
        await HighContrastAsync();
        await TextScaleAsync();
        await DpiAsync();
        await DeviceLossAsync();
        await ContentAsync();
    }

    private async Task KeyboardAsync()
    {
        _status.Text = "keyboard";
        _grid.ScrollTo(0, 0);
        _grid.SelectCell(0, 0, extend: false);
        _grid.Focus(FocusState.Programmatic);
        await Driver.EnsureForegroundAsync(ctx, _status);
        _grid.Focus(FocusState.Keyboard);
        await Task.Delay(500);
        _report.Line("keyboard.grid_focus_state", _grid.FocusState.ToString());

        var page = GridNavigation.PageRows(_grid.VisibleArea().Height, _grid.RowHeight);
        var last = _grid.RowCount - 1;
        var lastColumn = _grid.ColumnCount - 1;
        var steps = new List<(string Name, Action Send, int Row, int Column)>();
        for (var i = 1; i <= 12; i++)
        {
            steps.Add(("Down", () => Native.Press(Native.VkDown), i, 0));
        }
        for (var i = 1; i <= 15; i++)
        {
            steps.Add(("Right", () => Native.Press(Native.VkRight), 12, i));
        }
        for (var i = 1; i <= 5; i++)
        {
            steps.Add(("PageDown", () => Native.Press(Native.VkNext), 12 + (i * page), 15));
        }
        for (var i = 1; i <= 2; i++)
        {
            steps.Add(("PageUp", () => Native.Press(Native.VkPrior), 12 + ((5 - i) * page), 15));
        }
        var row = 12 + (3 * page);
        steps.Add(("Up", () => Native.Press(Native.VkUp), row - 1, 15));
        steps.Add(("Left", () => Native.Press(Native.VkLeft), row - 1, 14));
        steps.Add(("End", () => Native.Press(Native.VkEnd), row - 1, lastColumn));
        steps.Add(("Home", () => Native.Press(Native.VkHome), row - 1, 0));
        steps.Add(("Ctrl+End", () => Native.Chord(Native.VkControl, Native.VkEnd), last, lastColumn));
        steps.Add(("Up", () => Native.Press(Native.VkUp), last - 1, lastColumn));
        steps.Add(("Ctrl+Home", () => Native.Chord(Native.VkControl, Native.VkHome), 0, 0));

        var latencies = new List<double>();
        var results = new JsonArray();
        int wrong = 0, hidden = 0, timeouts = 0, resent = 0;
        foreach (var (name, send, targetRow, targetColumn) in steps)
        {
            var changed = new TaskCompletionSource<long>();
            void Handler(object? sender, EventArgs e) => changed.TrySetResult(Clock.Now());
            _grid.FocusedCellChanged += Handler;
            var t0 = Clock.Now();
            send();
            var done = await Task.WhenAny(changed.Task, Task.Delay(3000));
            // The Arm64 image's shell takes the foreground now and then, and a press sent meanwhile goes to it.
            if (done != changed.Task)
            {
                results.Add($"{name}: lost with foreground={Native.IsForeground(ctx.Window)} focus={_grid.FocusState}, sent again");
                await Driver.EnsureForegroundAsync(ctx, _status);
                _grid.Focus(FocusState.Keyboard);
                resent++;
                t0 = Clock.Now();
                send();
                done = await Task.WhenAny(changed.Task, Task.Delay(3000));
            }
            _grid.FocusedCellChanged -= Handler;
            if (done != changed.Task)
            {
                timeouts++;
                results.Add($"{name}: timeout at ({_grid.FocusedRow},{_grid.FocusedColumn}) foreground={Native.IsForeground(ctx.Window)}");
                continue;
            }
            var frame = await Frames.NextAsync();
            latencies.Add(Clock.Ms(t0, frame));
            await Frames.NextAsync();
            var ok = _grid.FocusedRow == targetRow && _grid.FocusedColumn == targetColumn;
            var visible = IsFullyVisible(_grid.FocusedRow, _grid.FocusedColumn);
            wrong += ok ? 0 : 1;
            hidden += visible ? 0 : 1;
            results.Add($"{name}: ({_grid.FocusedRow},{_grid.FocusedColumn}) expected ({targetRow},{targetColumn}) ok={ok} visible={visible} ms={latencies[^1]:F1}");
            await Task.Delay(80);
        }
        _report.Line("keyboard.steps", results);
        _report.Stats("keyboard.input_to_frame_ms", latencies);
        _report.Line("keyboard.summary", $"steps={steps.Count} wrong_cell={wrong} not_visible={hidden} timeouts={timeouts} page={page} resent_after_losing_foreground={resent}");

        Native.Down(Native.VkShift);
        Native.Press(Native.VkDown);
        Native.Press(Native.VkRight);
        Native.Up(Native.VkShift);
        await Task.Delay(400);
        _report.Line("keyboard.shift_extend", $"selection={_grid.SelectionRange} ok={_grid.SelectionRange == new CellRange(0, 0, 1, 1)}");
        await SendAsync("ctrl_a", () => Native.Chord(Native.VkControl, (ushort)'A'), () => _grid.SelectionKind == SelectionKind.All, 3000);
        _report.Line("keyboard.ctrl_a", $"kind={_grid.SelectionKind} range={_grid.SelectionRange} ok={_grid.SelectionKind == SelectionKind.All}");
        await Native.SaveScreenAsync(ctx.Shot("keyboard-ctrl-a"));
    }

    // From the drawn row's real position, not from the model.
    private bool IsFullyVisible(int row, int column)
    {
        _grid.UpdateLayout();
        if (!_grid.RealizedRows.TryGetValue(row, out var element) || ((DrawnRow)element).DrawnRowIndex != row)
        {
            return false;
        }
        var frozen = column < _grid.Columns.FrozenCount;
        if (!frozen && !((DrawnRow)element).TryGetDrawn(column, out _, out _))
        {
            return false;
        }
        var pane = frozen ? _grid.FrozenPane : _grid.ScrollingPane;
        var cell = pane.TransformToVisual(_grid.Scroller).TransformBounds(new Windows.Foundation.Rect(
            _grid.Columns.PaneX(column), row * _grid.RowHeight, _grid.Columns.Width(column), _grid.RowHeight));
        var (left, top) = _grid.Insets;
        var right = _grid.Scroller.ViewportWidth;
        var bottom = _grid.Scroller.ViewportHeight;
        return (frozen || cell.Left >= left - 0.5) && cell.Right <= right + 0.5 && cell.Top >= top - 0.5 && cell.Bottom <= bottom + 0.5;
    }

    private async Task SelectionAsync()
    {
        _status.Text = "selection";
        _grid.ScrollTo(140 * 10, _grid.RowHeight * 1000);
        await Task.Delay(500);
        var view = _grid.VisibleArea();
        var row = (int)(view.Top / _grid.RowHeight) + 2;
        var column = _grid.Columns.ScrollColumnAt(view.Left) + 1;
        await Driver.EnsureForegroundAsync(ctx, _status);

        var (cx, cy) = CellCenterOnScreen(row, column);
        Native.Click(cx, cy);
        await Task.Delay(400);
        var single = _grid.FocusedRow == row && _grid.FocusedColumn == column && _grid.SelectionRange == new CellRange(row, column, row, column);
        _report.Line("selection.click", $"target=({row},{column}) focused=({_grid.FocusedRow},{_grid.FocusedColumn}) single={single} focus={_grid.FocusState}");

        var (sx, sy) = CellCenterOnScreen(row + 3, column + 2);
        Native.Down(Native.VkShift);
        await Task.Delay(150);
        Native.Click(sx, sy);
        await Task.Delay(150);
        Native.Up(Native.VkShift);
        await Task.Delay(400);
        var expectedRange = new CellRange(row, column, row + 3, column + 2);
        _report.Line("selection.shift_click", $"selection={_grid.SelectionRange} expected={expectedRange} ok={_grid.SelectionRange == expectedRange}");
        await Native.SaveScreenAsync(ctx.Shot("shift-range"));

        var copies = _grid.Copies;
        await SendAsync("ctrl_c", () => Native.Chord(Native.VkControl, (ushort)'C'), () => _grid.Copies > copies, 10_000);
        var clip = await ClipboardTextAsync();
        var expected = ExpectedTsv(expectedRange);
        _report.Line("selection.ctrl_c", $"tsv_matches={clip == expected} lines={clip.Split("\r\n").Length - 1} tabs_in_first_line={clip.Split("\r\n")[0].Count(ch => ch == '\t')}");
        _report.Line("selection.clipboard_text", clip.Length > 600 ? clip[..600] : clip);

        var frozenColumn = 0;
        var (fx, fy) = CellCenterOnScreen(row + 1, frozenColumn);
        Native.Click(fx, fy);
        await Task.Delay(400);
        _report.Line("selection.frozen_click", $"focused=({_grid.FocusedRow},{_grid.FocusedColumn}) ok={_grid.FocusedRow == row + 1 && _grid.FocusedColumn == frozenColumn}");
    }

    // A selection far larger than the screen copies from the model, off the UI thread.
    private async Task LargeCopyAsync()
    {
        _status.Text = "large copy";
        const int Rows = 2000;
        const int Columns = 40;
        var first = 250_000;
        _grid.SelectCell(first, 0, extend: false);
        _grid.SelectCell(first + Rows - 1, Columns - 1, extend: true);
        await Task.Delay(300);
        using var heartbeat = new Heartbeat(ctx.Window.DispatcherQueue);
        await Task.Delay(100);
        heartbeat.Take();
        var copies = _grid.Copies;
        var t = Clock.Now();
        var finished = await SendAsync("large_ctrl_c", () => Native.Chord(Native.VkControl, (ushort)'C'), () => _grid.Copies > copies, 120_000);
        var ms = Clock.MsSince(t);
        var block = heartbeat.Take();
        var clip = await ClipboardTextAsync();
        var expected = ExpectedTsv(_grid.SelectionRange);
        _report.Line("large_copy.summary", string.Create(CultureInfo.InvariantCulture,
            $"cells={(long)Rows * Columns} finished={finished} ms={ms:F0} chars={clip.Length} lines={clip.Split("\r\n").Length - 1} matches={clip == expected}"));
        _report.Stats("large_copy.heartbeat_wait_ms", block);
    }

    // Real pointer input on the header: a drag on a column's right edge, a double-click there, a click to sort.
    private async Task HeaderAsync()
    {
        _status.Text = "header";
        _grid.ScrollTo(0, 0);
        await Task.Delay(400);
        await Driver.EnsureForegroundAsync(ctx, _status);
        var column = _grid.ColumnWindow.First + 1;
        var header = _grid.HeaderCell(column)!;
        var before = _grid.Columns.Width(column);
        var (x, y) = Native.ToScreen(ctx.Window, header, new Windows.Foundation.Point(header.ActualWidth - 3, header.ActualHeight / 2));
        Native.MoveTo(x, y);
        await Task.Delay(150);
        Native.LeftDown(x, y);
        for (var step = 1; step <= 6; step++)
        {
            await Task.Delay(40);
            Native.MoveTo(x + (step * 10), y);
        }
        await Task.Delay(80);
        Native.LeftUp(x + 60, y);
        await Task.Delay(400);
        var dragged = _grid.Columns.Width(column);
        _report.Line("header.resize_drag", string.Create(CultureInfo.InvariantCulture,
            $"column={column} before={before} after={dragged} ok={Math.Abs(dragged - before - 60) <= 2}"));
        await Native.SaveScreenAsync(ctx.Shot("header-resized"));

        var fitColumn = column + 1;
        var fitHeader = _grid.HeaderCell(fitColumn)!;
        var (fx, fy) = Native.ToScreen(ctx.Window, fitHeader, new Windows.Foundation.Point(fitHeader.ActualWidth - 3, fitHeader.ActualHeight / 2));
        var widest = 0.0;
        for (var row = _grid.RowWindow.First; row <= _grid.RowWindow.Last; row++)
        {
            var cell = _grid.Cell(row, fitColumn);
            widest = Math.Max(widest, cell.IsNull ? _grid.Painter.Measure("NULL", placeholder: true) : _grid.Painter.Measure(cell.Text));
        }
        Native.Click(fx, fy);
        Native.Click(fx, fy);
        await Task.Delay(500);
        var fitted = _grid.Columns.Width(fitColumn);
        _report.Line("header.fit_double_click", string.Create(CultureInfo.InvariantCulture,
            $"column={fitColumn} width={fitted} widest_text={widest:F1} ok={fitted >= widest + 24 && fitted <= Math.Max(widest, 24) + 40}"));

        var sortHeader = _grid.HeaderCell(column)!;
        var requested = new List<Model.GridSort>();
        void OnSort(object? sender, Model.GridSort sort) => requested.Add(sort);
        _grid.SortRequested += OnSort;
        var (sx, sy) = Native.ToScreen(ctx.Window, sortHeader, new Windows.Foundation.Point(20, sortHeader.ActualHeight / 2));
        Native.Click(sx, sy);
        await Task.Delay(900);
        Native.Click(sx, sy);
        await Task.Delay(900);
        _grid.SortRequested -= OnSort;
        _report.Line("header.sort_clicks", $"requests={string.Join(' ', requested)} indicator={_grid.HeaderCell(column)?.SortDirection} " +
            $"ok={requested.Count == 2 && requested[0].Direction == Model.SortDirection.Ascending && requested[1].Direction == Model.SortDirection.Descending}");
        await Native.SaveScreenAsync(ctx.Shot("header-sorted"));
    }

    private async Task UiaAsync()
    {
        _status.Text = "uia";
        _grid.ScrollTo(0, 0);
        _grid.SelectCell(2, 3, extend: false);
        _grid.Focus(FocusState.Programmatic);
        await Task.Delay(500);
        await Driver.RequestAsync(ctx, "uia-" + ctx.Name);
        _grid.SelectCell(10, 0, extend: false);
        _grid.SelectCell(5000, 30, extend: true);
        await Task.Delay(300);
        await Driver.RequestAsync(ctx, "uia-" + ctx.Name + "-large");
    }

    private async Task ThemeAsync()
    {
        _status.Text = "theme";
        _grid.ScrollTo(140 * 3, _grid.RowHeight * 500_000);
        await Task.Delay(300);
        _grid.SelectCell(500_002, 4, extend: false);
        _grid.SelectCell(500_006, 7, extend: true);
        await Task.Delay(600);
        await Native.SaveScreenAsync(ctx.Shot("selection-light"));
        _report.Line("light.text", _grid.Painter.Colors.Text.ToString());
        _root.RequestedTheme = ElementTheme.Dark;
        await Task.Delay(800);
        await Native.SaveScreenAsync(ctx.Shot("selection-dark"));
        _report.Line("dark.text", _grid.Painter.Colors.Text.ToString());
        _report.Line("dark.verify", await VerifyNowAsync());
        _root.RequestedTheme = ElementTheme.Light;
        await Task.Delay(500);
        _report.Line("theme.back_to_light", _grid.Painter.Colors.Text.ToString());
    }

    private async Task HighContrastAsync()
    {
        _status.Text = "high contrast";
        var on = Native.SetHighContrast(true);
        var changed = await WaitAsync(() => _grid.Painter.Colors.HighContrast, 15_000);
        await Task.Delay(800);
        var colors = _grid.Painter.Colors;
        _report.Line("high_contrast.on", $"set={on} grid_followed={changed} text={colors.Text} selection={colors.Selection} selected_text={colors.SelectedText} background={colors.Background}");
        _report.Line("high_contrast.verify", await VerifyNowAsync());
        await Native.SaveScreenAsync(ctx.Shot("high-contrast"));
        var (x, y, w, h) = CellOnScreen(500_003, 5);
        var screen = await Task.Run(Native.CaptureScreen);
        var selectedInk = Analyze(screen, (x, y, w, h), colors.Selection);
        _report.Line("high_contrast.selected_cell", $"ink={selectedInk.Ink} ink_color={selectedInk.InkColor} expected={colors.SelectedText} fill_matches={selectedInk.BackgroundShare:F2}");
        Native.SetHighContrast(false);
        var back = await WaitAsync(() => !_grid.Painter.Colors.HighContrast, 15_000);
        await Task.Delay(800);
        _report.Line("high_contrast.off", $"grid_followed={back} text={_grid.Painter.Colors.Text}");
    }

    private async Task TextScaleAsync()
    {
        _status.Text = "text scale";
        var before = (_grid.RowHeight, _grid.Painter.FontSize);
        _grid.ApplyTextScale(1.5);
        await Frames.SkipAsync(3);
        var verify = await VerifyNowAsync();
        _report.Line("text_scale.1_5", $"row_height={_grid.RowHeight} font={_grid.Painter.FontSize} header={_grid.HeaderHeight} before={before} verify={verify.ToJsonString()}");
        await Native.SaveScreenAsync(ctx.Shot("text-scale-150"));
        _grid.ApplyTextScale(1.0);
        await Frames.SkipAsync(3);
        _report.Line("text_scale.back", $"row_height={_grid.RowHeight} font={_grid.Painter.FontSize} verify={(await VerifyNowAsync()).ToJsonString()}");
    }

    // A real change of the display's scale where Windows allows one; otherwise the grid's own path for it.
    private async Task DpiAsync()
    {
        _status.Text = "dpi";
        var before = _grid.XamlRoot.RasterizationScale;
        var set = DisplayScale.TrySet(150, out var detail);
        var changed = set && await WaitAsync(() => Math.Abs(_grid.XamlRoot.RasterizationScale - before) > 0.01, 10_000);
        if (!changed)
        {
            _grid.ApplyRasterizationScale(1.5);
        }
        await Frames.SkipAsync(5);
        var row = _grid.RealizedRows.Values.Cast<DrawnRow>().FirstOrDefault();
        var pixels = row?.SurfacePixels ?? default;
        var expectedHeight = (int)Math.Ceiling(_grid.RowHeight * _grid.RenderScale);
        _report.Line("dpi.change", string.Create(CultureInfo.InvariantCulture,
            $"real={changed} set={set} detail='{detail}' raster_before={before} raster_now={_grid.XamlRoot.RasterizationScale} grid_scale={_grid.RenderScale} surface_height={pixels.Height} expected_at_least={expectedHeight} surfaces_ok={pixels.Height >= expectedHeight}"));
        _report.Line("dpi.verify", await VerifyNowAsync());
        await Native.SaveScreenAsync(ctx.Shot("dpi-150"));
        if (changed)
        {
            DisplayScale.TrySet(100, out _);
            await WaitAsync(() => Math.Abs(_grid.XamlRoot.RasterizationScale - before) < 0.01, 10_000);
        }
        else
        {
            _grid.ApplyRasterizationScale(before);
        }
        await Frames.SkipAsync(5);
    }

    private async Task DeviceLossAsync()
    {
        _status.Text = "device loss";
        var lost = DataGridView.DevicesLost;
        _grid.SimulateDeviceLoss();
        await Frames.SkipAsync(8);
        _report.Line("device_loss", $"devices_lost={DataGridView.DevicesLost - lost} verify={(await VerifyNowAsync()).ToJsonString()}");
        await Native.SaveScreenAsync(ctx.Shot("after-device-loss"));
    }

    private async Task ContentAsync()
    {
        _status.Text = "content";
        var (run, set, data) = await _bench.QueryAsync(BenchData.ContentQuery, 10);
        _grid.FrozenColumnCount = 0;
        _grid.SetData(data);
        for (var column = 0; column < data.ColumnCount; column++)
        {
            _grid.ResizeColumn(column, 220);
        }
        _grid.SelectCell(0, 6, extend: false);
        await Frames.SkipAsync(5);
        await Task.Delay(600);
        await Native.SaveScreenAsync(ctx.Shot("content"));
        var screen = await Task.Run(Native.CaptureScreen);
        var background = _grid.Painter.Colors.Background;
        var rtl = Analyze(screen, CellOnScreen(0, 0), background);
        var hebrew = Analyze(screen, CellOnScreen(0, 1), background);
        var emoji = Analyze(screen, CellOnScreen(0, 2), background);
        var nothing = Analyze(screen, CellOnScreen(0, 3), background);
        var cut = _grid.Cell(0, 4);
        _report.Line("content.rtl", $"centroid={rtl.Centroid:F2} right_aligned={rtl.Centroid > 0.5} ink={rtl.Ink} state={_grid.Cell(0, 0).State}");
        _report.Line("content.hebrew", $"centroid={hebrew.Centroid:F2} right_aligned={hebrew.Centroid > 0.5}");
        _report.Line("content.emoji", $"colored_pixels={emoji.Colored} in_color={emoji.Colored > 20}");
        _report.Line("content.null", $"ink={nothing.Ink} ink_color={nothing.InkColor} placeholder={_grid.Painter.Colors.Placeholder} text={_grid.Painter.Colors.Text} drawn={nothing.Ink > 0}");
        _report.Line("content.cut", $"state={cut.State} length={cut.Text.Length} ends_with_mark={cut.Text.Length > 0 && cut.Text[^1] == CellBlock.Ellipsis} cut_mark={_grid.Painter.Colors.CutMark}");
        _grid.SelectCell(0, 5, extend: false);
        await _grid.CopySelectionAsync();
        var clip = await ClipboardTextAsync();
        _report.Line("content.two_lines_copy", $"shown='{_grid.CellName(0, 5)}' copied_ok={clip == "\"line one\nline two\"\r\n"}");
        _grid.SetData(null);
        set.Dispose();
        run.Dispose();
    }

    private async Task<JsonObject> VerifyNowAsync()
    {
        _grid.UpdateLayout();
        await Frames.NextAsync();
        var verify = new Verifier(this);
        verify.Check(afterFrame: true);
        return verify.Summary();
    }

    // A press the runner's shell took is sent once more after the window has the foreground and the grid the focus.
    private async Task<bool> SendAsync(string name, Action send, Func<bool> done, int milliseconds)
    {
        send();
        if (await WaitAsync(done, Math.Min(milliseconds, 3000)))
        {
            return true;
        }
        _report.Line(name + ".resent", $"foreground={Native.IsForeground(ctx.Window)} focus={_grid.FocusState}");
        await Driver.EnsureForegroundAsync(ctx, _status);
        _grid.Focus(FocusState.Keyboard);
        send();
        return await WaitAsync(done, milliseconds);
    }

    private static async Task<bool> WaitAsync(Func<bool> condition, int milliseconds)
    {
        var sw = Stopwatch.StartNew();
        while (!condition())
        {
            if (sw.ElapsedMilliseconds > milliseconds)
            {
                return false;
            }
            await Task.Delay(50);
        }
        return true;
    }

    // Centroid runs from 0 at the cell's left edge to 1 at its right.
    private static (int Ink, int Colored, double Centroid, Color InkColor, double BackgroundShare) Analyze(
        (int Width, int Height, byte[] Bgra) screen, (int X, int Y, int Width, int Height) cell, Color background)
    {
        int ink = 0, colored = 0, total = 0, plain = 0;
        double sumX = 0;
        long r = 0, g = 0, b = 0;
        for (var y = cell.Y + 3; y < cell.Y + cell.Height - 3; y++)
        {
            for (var x = cell.X + 3; x < cell.X + cell.Width - 3; x++)
            {
                if (x < 0 || y < 0 || x >= screen.Width || y >= screen.Height)
                {
                    continue;
                }
                var i = ((y * screen.Width) + x) * 4;
                int pb = screen.Bgra[i], pg = screen.Bgra[i + 1], pr = screen.Bgra[i + 2];
                total++;
                var distance = Math.Abs(pr - background.R) + Math.Abs(pg - background.G) + Math.Abs(pb - background.B);
                if (distance < 30)
                {
                    plain++;
                    continue;
                }
                ink++;
                sumX += (x - cell.X) / (double)cell.Width;
                r += pr;
                g += pg;
                b += pb;
                if (Math.Max(pr, Math.Max(pg, pb)) - Math.Min(pr, Math.Min(pg, pb)) > 60)
                {
                    colored++;
                }
            }
        }
        var inkColor = ink == 0 ? default : Color.FromArgb(255, (byte)(r / ink), (byte)(g / ink), (byte)(b / ink));
        return (ink, colored, ink == 0 ? 0 : sumX / ink, inkColor, total == 0 ? 0 : plain / (double)total);
    }
}

// Settings' per-source DPI call, absent from the SDK; request numbers from SetDPI (MIT, github.com/imniko/SetDPI).
internal static partial class DisplayScale
{
    private static readonly int[] Scales = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];

    public static bool TrySet(int percent, out string detail)
    {
        try
        {
            if (GetDisplayConfigBufferSizes(2, out var pathCount, out var modeCount) != 0)
            {
                detail = "buffer sizes failed";
                return false;
            }
            var paths = new PathInfo[pathCount];
            var modes = new ModeInfo[modeCount];
            if (QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0 || pathCount == 0)
            {
                detail = "query failed";
                return false;
            }
            var get = new DpiGet
            {
                Header = new DeviceInfoHeader { Type = -3, Size = (uint)Marshal.SizeOf<DpiGet>(), AdapterId = paths[0].Source.AdapterId, Id = paths[0].Source.Id },
            };
            if (DisplayConfigGetDeviceInfo(ref get) != 0)
            {
                detail = "get dpi failed";
                return false;
            }
            var recommended = Math.Abs(get.Min);
            var target = Array.IndexOf(Scales, percent);
            var set = new DpiSet
            {
                Header = new DeviceInfoHeader { Type = -4, Size = (uint)Marshal.SizeOf<DpiSet>(), AdapterId = paths[0].Source.AdapterId, Id = paths[0].Source.Id },
                ScaleRel = target - recommended,
            };
            var result = DisplayConfigSetDeviceInfo(ref set);
            detail = string.Create(CultureInfo.InvariantCulture,
                $"min={get.Min} current={get.Current} max={get.Max} recommended={Scales[Math.Min(recommended, Scales.Length - 1)]} result={result}");
            return result == 0;
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            detail = ex.Message;
            return false;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Luid
    {
        public uint Low;
        public int High;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SourceInfo
    {
        public Luid AdapterId;
        public uint Id;
        public uint ModeInfoIdx;
        public uint StatusFlags;
    }

    [StructLayout(LayoutKind.Sequential, Size = 48)]
    private struct TargetInfo
    {
        public Luid AdapterId;
        public uint Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PathInfo
    {
        public SourceInfo Source;
        public TargetInfo Target;
        public uint Flags;
    }

    [StructLayout(LayoutKind.Sequential, Size = 64)]
    private struct ModeInfo
    {
        public int InfoType;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DeviceInfoHeader
    {
        public int Type;
        public uint Size;
        public Luid AdapterId;
        public uint Id;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DpiGet
    {
        public DeviceInfoHeader Header;
        public int Min;
        public int Current;
        public int Max;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DpiSet
    {
        public DeviceInfoHeader Header;
        public int ScaleRel;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] PathInfo[] paths, ref uint modeCount,
        [Out] ModeInfo[] modes, IntPtr topology);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DpiGet request);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigSetDeviceInfo(ref DpiSet request);
}
