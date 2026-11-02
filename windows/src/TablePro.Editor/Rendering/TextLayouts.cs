using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STRETCH;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_WEIGHT;
using static TerraFX.Interop.DirectX.DWRITE_LINE_SPACING_METHOD;
using static TerraFX.Interop.DirectX.DWRITE_TEXT_ALIGNMENT;
using static TerraFX.Interop.DirectX.DWRITE_WORD_WRAPPING;

namespace TablePro.Editor.Rendering;

// One laid-out line, or a slice of a very long one. Columns in it count from SegmentStart.
internal sealed unsafe class LineLayout
{
    public IDWriteTextLayout* Layout;
    public int SegmentStart;
    public int Length;
    public float OriginX;
    public long LastFrame;

    public float XAt(int column)
    {
        var local = Math.Clamp(column - SegmentStart, 0, Length);
        float x, y;
        DWRITE_HIT_TEST_METRICS metrics;
        Layout->HitTestTextPosition((uint)local, BOOL.FALSE, &x, &y, &metrics);
        return OriginX + x;
    }

    // The column under x, rounding to the nearer side of the character.
    public int ColumnAt(float x)
    {
        BOOL trailing, inside;
        DWRITE_HIT_TEST_METRICS metrics;
        Layout->HitTestPoint(x - OriginX, 1, &trailing, &inside, &metrics);
        var column = (int)metrics.textPosition + (trailing ? (int)metrics.length : 0);
        return SegmentStart + Math.Clamp(column, 0, Length);
    }

    public float Width
    {
        get
        {
            DWRITE_TEXT_METRICS metrics;
            Layout->GetMetrics(&metrics);
            return OriginX + metrics.widthIncludingTrailingWhitespace;
        }
    }
}

// Fonts, metrics and the cache of line layouts. A layout is keyed by its text and colors, so lines that shift up or
// down after an edit find theirs again; only the edited line is laid out anew. Nothing here knows the editor: the
// data grid is to draw its cells with the same layer, through the span overloads that make no string per cell.
internal sealed unsafe class TextLayouts : IDisposable
{
    // Past this many characters a line is laid out in a slice around the visible columns.
    public const int LongLine = 4096;
    private const int SliceMargin = 512;

    private static readonly string[] Families = ["Cascadia Mono", "Consolas", "Courier New"];

    private readonly IDWriteFactory* _factory;
    private readonly Dictionary<LayoutKey, LineLayout> _cache = [];
    private IDWriteTextFormat* _format;
    private IDWriteTextFormat* _gutterFormat;
    private long _frame;

    private static int s_fallbackWarmed;

    public TextLayouts(IDWriteFactory* factory, float fontSize, int tabSize)
    {
        _factory = factory;
        FamilyName = PickFamily();
        Configure(fontSize, tabSize);
        WarmFontFallback(factory, FamilyName);
    }

    // The first text in a script the font lacks makes DirectWrite load its fallback fonts, which the grid gate
    // measured at 316 to 1,346 ms (lane wingates2). Doing it once per process on a pool thread keeps it off the first
    // keystroke or row that needs it.
    public static void WarmFontFallback(IDWriteFactory* factory, string family)
    {
        if (Interlocked.Exchange(ref s_fallbackWarmed, 1) == 1)
        {
            return;
        }
        factory->AddRef();
        var pointer = (nint)factory;
        _ = Task.Run(() =>
        {
            var shared = (IDWriteFactory*)pointer;
            try
            {
                IDWriteTextFormat* format;
                fixed (char* name = family)
                fixed (char* locale = "en-us")
                {
                    if (shared->CreateTextFormat(name, null, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                        DWRITE_FONT_STRETCH_NORMAL, 14, locale, &format).FAILED)
                    {
                        return;
                    }
                }
                const string Scripts = "Tiếng Việt 你好 日本語 한국어 العربية עברית ไทย Ελληνικά Русский ✓ 😀";
                IDWriteTextLayout* layout;
                fixed (char* text = Scripts)
                {
                    if (shared->CreateTextLayout(text, (uint)Scripts.Length, format, 10_000, 100, &layout).SUCCEEDED)
                    {
                        DWRITE_TEXT_METRICS metrics;
                        layout->GetMetrics(&metrics);
                        layout->Release();
                    }
                }
                format->Release();
            }
            finally
            {
                shared->Release();
            }
        });
    }

    // A layout of any UTF-16 text in the regular format, not cached; the caller releases it.
    public IDWriteTextLayout* CreateLayout(ReadOnlySpan<char> text, float maxWidth)
    {
        fixed (char* chars = text)
        {
            return CreateLayout(chars, text.Length, maxWidth);
        }
    }

    public IDWriteTextLayout* CreateLayout(char* text, int length, float maxWidth) =>
        CreateLayout(text, length, _format, maxWidth);

    public string FamilyName { get; }

    public float FontSize { get; private set; }

    public float LineHeight { get; private set; }

    public float CharWidth { get; private set; }

    public int CachedLayouts => _cache.Count;

    public int CreatedThisFrame { get; private set; }

    public void Configure(float fontSize, int tabSize)
    {
        Clear();
        NativeCom.Release(ref _format);
        NativeCom.Release(ref _gutterFormat);
        FontSize = fontSize;
        _format = CreateFormat(fontSize);
        _gutterFormat = CreateFormat(fontSize * 0.92f);
        _gutterFormat->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_TRAILING);

        var probe = CreateLayout("M", _format);
        DWRITE_TEXT_METRICS metrics;
        probe->GetMetrics(&metrics);
        DWRITE_LINE_METRICS line;
        uint count;
        probe->GetLineMetrics(&line, 1, &count);
        probe->Release();
        CharWidth = metrics.widthIncludingTrailingWhitespace;
        LineHeight = MathF.Ceiling(line.height * 1.2f);
        var baseline = line.baseline + (LineHeight - line.height) / 2;
        foreach (var format in new[] { _format, _gutterFormat })
        {
            format->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, LineHeight, baseline);
            format->SetIncrementalTabStop(CharWidth * tabSize);
        }
    }

    public void BeginFrame()
    {
        _frame++;
        CreatedThisFrame = 0;
    }

    // Layouts no frame used for a while go, so scrolling through a long file keeps the cache small.
    public void EndFrame()
    {
        if (_cache.Count < 600)
        {
            return;
        }
        foreach (var (key, layout) in _cache.Where(e => e.Value.LastFrame < _frame - 2).ToList())
        {
            layout.Layout->Release();
            _cache.Remove(key);
        }
    }

    // A line's layout with its colors. styleKey must change whenever the runs do.
    public LineLayout Get(string text, ReadOnlySpan<StyleRun> runs, ulong styleKey, float scrollX, float viewWidth,
        IStyleBrushes brushes)
    {
        var segmentStart = 0;
        var segmentLength = text.Length;
        if (text.Length > LongLine)
        {
            var firstVisible = (int)(scrollX / CharWidth);
            segmentStart = Math.Max(0, firstVisible - SliceMargin);
            segmentLength = Math.Min(text.Length - segmentStart, (int)(viewWidth / CharWidth) + 2 * SliceMargin);
        }
        var key = new LayoutKey(text, styleKey, segmentStart, segmentLength);
        if (_cache.TryGetValue(key, out var cached))
        {
            cached.LastFrame = _frame;
            return cached;
        }
        CreatedThisFrame++;
        var slice = segmentStart == 0 && segmentLength == text.Length ? text : text.Substring(segmentStart, segmentLength);
        var layout = CreateLayout(slice, _format);
        foreach (var run in runs)
        {
            var start = Math.Max(run.Start, segmentStart) - segmentStart;
            var end = Math.Min(run.Start + run.Length, segmentStart + segmentLength) - segmentStart;
            if (end <= start)
            {
                continue;
            }
            var range = new DWRITE_TEXT_RANGE { startPosition = (uint)start, length = (uint)(end - start) };
            var brush = brushes.For(run.Kind);
            if (brush is not null)
            {
                layout->SetDrawingEffect((IUnknown*)brush, range);
            }
            if (brushes.IsBold(run.Kind))
            {
                layout->SetFontWeight(DWRITE_FONT_WEIGHT_BOLD, range);
            }
        }
        var entry = new LineLayout
        {
            Layout = layout,
            SegmentStart = segmentStart,
            Length = slice.Length,
            OriginX = segmentStart * CharWidth,
            LastFrame = _frame,
        };
        _cache[key] = entry;
        return entry;
    }

    public IDWriteTextLayout* GutterNumber(string number, float width)
    {
        var key = new LayoutKey(number, 0xFFFF_FFFF_0000_0000UL | (uint)BitConverter.SingleToInt32Bits(width), -1, 0);
        if (_cache.TryGetValue(key, out var cached))
        {
            cached.LastFrame = _frame;
            return cached.Layout;
        }
        var layout = CreateLayout(number, _gutterFormat, width);
        _cache[key] = new LineLayout { Layout = layout, Length = number.Length, LastFrame = _frame };
        return layout;
    }

    public void Clear()
    {
        foreach (var layout in _cache.Values)
        {
            layout.Layout->Release();
        }
        _cache.Clear();
    }

    public void Dispose()
    {
        Clear();
        NativeCom.Release(ref _format);
        NativeCom.Release(ref _gutterFormat);
    }

    private IDWriteTextLayout* CreateLayout(ReadOnlySpan<char> text, IDWriteTextFormat* format, float width = 100_000)
    {
        fixed (char* chars = text)
        {
            return CreateLayout(chars, text.Length, format, width);
        }
    }

    private IDWriteTextLayout* CreateLayout(char* text, int length, IDWriteTextFormat* format, float width)
    {
        // Pinning an empty span gives a null pointer, which DirectWrite refuses even for no text.
        if (text is null)
        {
            fixed (char* empty = string.Empty)
            {
                return CreateLayout(empty, 0, format, width);
            }
        }
        IDWriteTextLayout* layout;
        NativeCom.Check(_factory->CreateTextLayout(text, (uint)length, format, width, LineHeight > 0 ? LineHeight : 100, &layout));
        return layout;
    }

    private IDWriteTextFormat* CreateFormat(float size)
    {
        IDWriteTextFormat* format;
        fixed (char* family = FamilyName)
        fixed (char* locale = "en-us")
        {
            NativeCom.Check(_factory->CreateTextFormat(family, null, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                DWRITE_FONT_STRETCH_NORMAL, size, locale, &format));
        }
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        return format;
    }

    private string PickFamily()
    {
        IDWriteFontCollection* fonts;
        NativeCom.Check(_factory->GetSystemFontCollection(&fonts, BOOL.FALSE));
        try
        {
            foreach (var name in Families)
            {
                uint index;
                BOOL exists;
                fixed (char* chars = name)
                {
                    if (fonts->FindFamilyName(chars, &index, &exists).SUCCEEDED && exists)
                    {
                        return name;
                    }
                }
            }
        }
        finally
        {
            fonts->Release();
        }
        return Families[^1];
    }

    private readonly record struct LayoutKey(string Text, ulong Style, int SegmentStart, int SegmentLength);
}

// A colored run within one line, in that line's columns.
internal readonly record struct StyleRun(int Start, int Length, byte Kind);

internal unsafe interface IStyleBrushes
{
    ID2D1Brush* For(byte kind);

    bool IsBold(byte kind);
}
