using System.Globalization;
using TablePro.DataGrid.Model;
using TablePro.Graphics;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using Windows.UI;
using static TerraFX.Interop.DirectX.D2D1_ALPHA_MODE;
using static TerraFX.Interop.DirectX.D2D1_BITMAP_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_DEVICE_CONTEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_DRAW_TEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_TEXT_ANTIALIAS_MODE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STRETCH;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_WEIGHT;
using static TerraFX.Interop.DirectX.DWRITE_LINE_SPACING_METHOD;
using static TerraFX.Interop.DirectX.DWRITE_PARAGRAPH_ALIGNMENT;
using static TerraFX.Interop.DirectX.DWRITE_READING_DIRECTION;
using static TerraFX.Interop.DirectX.DWRITE_TEXT_ALIGNMENT;
using static TerraFX.Interop.DirectX.DWRITE_TRIMMING_GRANULARITY;
using static TerraFX.Interop.DirectX.DWRITE_WORD_WRAPPING;
using static TerraFX.Interop.DirectX.DXGI_FORMAT;

namespace TablePro.DataGrid;

internal enum CellInk : byte
{
    Text,
    Placeholder,
    RowNumber,
    Default,
    Deleted,
}

// Matches a TextBlock cell: XAML's font or the host's, its size times the text scale, one line cut with an ellipsis.
internal sealed unsafe class CellPainter : IDisposable
{
    public const float Padding = 12;
    public const float RowNumberPadding = 8;
    public const string NullWord = "NULL";

    private static readonly string[] Families = ["Segoe UI Variable Text", "Segoe UI"];

    private readonly SurfaceDevice _device;
    private IDWriteTextFormat* _text;
    private IDWriteTextFormat* _null;
    private IDWriteTextFormat* _number;
    private IDWriteTextFormat* _default;
    private IDWriteTextFormat* _wrapped;
    private float _wrapLineHeight;
    private float[]? _advances;
    private float _ellipsisAdvance;
    private DWRITE_LINE_METRICS[] _lines = new DWRITE_LINE_METRICS[16];
    private char[] _capped = new char[256];
    private IDWriteInlineObject* _ellipsis;
    private IDWriteInlineObject* _nullEllipsis;
    private IDWriteInlineObject* _defaultEllipsis;
    private ID2D1SolidColorBrush* _textBrush;
    private ID2D1SolidColorBrush* _placeholderBrush;
    private ID2D1SolidColorBrush* _cutMarkBrush;
    private ID2D1SolidColorBrush* _rowNumberBrush;
    private ID2D1SolidColorBrush* _dividerBrush;
    private ID2D1SolidColorBrush* _frozenEdgeBrush;
    private ID2D1SolidColorBrush* _headerBrush;
    private ID2D1SolidColorBrush* _selectedTextBrush;
    private ID2D1SolidColorBrush* _defaultBrush;
    private ID2D1SolidColorBrush* _deletedBrush;
    private ID2D1SolidColorBrush* _modifiedFill;
    private ID2D1SolidColorBrush* _insertedFill;
    private ID2D1SolidColorBrush* _deletedFill;
    private ID2D1SolidColorBrush* _selectionBrush;
    private int _brushGeneration = -1;
    private GridColors _colors;
    private string _defaultText = string.Empty;
    private string _nullText = NullWord;
    private string _unreadableFormat = "{0}";

    public CellPainter(SurfaceDevice device, string? family, float fontSize, GridColors colors)
    {
        _device = device;
        _colors = colors;
        FamilyName = PickFamily(device.DWrite, family);
        Configure(fontSize, colors);
    }

    public string FamilyName { get; private set; }

    public float FontSize { get; private set; }

    // What a cell the server fills shows.
    public string DefaultText
    {
        get => _defaultText;
        set
        {
            if (!string.Equals(_defaultText, value, StringComparison.Ordinal))
            {
                _defaultText = value;
                Version++;
            }
        }
    }

    // What a value the driver could not read shows, its type's name as {0}.
    public string UnreadableFormat
    {
        get => _unreadableFormat;
        set
        {
            if (!string.Equals(_unreadableFormat, value, StringComparison.Ordinal))
            {
                _unreadableFormat = value;
                Version++;
            }
        }
    }

    // What a NULL cell shows.
    public string NullText
    {
        get => _nullText;
        set
        {
            if (!string.Equals(_nullText, value, StringComparison.Ordinal))
            {
                _nullText = value;
                Version++;
            }
        }
    }

    // Bumped by every change that makes drawn rows stale: fonts, colors, the device.
    public int Version { get; private set; }

    public GridColors Colors => _colors;

    public SurfaceDevice Device => _device;

    public long LayoutsCreated { get; set; }

    // What WarmAsync drew, for the gate: samples drawn and the milliseconds it took.
    public static string Warmed { get; private set; } = "";

    public void Configure(string? family, float fontSize, GridColors colors)
    {
        FamilyName = PickFamily(_device.DWrite, family);
        Configure(fontSize, colors);
    }

    public void Configure(float fontSize, GridColors colors)
    {
        ReleaseFormats();
        FontSize = fontSize;
        _colors = colors;
        _text = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING);
        _null = CreateFormat(DWRITE_FONT_STYLE_ITALIC, DWRITE_TEXT_ALIGNMENT_LEADING);
        _number = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_TRAILING);
        _default = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_FONT_WEIGHT_SEMI_BOLD);
        _ellipsis = Trim(_text);
        _nullEllipsis = Trim(_null);
        _defaultEllipsis = Trim(_default);
        _brushGeneration = -1;
        Version++;
    }

    // Brushes live on the Direct2D device, so a new device needs new ones.
    public void EnsureBrushes()
    {
        if (_brushGeneration == _device.Generation)
        {
            return;
        }
        ReleaseBrushes();
        var context = _device.Resources;
        _textBrush = Brush(context, _colors.Text);
        _placeholderBrush = Brush(context, _colors.Placeholder);
        _cutMarkBrush = Brush(context, _colors.CutMark);
        _rowNumberBrush = Brush(context, _colors.RowNumber);
        _dividerBrush = Brush(context, _colors.Divider);
        _frozenEdgeBrush = Brush(context, _colors.FrozenEdge);
        _headerBrush = Brush(context, _colors.HeaderBackground);
        _selectedTextBrush = Brush(context, _colors.SelectedText);
        _defaultBrush = Brush(context, _colors.DefaultValue);
        _deletedBrush = Brush(context, _colors.DeletedText);
        _modifiedFill = Brush(context, _colors.ModifiedFill);
        _insertedFill = Brush(context, _colors.InsertedFill);
        _deletedFill = Brush(context, _colors.DeletedFill);
        _selectionBrush = Brush(context, _colors.Selection);
        _brushGeneration = _device.Generation;
        Version++;
    }

    public ID2D1Brush* InkBrush(CellInk ink, bool selected) => ink switch
    {
        CellInk.Placeholder => (ID2D1Brush*)_placeholderBrush,
        CellInk.RowNumber => (ID2D1Brush*)(selected ? _textBrush : _rowNumberBrush),
        CellInk.Default => (ID2D1Brush*)(selected && _colors.HighContrast ? _selectedTextBrush : _defaultBrush),
        CellInk.Deleted => (ID2D1Brush*)(selected && _colors.HighContrast ? _selectedTextBrush : _deletedBrush),
        _ => (ID2D1Brush*)(selected && _colors.HighContrast ? _selectedTextBrush : _textBrush),
    };

    // The wash behind a pending change, or null where none is drawn.
    public ID2D1Brush* FillBrush(CellState marks)
    {
        if (_colors.HighContrast)
        {
            return null;
        }
        if ((marks & CellState.Deleted) != 0)
        {
            return (ID2D1Brush*)_deletedFill;
        }
        if ((marks & CellState.Inserted) != 0)
        {
            return (ID2D1Brush*)_insertedFill;
        }
        return (marks & CellState.Modified) != 0 ? (ID2D1Brush*)_modifiedFill : null;
    }

    public ID2D1Brush* DividerBrush => (ID2D1Brush*)_dividerBrush;

    public ID2D1Brush* FrozenEdgeBrush => (ID2D1Brush*)_frozenEdgeBrush;

    public ID2D1Brush* HeaderBrush => (ID2D1Brush*)_headerBrush;

    public ID2D1Brush* SelectedTextBrush => (ID2D1Brush*)_selectedTextBrush;

    // The selection's tint, for a washed cell that hides the selection box beneath the row.
    public ID2D1Brush* SelectionBrush => (ID2D1Brush*)_selectionBrush;

    // A layout for one cell's text, or null when nothing shows. The caller releases it.
    public IDWriteTextLayout* CreateLayout(ReadOnlySpan<char> text, CellState state, float width, float height, out CellInk ink)
    {
        var deleted = (state & CellState.Deleted) != 0;
        ink = deleted ? CellInk.Deleted : CellInk.Text;
        if (width <= 0 || (state & CellState.Missing) != 0)
        {
            return null;
        }
        IDWriteTextLayout* layout;
        int length;
        if ((state & CellState.Null) != 0)
        {
            ink = deleted ? CellInk.Deleted : CellInk.Placeholder;
            layout = Create(_nullText, _null, width, height);
            length = _nullText.Length;
        }
        else if ((state & CellState.Unreadable) != 0)
        {
            ink = deleted ? CellInk.Deleted : CellInk.Placeholder;
            var shown = Unreadable(text);
            layout = Create(shown, _null, width, height);
            length = shown.Length;
        }
        else if ((state & CellState.Default) != 0)
        {
            if (_defaultText.Length == 0)
            {
                return null;
            }
            ink = deleted ? CellInk.Deleted : CellInk.Default;
            layout = Create(_defaultText, _default, width, height);
            length = _defaultText.Length;
        }
        else
        {
            if (text.IsEmpty)
            {
                return null;
            }
            layout = Create(text, _text, width, height);
            length = text.Length;
            if ((state & CellState.RightToLeft) != 0)
            {
                layout->SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT);
            }
            if ((state & CellState.Truncated) != 0)
            {
                layout->SetDrawingEffect((IUnknown*)_cutMarkBrush, new DWRITE_TEXT_RANGE { startPosition = (uint)(text.Length - 1), length = 1 });
            }
        }
        var range = new DWRITE_TEXT_RANGE { startPosition = 0, length = (uint)length };
        if (deleted)
        {
            layout->SetStrikethrough(BOOL.TRUE, range);
        }
        else if ((state & (CellState.Modified | CellState.Inserted)) != 0)
        {
            layout->SetUnderline(BOOL.TRUE, range);
        }
        return layout;
    }

    public IDWriteTextLayout* CreateRowNumber(ReadOnlySpan<char> digits, float width, float height, bool deleted)
    {
        if (width <= 0 || digits.IsEmpty)
        {
            return null;
        }
        var layout = Create(digits, _number, width, height);
        if (deleted)
        {
            layout->SetStrikethrough(BOOL.TRUE, new DWRITE_TEXT_RANGE { startPosition = 0, length = (uint)digits.Length });
        }
        return layout;
    }

    // The height each line of a wrapped cell takes, whatever font a line falls back to.
    public float WrapLineHeight
    {
        get
        {
            EnsureWrapped();
            return _wrapLineHeight;
        }
    }

    // Where a wrapped cell's first line starts: where the one centered line of a row that does not wrap sits.
    public float WrapInset(float rowPitch) => MathF.Max(0, (rowPitch - WrapLineHeight) / 2);

    // True only when the text surely takes one line of the width, by each character's advance, with no layout.
    public bool FitsOneLine(ReadOnlySpan<char> text, float width)
    {
        var advances = _advances ??= MeasureAdvances();
        var room = width - 2;
        foreach (var character in text)
        {
            if (character == '\n')
            {
                return false;
            }
            // Outside ASCII no glyph in common use is wider than two ems.
            room -= character < advances.Length ? advances[character] : FontSize * 2;
            if (room < 0)
            {
                return false;
            }
        }
        return true;
    }

    // The lines a wrapped cell's text takes at a width, however many: a row's height and the tip's rule read it.
    public int CountLines(ReadOnlySpan<char> text, CellState state, float width)
    {
        if (text.IsEmpty || width <= 0 || FitsOneLine(text, width))
        {
            return 1;
        }
        EnsureWrapped();
        var layout = WrappedLayout(text, state, width, _wrapLineHeight);
        DWRITE_TEXT_METRICS metrics;
        layout->GetMetrics(&metrics);
        layout->Release();
        return Math.Max(1, (int)metrics.lineCount);
    }

    // A wrapped layout the caller releases, or null when nothing shows; past maxLines the text ends in one ellipsis.
    public IDWriteTextLayout* CreateWrapped(ReadOnlySpan<char> text, CellState state, float width, int maxLines,
        out CellInk ink)
    {
        var deleted = (state & CellState.Deleted) != 0;
        ink = deleted ? CellInk.Deleted : CellInk.Text;
        if (width <= 0 || text.IsEmpty || maxLines <= 0)
        {
            return null;
        }
        EnsureWrapped();
        var height = maxLines * _wrapLineHeight;
        var layout = WrappedLayout(text, state, width, height);
        var length = text.Length;
        var cut = (state & CellState.Truncated) != 0;
        DWRITE_TEXT_METRICS metrics;
        layout->GetMetrics(&metrics);
        if (metrics.lineCount > (uint)maxLines)
        {
            var end = LinesEnd(layout, (int)metrics.lineCount, maxLines, out var breaks);
            if (end > 0)
            {
                layout->Release();
                layout = Capped(text[..Math.Min(end, text.Length)], breaks, state, width, height, maxLines, out length);
                cut = true;
            }
        }
        if (cut && length > 0)
        {
            layout->SetDrawingEffect((IUnknown*)_cutMarkBrush,
                new DWRITE_TEXT_RANGE { startPosition = (uint)(length - 1), length = 1 });
        }
        var range = new DWRITE_TEXT_RANGE { startPosition = 0, length = (uint)length };
        if (deleted)
        {
            layout->SetStrikethrough(BOOL.TRUE, range);
        }
        else if ((state & (CellState.Modified | CellState.Inserted)) != 0)
        {
            layout->SetUnderline(BOOL.TRUE, range);
        }
        return layout;
    }

    // The width text takes on one line, for fitting a column to its content.
    public float Measure(ReadOnlySpan<char> text, bool placeholder = false)
    {
        if (text.IsEmpty)
        {
            return 0;
        }
        return Measure(text, placeholder ? _null : _text);
    }

    public string Unreadable(ReadOnlySpan<char> typeName) =>
        string.Format(CultureInfo.CurrentCulture, _unreadableFormat, typeName.ToString());

    public float MeasureDefault() => _defaultText.Length == 0 ? 0 : Measure(_defaultText, _default);

    // Lays out and draws sample cells of every common script as the rows do, on the rows' device from a pool thread.
    public Task WarmAsync(float width, float height)
    {
        var text = (nint)_text;
        var placeholder = (nint)_null;
        var nullText = _nullText;
        var device = (nint)_device.Direct2D;
        var factory = (nint)_device.DWrite;
        _text->AddRef();
        _null->AddRef();
        _device.Direct2D->AddRef();
        _device.DWrite->AddRef();
        return Task.Run(() =>
        {
            try
            {
                DrawSamples((IDWriteFactory*)factory, (ID2D1Device*)device, (IDWriteTextFormat*)text,
                    (IDWriteTextFormat*)placeholder, nullText, width, height);
            }
            finally
            {
                ((IUnknown*)text)->Release();
                ((IUnknown*)placeholder)->Release();
                ((IUnknown*)device)->Release();
                ((IUnknown*)factory)->Release();
            }
        });
    }

    public void Dispose()
    {
        ReleaseBrushes();
        ReleaseFormats();
    }

    private static void DrawSamples(IDWriteFactory* factory, ID2D1Device* device, IDWriteTextFormat* text,
        IDWriteTextFormat* placeholder, string nullText, float width, float height)
    {
        ID2D1DeviceContext* context = null;
        ID2D1Bitmap1* target = null;
        ID2D1SolidColorBrush* brush = null;
        try
        {
            if (device->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE, &context).FAILED)
            {
                return;
            }
            var properties = new D2D1_BITMAP_PROPERTIES1
            {
                pixelFormat = new D2D1_PIXEL_FORMAT { format = DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED },
                dpiX = 96,
                dpiY = 96,
                bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET,
            };
            var size = new D2D_SIZE_U { width = (uint)Math.Ceiling(width) + 32, height = (uint)Math.Ceiling(height) };
            if (context->CreateBitmap(size, null, 0, &properties, &target).FAILED)
            {
                return;
            }
            context->SetTarget((ID2D1Image*)target);
            var black = new DXGI_RGBA { a = 1 };
            if (context->CreateSolidColorBrush(&black, null, &brush).FAILED)
            {
                return;
            }
            var started = System.Diagnostics.Stopwatch.GetTimestamp();
            var drawn = 0;
            context->BeginDraw();
            context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            var samples = FontWarmup.Scripts.Split(' ').Concat(FontWarmup.Glyphs.Chunk(48).Select(chunk => new string(chunk))).ToArray();
            for (var i = -1; i <= samples.Length; i++)
            {
                var sample = i < 0 ? FontWarmup.Scripts : i == samples.Length ? nullText : samples[i];
                var format = i == samples.Length ? placeholder : text;
                IDWriteTextLayout* layout;
                fixed (char* chars = sample)
                {
                    if (factory->CreateTextLayout(chars, (uint)sample.Length, format, width, height, &layout).FAILED)
                    {
                        continue;
                    }
                }
                if (TextDirection.IsRightToLeft(sample))
                {
                    layout->SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT);
                }
                var clear = default(DXGI_RGBA);
                context->Clear(&clear);
                context->DrawTextLayout(default, layout, (ID2D1Brush*)brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
                layout->Release();
                drawn++;
            }
            var result = context->EndDraw(null, null);
            Warmed = string.Create(CultureInfo.InvariantCulture,
                $"samples={drawn} end=0x{result.Value:X8} ms={System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds:F1}");
            context->SetTarget(null);
        }
        finally
        {
            NativeCom.Release(ref brush);
            NativeCom.Release(ref target);
            NativeCom.Release(ref context);
        }
    }

    private float Measure(ReadOnlySpan<char> text, IDWriteTextFormat* format)
    {
        var layout = Create(text, format, 100_000, 100);
        DWRITE_TEXT_METRICS metrics;
        layout->GetMetrics(&metrics);
        layout->Release();
        return metrics.widthIncludingTrailingWhitespace;
    }

    private IDWriteTextLayout* WrappedLayout(ReadOnlySpan<char> text, CellState state, float width, float height)
    {
        var layout = Create(text, _wrapped, width, height);
        if ((state & CellState.RightToLeft) != 0)
        {
            layout->SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT);
        }
        return layout;
    }

    // The characters the first lines of a layout hold, and whether the last of them ends at a line break; 0 on failure.
    private int LinesEnd(IDWriteTextLayout* layout, int lineCount, int lines, out bool breaks)
    {
        breaks = false;
        if (_lines.Length < lineCount)
        {
            _lines = new DWRITE_LINE_METRICS[lineCount];
        }
        uint actual;
        fixed (DWRITE_LINE_METRICS* metrics = _lines)
        {
            if (layout->GetLineMetrics(metrics, (uint)_lines.Length, &actual).FAILED || actual < (uint)lines)
            {
                return 0;
            }
        }
        var end = 0;
        for (var line = 0; line < lines; line++)
        {
            end += (int)_lines[line].length;
        }
        breaks = _lines[lines - 1].newlineLength > 0;
        return end;
    }

    // DirectWrite has no line limit and documents no trimming of a wrapped layout, so the cut is made here.
    private IDWriteTextLayout* Capped(ReadOnlySpan<char> text, bool breaks, CellState state, float width, float height,
        int maxLines, out int length)
    {
        // Only the break that ends the last line goes: blank lines above it are part of the value.
        var kept = TrimSpaces(breaks && text.Length > 0 ? text[..^1] : text);
        // Text the core cut ends in its own ellipsis already.
        var marked = kept.Length > 0 && kept[^1] == CellBlock.Ellipsis;
        if (!marked && !breaks)
        {
            kept = MakeRoom(kept);
        }
        for (var attempt = 0; ; attempt++)
        {
            if (_capped.Length < kept.Length + 1)
            {
                _capped = new char[Math.Max(_capped.Length * 2, kept.Length + 1)];
            }
            kept.CopyTo(_capped);
            length = kept.Length;
            if (!marked)
            {
                _capped[length++] = CellBlock.Ellipsis;
            }
            var layout = WrappedLayout(_capped.AsSpan(0, length), state, width, height);
            DWRITE_TEXT_METRICS metrics;
            layout->GetMetrics(&metrics);
            if (metrics.lineCount <= (uint)maxLines || kept.Length <= 1 || attempt == 16)
            {
                return layout;
            }
            layout->Release();
            kept = TrimSpaces(DropLast(kept));
        }
    }

    private static ReadOnlySpan<char> TrimSpaces(ReadOnlySpan<char> text)
    {
        var end = text.Length;
        while (end > 0 && text[end - 1] != '\n' && char.IsWhiteSpace(text[end - 1]))
        {
            end--;
        }
        return text[..end];
    }

    // Drops characters from a full line's end until what they took is at least an ellipsis wide, by their advances.
    private ReadOnlySpan<char> MakeRoom(ReadOnlySpan<char> text)
    {
        var advances = _advances ??= MeasureAdvances();
        var freed = 0f;
        while (text.Length > 1 && freed < _ellipsisAdvance)
        {
            var last = text[^1];
            // A character outside ASCII frees at least half an em, or the layout's line count says to drop more.
            freed += last < advances.Length ? advances[last] : FontSize / 2;
            text = DropLast(text);
        }
        return text;
    }

    private static ReadOnlySpan<char> DropLast(ReadOnlySpan<char> text) =>
        text.Length >= 2 && char.IsLowSurrogate(text[^1]) && char.IsHighSurrogate(text[^2]) ? text[..^2] : text[..^1];

    // The advance of each printable ASCII character alone, and the ellipsis's, measured once per font.
    private float[] MeasureAdvances()
    {
        var advances = new float[128];
        Span<char> one = stackalloc char[1];
        for (var character = ' '; character < 127; character++)
        {
            one[0] = character;
            advances[character] = Measure(one, _text);
        }
        one[0] = CellBlock.Ellipsis;
        _ellipsisAdvance = Measure(one, _text);
        return advances;
    }

    // Made when a grid first wraps, so a grid that never does pays for no format and no probe.
    private void EnsureWrapped()
    {
        if (_wrapped != null)
        {
            return;
        }
        _wrapped = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING);
        // A word wider than the column, such as a URL or a hash, breaks inside itself rather than overflow.
        _wrapped->SetWordWrapping(DWRITE_WORD_WRAPPING_EMERGENCY_BREAK);
        _wrapped->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
        var probe = Create("M", _wrapped, 1000, 1000);
        DWRITE_LINE_METRICS line;
        uint count;
        probe->GetLineMetrics(&line, 1, &count);
        probe->Release();
        _wrapLineHeight = MathF.Ceiling(line.height);
        // Uniform, so a line that falls back to a taller font is no taller and a row is its line count times this.
        _wrapped->SetLineSpacing(DWRITE_LINE_SPACING_METHOD_UNIFORM, _wrapLineHeight,
            line.baseline + ((_wrapLineHeight - line.height) / 2));
    }

    private IDWriteTextLayout* Create(ReadOnlySpan<char> text, IDWriteTextFormat* format, float width, float height)
    {
        IDWriteTextLayout* layout;
        fixed (char* chars = text)
        {
            NativeCom.Check(_device.DWrite->CreateTextLayout(chars, (uint)text.Length, format, width, height, &layout));
        }
        LayoutsCreated++;
        return layout;
    }

    private IDWriteTextFormat* CreateFormat(DWRITE_FONT_STYLE style, DWRITE_TEXT_ALIGNMENT alignment,
        DWRITE_FONT_WEIGHT weight = DWRITE_FONT_WEIGHT_NORMAL)
    {
        IDWriteTextFormat* format;
        // The user's language picks glyph variants, such as Han forms, as XAML text does.
        var locale = CultureInfo.CurrentUICulture.Name;
        fixed (char* family = FamilyName)
        fixed (char* localeName = locale.Length == 0 ? "en-us" : locale)
        {
            NativeCom.Check(_device.DWrite->CreateTextFormat(family, null, weight, style,
                DWRITE_FONT_STRETCH_NORMAL, FontSize, localeName, &format));
        }
        format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
        format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        format->SetTextAlignment(alignment);
        return format;
    }

    private IDWriteInlineObject* Trim(IDWriteTextFormat* format)
    {
        IDWriteInlineObject* sign;
        NativeCom.Check(_device.DWrite->CreateEllipsisTrimmingSign(format, &sign));
        var trimming = new DWRITE_TRIMMING { granularity = DWRITE_TRIMMING_GRANULARITY_CHARACTER };
        format->SetTrimming(&trimming, sign);
        return sign;
    }

    private static ID2D1SolidColorBrush* Brush(ID2D1DeviceContext* context, Color color)
    {
        var value = ThemeColors.ToD2D(color);
        ID2D1SolidColorBrush* brush;
        NativeCom.Check(context->CreateSolidColorBrush(&value, null, &brush));
        return brush;
    }

    // The family asked for when it is installed, else the first of ours that is.
    internal static string PickFamily(IDWriteFactory* factory, string? preferred = null)
    {
        IDWriteFontCollection* fonts;
        NativeCom.Check(factory->GetSystemFontCollection(&fonts, BOOL.FALSE));
        try
        {
            if (!string.IsNullOrWhiteSpace(preferred) && IsInstalled(fonts, preferred))
            {
                return preferred;
            }
            foreach (var name in Families)
            {
                if (IsInstalled(fonts, name))
                {
                    return name;
                }
            }
        }
        finally
        {
            fonts->Release();
        }
        return Families[^1];
    }

    private static bool IsInstalled(IDWriteFontCollection* fonts, string name)
    {
        uint index;
        BOOL exists;
        fixed (char* chars = name)
        {
            return fonts->FindFamilyName(chars, &index, &exists).SUCCEEDED && exists;
        }
    }

    private void ReleaseBrushes()
    {
        NativeCom.Release(ref _textBrush);
        NativeCom.Release(ref _placeholderBrush);
        NativeCom.Release(ref _cutMarkBrush);
        NativeCom.Release(ref _rowNumberBrush);
        NativeCom.Release(ref _dividerBrush);
        NativeCom.Release(ref _frozenEdgeBrush);
        NativeCom.Release(ref _headerBrush);
        NativeCom.Release(ref _selectedTextBrush);
        NativeCom.Release(ref _defaultBrush);
        NativeCom.Release(ref _deletedBrush);
        NativeCom.Release(ref _modifiedFill);
        NativeCom.Release(ref _insertedFill);
        NativeCom.Release(ref _deletedFill);
        NativeCom.Release(ref _selectionBrush);
    }

    private void ReleaseFormats()
    {
        NativeCom.Release(ref _ellipsis);
        NativeCom.Release(ref _nullEllipsis);
        NativeCom.Release(ref _defaultEllipsis);
        NativeCom.Release(ref _wrapped);
        _advances = null;
        NativeCom.Release(ref _text);
        NativeCom.Release(ref _null);
        NativeCom.Release(ref _number);
        NativeCom.Release(ref _default);
    }
}
