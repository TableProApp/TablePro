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
    private readonly Dictionary<int, LineLayout> _frameLayouts = [];
    private readonly List<StyleRun> _runs = [];
    private long _frameVersion = -1;
    private bool _idleLexingQueued;
    private bool _waitingForTick;

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
        var lineHeight = _layouts.LineHeight;
        var width = (float)ViewWidth;
        var height = (float)ViewHeight;
        var lineCount = Document.LineCount;
        var first = Math.Clamp((int)(_scrollY / lineHeight), 0, lineCount - 1);
        var last = Math.Clamp((int)((_scrollY + height) / lineHeight), first, lineCount - 1);

        var lexStarted = Now();
        if (_highlighter is not null)
        {
            _highlighter.GetTokens(first, last, _spans);
        }
        else
        {
            _spans.Clear();
        }
        var lexMilliseconds = Milliseconds(lexStarted, Now());

        _layouts.BeginFrame();
        _frameLayouts.Clear();
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
        var caretLines = new HashSet<int>();
        foreach (var selection in selections)
        {
            var activeLine = Document.GetLineFromOffset(selection.Active);
            if (activeLine >= first && activeLine <= last)
            {
                caretLines.Add(activeLine);
            }
        }

        if (!palette.HighContrast)
        {
            foreach (var selection in selections)
            {
                if (!selection.IsEmpty)
                {
                    continue;
                }
                var line = Document.GetLineFromOffset(selection.Active);
                if (line < first || line > last)
                {
                    continue;
                }
                var band = Rect(0, (float)(line * lineHeight - _scrollY), width, lineHeight);
                context->FillRectangle(&band, brushes.CurrentLine);
            }
        }

        var numberWidth = gutter - GutterPadding;
        for (var line = first; line <= last; line++)
        {
            var number = _layouts.GutterNumber((line + 1).ToString(System.Globalization.CultureInfo.InvariantCulture), numberWidth);
            var origin = new D2D_POINT_2F(0, (float)(line * lineHeight - _scrollY));
            context->DrawTextLayout(origin, number, caretLines.Contains(line) ? brushes.Text : brushes.LineNumber,
                D2D1_DRAW_TEXT_OPTIONS_NONE);
        }

        var clip = Rect(gutter, 0, width - gutter, height);
        context->PushAxisAlignedClip(&clip, D2D1_ANTIALIAS_MODE_ALIASED);
        var matches = FindMatchesIn(first, last);
        var spanIndex = 0;
        var primaryLine = Document.GetLineFromOffset(_model.Primary.Active);
        _caretSpots.Clear();
        for (var line = first; line <= last; line++)
        {
            var lineStart = Document.GetLineStart(line);
            var lineEnd = Document.GetLineEnd(line);
            var text = Document.GetText(lineStart, lineEnd - lineStart);
            while (spanIndex < _spans.Count && _spans[spanIndex].End <= lineStart)
            {
                spanIndex++;
            }
            CollectRuns(spanIndex, lineStart, lineEnd, selections, palette.HighContrast);
            var y = (float)(line * lineHeight - _scrollY);
            var originX = (float)(textLeft - _scrollX);

            var composing = _composition.Length > 0 && line == primaryLine;
            var compositionColumn = composing ? _model.Primary.Active - lineStart : 0;
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
                _frameLayouts[line] = layout;
            }
            _widest = Math.Max(_widest, layout.Width);

            foreach (var (matchStart, matchLength) in matches)
            {
                if (matchStart >= lineStart && matchStart <= lineEnd)
                {
                    var x1 = layout.XAt(matchStart - lineStart);
                    var x2 = layout.XAt(Math.Min(matchStart + matchLength, lineEnd) - lineStart);
                    var box = Rect(originX + x1, y, x2 - x1, lineHeight);
                    context->FillRectangle(&box, brushes.FindMatch);
                }
            }

            if (!composing)
            {
                foreach (var selection in selections)
                {
                    if (selection.IsEmpty || selection.End < lineStart || selection.Start > lineEnd)
                    {
                        continue;
                    }
                    var from = Math.Max(selection.Start, lineStart) - lineStart;
                    var to = Math.Min(selection.End, lineEnd) - lineStart;
                    var x1 = layout.XAt(from);
                    var x2 = layout.XAt(to);
                    // A selection that runs on past the line break shows it as a little extra width.
                    if (selection.End > lineEnd)
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

            context->DrawTextLayout(new D2D_POINT_2F(originX, y), layout.Layout, brushes.Text,
                D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);

            if (composing)
            {
                DrawCompositionMarks(context, layout, compositionColumn, originX, y, lineHeight);
            }

            foreach (var selection in selections)
            {
                if (selection.Active < lineStart || selection.Active > lineEnd)
                {
                    continue;
                }
                var column = selection.Active - lineStart;
                if (composing && selection.Active == _model.Primary.Active)
                {
                    column += _compositionCaret;
                }
                _caretSpots.Add(new System.Numerics.Vector2(originX + layout.XAt(column), y));
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
            Document.Version, first, last, created, _device.IsSoftware));
        ScheduleIdleLexing();
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
        _layouts?.Configure(_fontSize * _zoom, _model.Options.TabSize);
        _frameLayouts.Clear();
        _frameVersion = -1;
    }

    private LineLayout LayoutFor(int line, string text)
    {
        if (_frameVersion == Document.Version && _frameLayouts.TryGetValue(line, out var drawn))
        {
            return drawn;
        }
        return _layouts!.Get(text, [], 0, (float)_scrollX, (float)(ViewWidth - TextLeft), _brushes!);
    }

    private string LineText(int line)
    {
        var start = Document.GetLineStart(line);
        return Document.GetText(start, Document.GetLineEnd(line) - start);
    }

    private void CollectRuns(int spanIndex, int lineStart, int lineEnd, IReadOnlyList<Selection> selections, bool highContrast)
    {
        _runs.Clear();
        for (var i = spanIndex; i < _spans.Count && _spans[i].Start < lineEnd; i++)
        {
            var span = _spans[i];
            var start = Math.Max(span.Start, lineStart);
            var end = Math.Min(span.End, lineEnd);
            if (end > start)
            {
                _runs.Add(new StyleRun(start - lineStart, end - start, span.Kind));
            }
        }
        if (!highContrast)
        {
            return;
        }
        // In high contrast the selected text itself changes color, so it is part of the line's style.
        foreach (var selection in selections)
        {
            var start = Math.Max(selection.Start, lineStart);
            var end = Math.Min(selection.End, lineEnd);
            if (!selection.IsEmpty && end > start)
            {
                _runs.Add(new StyleRun(start - lineStart, end - start, Rendering.Brushes.SelectedText));
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

    private List<(int Start, int Length)> FindMatchesIn(int first, int last)
    {
        if (_findBar is null || !_findBar.IsOpen || string.IsNullOrEmpty(_findBar.Query.Text))
        {
            return [];
        }
        return TextSearch.InRange(Document, _findBar.Query, Document.GetLineStart(first), Document.GetLineEnd(last));
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
