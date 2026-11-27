using TablePro.Editor.Input;
using TablePro.Editor.Model;
using TablePro.Editor.Rendering;
using TablePro.Graphics;
using TerraFX.Interop.DirectX;
using static TerraFX.Interop.DirectX.D2D1_ANTIALIAS_MODE;
using static TerraFX.Interop.DirectX.D2D1_DRAW_TEXT_OPTIONS;

namespace TablePro.Editor;

public sealed partial class SqlEditor
{
    // What a folded line shows after its text, as VS Code marks a fold.
    private const string FoldMark = "\u22EF";

    private readonly Dictionary<int, LineLayout> _frameLayouts = [];
    private readonly List<StyleRun> _runs = [];
    private readonly List<SyntaxSpan> _runSpans = [];
    private readonly List<(Windows.Foundation.Rect Box, int Line)> _chips = [];
    private long _frameVersion = -1;
    private bool _idleLexingQueued;
    private bool _waitingForTick;
    private bool _pointerInGutter;

    private unsafe void Render()
    {
        _renderQueued = false;
        if (_device is null || !_device.HasTarget || _layouts is null || _brushes is null || _disposed)
        {
            return;
        }
        // Another editor on this thread found the shared device lost, or the driver removed it.
        if (_device.NeedsRecovery)
        {
            RecoverDevice(lost: false);
            return;
        }
        if (!_device.TryBeginFrame())
        {
            RenderOnNextTick();
            return;
        }
        var started = Now();
        EnsureStructure();
        var lineHeight = _layouts.LineHeight;
        var width = (float)ViewWidth;
        var height = (float)ViewHeight;
        var rows = _model.Rows;
        var rowCount = rows.RowCount;
        var firstRow = Math.Clamp((int)(_scrollY / lineHeight), 0, rowCount - 1);
        var lastRow = Math.Clamp((int)((_scrollY + height) / lineHeight), firstRow, rowCount - 1);

        var lexStarted = Now();
        CollectTokens(firstRow, lastRow);
        var lexMilliseconds = Milliseconds(lexStarted, Now());

        _layouts.BeginFrame();
        _frameLayouts.Clear();
        _chips.Clear();
        _frameVersion = Document.Version;
        var context = _device.Context;
        var brushes = _brushes;
        var palette = brushes.Palette;
        context->BeginDraw();
        var identity = new D2D_MATRIX_3X2_F { _11 = 1, _22 = 1 };
        context->SetTransform(&identity);
        var background = Palette.ToD2D(palette.Background);
        context->Clear(&background);

        var gutter = GutterWidth;
        var textLeft = TextLeft;
        var selections = _model.Selections;
        var caretRows = new HashSet<int>();
        var caretLines = new HashSet<int>();
        foreach (var selection in selections)
        {
            var row = rows.RowOf(selection.Active);
            if (row >= firstRow && row <= lastRow)
            {
                caretRows.Add(row);
                caretLines.Add(Document.GetLineFromOffset(selection.Active));
            }
        }

        if (!palette.HighContrast)
        {
            foreach (var selection in selections)
            {
                var row = rows.RowOf(selection.Active);
                if (!selection.IsEmpty || row < firstRow || row > lastRow)
                {
                    continue;
                }
                var band = Rect(0, (float)(row * lineHeight - _scrollY), width, lineHeight);
                context->FillRectangle(&band, brushes.CurrentLine);
            }
        }

        DrawGutter(context, firstRow, lastRow, caretLines);

        var clip = Rect(gutter, 0, width - gutter, height);
        context->PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_ALIASED);
        var matches = FindMatchesIn(firstRow, lastRow);
        var statement = StatementBand();
        var brackets = BracketPair();
        var spanIndex = 0;
        var primary = _model.Primary.Active;
        var primaryRow = rows.RowOf(primary);
        // Vim's cursor, which in Visual mode can sit at the selection's start; -1 draws the carets as bars.
        var (blockCaret, blockEnd) = DrawsBlockCaret && _composition.Length == 0 ? _vim!.CursorCharacter : (-1, -1);
        _caretSpots.Clear();
        for (var row = firstRow; row <= lastRow; row++)
        {
            var (line, rowStart, rowEnd) = rows.RowSpan(row);
            var text = Document.GetText(rowStart, rowEnd - rowStart);
            while (spanIndex < _spans.Count && _spans[spanIndex].End <= rowStart)
            {
                spanIndex++;
            }
            CollectRuns(spanIndex, rowStart, rowEnd, selections, palette.HighContrast);
            var y = (float)(row * lineHeight - _scrollY);
            var originX = (float)(textLeft - _scrollX);
            var lastOfLine = rows.IsLastRowOfLine(row);

            var composing = _composition.Length > 0 && row == primaryRow;
            var compositionColumn = composing ? primary - rowStart : 0;
            LineLayout layout;
            if (composing)
            {
                var spliced = text.Insert(compositionColumn, _composition);
                ShiftRuns(compositionColumn, _composition.Length);
                layout = _layouts.Get(spliced, ListSpan(_runs), StyleKey(_runs) ^ (ulong)_composition.GetHashCode(), (float)_scrollX,
                    width - textLeft, brushes);
            }
            else
            {
                layout = _layouts.Get(text, ListSpan(_runs), StyleKey(_runs), (float)_scrollX, width - textLeft, brushes);
                _frameLayouts[row] = layout;
            }
            if (!_wordWrap)
            {
                _widest = Math.Max(_widest, layout.Width);
            }

            // Rows the statement runs on past are banded to the edge, as a selection over a line break reads.
            if (statement is { } band && band.End > rowStart && (band.Start < rowEnd || band.Start == rowStart)
                && !palette.HighContrast)
            {
                var x1 = band.Start > rowStart ? originX + layout.XAt(band.Start - rowStart) : clip.left;
                var x2 = band.End <= rowEnd ? originX + layout.XAt(band.End - rowStart) : width;
                if (x2 > x1)
                {
                    var box = Rect(x1, y, x2 - x1, lineHeight);
                    context->FillRectangle(&box, brushes.CurrentStatement);
                }
            }

            foreach (var (matchStart, matchLength) in matches)
            {
                var matchEnd = matchStart + matchLength;
                if (matchStart > rowEnd || (matchStart == rowEnd && !lastOfLine) || (matchEnd <= rowStart && matchLength > 0))
                {
                    continue;
                }
                var x1 = layout.XAt(Math.Max(matchStart, rowStart) - rowStart);
                var x2 = layout.XAt(Math.Min(matchEnd, rowEnd) - rowStart);
                var box = Rect(originX + x1, y, x2 - x1, lineHeight);
                context->FillRectangle(&box, brushes.FindMatch);
            }

            if (!composing)
            {
                foreach (var selection in selections)
                {
                    if (selection.IsEmpty || selection.End < rowStart || selection.Start > rowEnd)
                    {
                        continue;
                    }
                    var from = Math.Max(selection.Start, rowStart) - rowStart;
                    var to = Math.Min(selection.End, rowEnd) - rowStart;
                    var x1 = layout.XAt(from);
                    var x2 = layout.XAt(to);
                    // A selection that runs on past the row's end shows it as a little extra width.
                    if (selection.End > rowEnd)
                    {
                        x2 += _layouts.CharWidth / 2;
                    }
                    if (x2 > x1)
                    {
                        var box = Rect(originX + x1, y, x2 - x1, lineHeight);
                        context->FillRectangle(&box, brushes.Selection);
                    }
                }
            }

            if (brackets is { } pair)
            {
                foreach (var at in new[] { pair.Open, pair.Close })
                {
                    if (at >= rowStart && at < rowEnd)
                    {
                        var x1 = originX + layout.XAt(at - rowStart);
                        var x2 = originX + layout.XAt(at + 1 - rowStart);
                        var box = Rect(x1, y + 1, Math.Max(1, x2 - x1), lineHeight - 2);
                        context->FillRectangle(&box, brushes.BracketFill);
                        var edge = Rect(x1 + 0.5f, y + 1.5f, Math.Max(1, x2 - x1) - 1, lineHeight - 3);
                        context->DrawRectangle(&edge, brushes.BracketBorder, 1, null);
                    }
                }
            }

            context->DrawTextLayout(new D2D_POINT_2F(originX, y), layout.Layout, brushes.Text,
                D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);

            if (lastOfLine && rows.Folds.IsFolded(line))
            {
                DrawFoldChip(context, line, originX + layout.Width + _layouts.CharWidth / 2, y, lineHeight);
            }

            if (composing)
            {
                DrawCompositionMarks(context, layout, compositionColumn, originX, y, lineHeight);
            }

            if (blockCaret >= 0)
            {
                if (rows.RowOf(blockCaret) == row && blockCaret >= rowStart && blockCaret <= rowEnd)
                {
                    var column = blockCaret - rowStart;
                    var x1 = layout.XAt(column);
                    var next = Math.Min(rowEnd, blockEnd) - rowStart;
                    var x2 = next > column ? layout.XAt(next) : x1;
                    _caretSpots.Add(new CaretSpot(new System.Numerics.Vector2(originX + x1, y),
                        x2 > x1 ? x2 - x1 : _layouts.CharWidth));
                }
            }
            else if (caretRows.Contains(row))
            {
                foreach (var selection in selections)
                {
                    if (selection.Active < rowStart || selection.Active > rowEnd || rows.RowOf(selection.Active) != row)
                    {
                        continue;
                    }
                    var column = selection.Active - rowStart;
                    if (composing && selection.Active == primary)
                    {
                        column += _compositionCaret;
                    }
                    _caretSpots.Add(new CaretSpot(new System.Numerics.Vector2(originX + layout.XAt(column), y), 0));
                }
            }
        }
        context->PopAxisAlignedClip();

        var created = _layouts.CreatedThisFrame;
        if (!_device.EndDrawAndPresent())
        {
            RecoverDevice(lost: true);
            return;
        }
        _layouts.EndFrame();
        PlaceCarets(gutter, width, height, lineHeight);
        var presented = Now();
        FramePresented?.Invoke(this, new EditorFrame(presented, Milliseconds(started, presented), lexMilliseconds,
            Document.Version, rows.LineAtRow(firstRow), rows.LineAtRow(lastRow), created, _device.IsSoftware));
        ScheduleIdleLexing();
    }

    // Lexed by runs of lines that follow one another, so a fold's hidden lines are never lexed for the frame.
    private void CollectTokens(int firstRow, int lastRow)
    {
        _spans.Clear();
        if (_highlighter is null)
        {
            return;
        }
        var rows = _model.Rows;
        var runFirst = rows.LineAtRow(firstRow);
        var runLast = runFirst;
        for (var row = firstRow + 1; row <= lastRow + 1; row++)
        {
            var line = row <= lastRow ? rows.LineAtRow(row) : -1;
            if (line == runLast || line == runLast + 1)
            {
                runLast = line;
                continue;
            }
            _highlighter.GetTokens(runFirst, runLast, _runSpans);
            var lastStart = _spans.Count > 0 ? _spans[^1].Start : -1;
            foreach (var span in _runSpans)
            {
                // A token that runs on through a fold comes back with the next run too.
                if (span.Start > lastStart)
                {
                    _spans.Add(span);
                }
            }
            runFirst = line;
            runLast = line;
        }
    }

    private unsafe void DrawGutter(ID2D1DeviceContext* context, int firstRow, int lastRow, HashSet<int> caretLines)
    {
        var rows = _model.Rows;
        var lineHeight = _layouts!.LineHeight;
        var brushes = _brushes!;
        var numbersRight = NumbersRight;
        var regions = RegionsNow();
        var foldLeft = numbersRight + 4;
        var foldWidth = FoldColumnWidth;
        for (var row = firstRow; row <= lastRow; row++)
        {
            var (line, rowStart, _) = rows.RowSpan(row);
            if (rowStart != Document.GetLineStart(line))
            {
                continue;
            }
            var y = (float)(row * lineHeight - _scrollY);
            var number = _layouts.GutterNumber((line + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), numbersRight);
            context->DrawTextLayout(new D2D_POINT_2F(0, y), number, caretLines.Contains(line) ? brushes.Text : brushes.LineNumber,
                D2D1_DRAW_TEXT_OPTIONS_NONE);
            if (foldWidth <= 0)
            {
                continue;
            }
            var folded = rows.Folds.IsFolded(line);
            // A folded line keeps its chevron, so nothing hides without a way back; the rest show while the pointer is near.
            if (!folded && (!_pointerInGutter || FoldSet.FindStart(regions, line) is null))
            {
                continue;
            }
            DrawChevron(context, foldLeft, y, foldWidth, lineHeight, folded);
        }
    }

    // Right while folded and down while open, as a disclosure control points.
    private unsafe void DrawChevron(ID2D1DeviceContext* context, float left, float top, float width, float height, bool folded)
    {
        var size = MathF.Min(width, height) * 0.28f;
        var cx = left + width / 2;
        var cy = top + height / 2;
        D2D_POINT_2F a, b, c;
        if (folded)
        {
            a = new D2D_POINT_2F(cx - size / 2, cy - size);
            b = new D2D_POINT_2F(cx + size / 2, cy);
            c = new D2D_POINT_2F(cx - size / 2, cy + size);
        }
        else
        {
            a = new D2D_POINT_2F(cx - size, cy - size / 2);
            b = new D2D_POINT_2F(cx, cy + size / 2);
            c = new D2D_POINT_2F(cx + size, cy - size / 2);
        }
        var brush = folded ? _brushes!.Text : _brushes!.LineNumber;
        context->DrawLine(a, b, brush, 1.5f, null);
        context->DrawLine(b, c, brush, 1.5f, null);
    }

    // The chip after a folded line's text; a click on it opens the fold.
    private unsafe void DrawFoldChip(ID2D1DeviceContext* context, int line, float x, float y, float lineHeight)
    {
        var mark = _layouts!.Get(FoldMark, [], 0, 0, 1000, _brushes!);
        var markWidth = mark.Width;
        var padding = _layouts.CharWidth / 2;
        var box = Rect(x, y + lineHeight * 0.15f, markWidth + padding * 2, lineHeight * 0.7f);
        var rounded = new D2D1_ROUNDED_RECT { rect = box, radiusX = 3, radiusY = 3 };
        context->FillRoundedRectangle(&rounded, _brushes!.FoldChip);
        context->DrawTextLayout(new D2D_POINT_2F(x + padding, y), mark.Layout, _brushes.LineNumber, D2D1_DRAW_TEXT_OPTIONS_NONE);
        _chips.Add((new Windows.Foundation.Rect(box.left, y, box.right - box.left, lineHeight), line));
    }

    // Low priority, a few windows at a time, so input and frames go first.
    private void ScheduleIdleLexing()
    {
        if (_idleLexingQueued || _highlighter is null)
        {
            return;
        }
        _idleLexingQueued = true;
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            _idleLexingQueued = false;
            if (_highlighter?.AdvanceIdle(4) == true && !_disposed)
            {
                ScheduleIdleLexing();
            }
        });
    }

    // The last frame is still on its way to the screen; draw once the compositor ticks again.
    private void RenderOnNextTick()
    {
        if (_waitingForTick)
        {
            return;
        }
        _waitingForTick = true;
        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += OnRenderingTick;
    }

    private void OnRenderingTick(object? sender, object e)
    {
        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= OnRenderingTick;
        _waitingForTick = false;
        Invalidate();
    }

    // The frame's map points at layouts the cache owns, so it goes whenever they do.
    private void ForgetLayouts()
    {
        _layouts?.Clear();
        _frameLayouts.Clear();
        _frameVersion = -1;
    }

    private void ConfigureLayouts()
    {
        _layouts?.Configure(_fontFamily, _fontSize * _zoom, _model.Options.TabSize);
        _frameLayouts.Clear();
        _frameVersion = -1;
        UpdateWrap();
    }

    // The row as the last frame laid it out, else a plain layout of its text.
    private LineLayout LayoutFor(int row, int start, int end)
    {
        if (_frameVersion == Document.Version && _frameLayouts.TryGetValue(row, out var drawn))
        {
            return drawn;
        }
        return _layouts!.Get(Document.GetText(start, end - start), [], 0, (float)_scrollX, (float)(ViewWidth - TextLeft), _brushes!);
    }

    private void CollectRuns(int spanIndex, int rowStart, int rowEnd, IReadOnlyList<Selection> selections, bool highContrast)
    {
        _runs.Clear();
        for (var i = spanIndex; i < _spans.Count && _spans[i].Start < rowEnd; i++)
        {
            var span = _spans[i];
            var start = Math.Max(span.Start, rowStart);
            var end = Math.Min(span.End, rowEnd);
            if (end > start)
            {
                _runs.Add(new StyleRun(start - rowStart, end - start, span.Kind));
            }
        }
        if (!highContrast)
        {
            return;
        }
        // In high contrast the selected text itself changes color, so it is part of the row's style.
        foreach (var selection in selections)
        {
            var start = Math.Max(selection.Start, rowStart);
            var end = Math.Min(selection.End, rowEnd);
            if (!selection.IsEmpty && end > start)
            {
                _runs.Add(new StyleRun(start - rowStart, end - start, Rendering.Brushes.SelectedText));
            }
        }
    }

    private void ShiftRuns(int at, int by)
    {
        for (var i = 0; i < _runs.Count; i++)
        {
            var run = _runs[i];
            if (run.Start >= at)
            {
                _runs[i] = run with { Start = run.Start + by };
            }
            else if (run.Start + run.Length > at)
            {
                _runs[i] = run with { Length = run.Length + by };
            }
        }
    }

    private unsafe void DrawCompositionMarks(ID2D1DeviceContext* context, LineLayout layout, int column, float originX, float y,
        float lineHeight)
    {
        foreach (var run in _compositionRuns)
        {
            if (run.Underline == CompositionUnderline.None)
            {
                continue;
            }
            var x1 = originX + layout.XAt(column + run.Start);
            var x2 = originX + layout.XAt(column + run.Start + run.Length);
            var thickness = run.Bold ? 2f : 1f;
            var line = Rect(x1, y + lineHeight - thickness - 1, Math.Max(1, x2 - x1 - 1), thickness);
            context->FillRectangle(&line, _brushes!.Text);
        }
    }

    private List<(int Start, int Length)> FindMatchesIn(int firstRow, int lastRow)
    {
        if (_findBar is null || !_findBar.IsOpen || string.IsNullOrEmpty(_findBar.Query.Text))
        {
            return [];
        }
        // Range by range, so a fold between the rows on screen is never searched. A match that starts on a wrapped row
        // above the first one on screen still shows on it: plain text is never longer than the query, and a pattern is
        // matched from its line's start, where its anchors hold.
        var query = _findBar.Query;
        var matches = new List<(int Start, int Length)>();
        foreach (var (start, end) in RowRanges(firstRow, lastRow))
        {
            var lineStart = Document.GetLineStart(Document.GetLineFromOffset(start));
            var from = query.UseRegex ? lineStart : Math.Max(lineStart, start - query.Text.Length);
            foreach (var match in TextSearch.InRange(Document, query, from, end))
            {
                if (match.Start + match.Length > start || match.Start >= start)
                {
                    matches.Add(match);
                }
            }
        }
        return matches;
    }

    private static ulong StyleKey(List<StyleRun> runs)
    {
        var hash = 14695981039346656037UL;
        foreach (var run in runs)
        {
            hash = (hash ^ (uint)run.Start) * 1099511628211UL;
            hash = (hash ^ (uint)run.Length) * 1099511628211UL;
            hash = (hash ^ run.Kind) * 1099511628211UL;
        }
        return hash;
    }

    private static ReadOnlySpan<StyleRun> ListSpan(List<StyleRun> runs) => System.Runtime.InteropServices.CollectionsMarshal.AsSpan(runs);

    private static D2D_RECT_F Rect(float x, float y, float width, float height) => new()
    {
        left = x,
        top = y,
        right = x + width,
        bottom = y + height,
    };
}
