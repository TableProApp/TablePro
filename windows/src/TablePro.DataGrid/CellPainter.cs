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
}

// Matches a TextBlock cell: XAML's font and content size times the text scale, one line cut with an ellipsis.
internal sealed unsafe class CellPainter : IDisposable
{
    public const float Padding = 12;
    public const float RowNumberPadding = 8;
    public const string NullText = "NULL";

    private static readonly string[] Families = ["Segoe UI Variable Text", "Segoe UI"];

    private readonly SurfaceDevice _device;
    private IDWriteTextFormat* _text;
    private IDWriteTextFormat* _null;
    private IDWriteTextFormat* _number;
    private IDWriteInlineObject* _ellipsis;
    private IDWriteInlineObject* _nullEllipsis;
    private ID2D1SolidColorBrush* _textBrush;
    private ID2D1SolidColorBrush* _placeholderBrush;
    private ID2D1SolidColorBrush* _cutMarkBrush;
    private ID2D1SolidColorBrush* _rowNumberBrush;
    private ID2D1SolidColorBrush* _dividerBrush;
    private ID2D1SolidColorBrush* _frozenEdgeBrush;
    private ID2D1SolidColorBrush* _headerBrush;
    private ID2D1SolidColorBrush* _selectedTextBrush;
    private int _brushGeneration = -1;
    private GridColors _colors;

    public CellPainter(SurfaceDevice device, float fontSize, GridColors colors)
    {
        _device = device;
        _colors = colors;
        FamilyName = PickFamily(device.DWrite);
        Configure(fontSize, colors);
    }

    public string FamilyName { get; }

    public float FontSize { get; private set; }

    // Bumped by every change that makes drawn rows stale: fonts, colors, the device.
    public int Version { get; private set; }

    public GridColors Colors => _colors;

    public SurfaceDevice Device => _device;

    public long LayoutsCreated { get; set; }

    // What WarmAsync drew, for the gate: samples drawn and the milliseconds it took.
    public static string Warmed { get; private set; } = "";

    public void Configure(float fontSize, GridColors colors)
    {
        ReleaseFormats();
        FontSize = fontSize;
        _colors = colors;
        _text = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_LEADING);
        _null = CreateFormat(DWRITE_FONT_STYLE_ITALIC, DWRITE_TEXT_ALIGNMENT_LEADING);
        _number = CreateFormat(DWRITE_FONT_STYLE_NORMAL, DWRITE_TEXT_ALIGNMENT_TRAILING);
        _ellipsis = Trim(_text);
        _nullEllipsis = Trim(_null);
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
        _brushGeneration = _device.Generation;
        Version++;
    }

    public ID2D1Brush* InkBrush(CellInk ink, bool selected) => ink switch
    {
        CellInk.Placeholder => (ID2D1Brush*)_placeholderBrush,
        CellInk.RowNumber => (ID2D1Brush*)(selected ? _textBrush : _rowNumberBrush),
        _ => (ID2D1Brush*)(selected && _colors.HighContrast ? _selectedTextBrush : _textBrush),
    };

    public ID2D1Brush* DividerBrush => (ID2D1Brush*)_dividerBrush;

    public ID2D1Brush* FrozenEdgeBrush => (ID2D1Brush*)_frozenEdgeBrush;

    public ID2D1Brush* HeaderBrush => (ID2D1Brush*)_headerBrush;

    public ID2D1Brush* SelectedTextBrush => (ID2D1Brush*)_selectedTextBrush;

    // A layout for one cell's text, or null when nothing shows. The caller releases it.
    public IDWriteTextLayout* CreateLayout(ReadOnlySpan<char> text, CellState state, float width, float height, out CellInk ink)
    {
        ink = CellInk.Text;
        if (width <= 0 || (state & CellState.Missing) != 0)
        {
            return null;
        }
        if ((state & CellState.Null) != 0)
        {
            ink = CellInk.Placeholder;
            return Create(NullText, _null, width, height);
        }
        if (text.IsEmpty)
        {
            return null;
        }
        var layout = Create(text, _text, width, height);
        if ((state & CellState.RightToLeft) != 0)
        {
            layout->SetReadingDirection(DWRITE_READING_DIRECTION_RIGHT_TO_LEFT);
        }
        if ((state & CellState.Truncated) != 0)
        {
            layout->SetDrawingEffect((IUnknown*)_cutMarkBrush, new DWRITE_TEXT_RANGE { startPosition = (uint)(text.Length - 1), length = 1 });
        }
        return layout;
    }

    public IDWriteTextLayout* CreateRowNumber(ReadOnlySpan<char> digits, float width, float height) =>
        width <= 0 || digits.IsEmpty ? null : Create(digits, _number, width, height);

    // The width text takes on one line, for fitting a column to its content.
    public float Measure(ReadOnlySpan<char> text, bool placeholder = false)
    {
        if (text.IsEmpty)
        {
            return 0;
        }
        var layout = Create(text, placeholder ? _null : _text, 100_000, 100);
        DWRITE_TEXT_METRICS metrics;
        layout->GetMetrics(&metrics);
        layout->Release();
        return metrics.widthIncludingTrailingWhitespace;
    }

    // Lays out and draws sample cells of every common script as the rows do, on the rows' device from a pool thread.
    public Task WarmAsync(float width, float height)
    {
        var text = (nint)_text;
        var placeholder = (nint)_null;
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
                    (IDWriteTextFormat*)placeholder, width, height);
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
        IDWriteTextFormat* placeholder, float width, float height)
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
                var sample = i < 0 ? FontWarmup.Scripts : i == samples.Length ? NullText : samples[i];
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

    private IDWriteTextFormat* CreateFormat(DWRITE_FONT_STYLE style, DWRITE_TEXT_ALIGNMENT alignment)
    {
        IDWriteTextFormat* format;
        // The user's language picks glyph variants, such as Han forms, as XAML text does.
        var locale = CultureInfo.CurrentUICulture.Name;
        fixed (char* family = FamilyName)
        fixed (char* localeName = locale.Length == 0 ? "en-us" : locale)
        {
            NativeCom.Check(_device.DWrite->CreateTextFormat(family, null, DWRITE_FONT_WEIGHT_NORMAL, style,
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

    internal static string PickFamily(IDWriteFactory* factory)
    {
        IDWriteFontCollection* fonts;
        NativeCom.Check(factory->GetSystemFontCollection(&fonts, BOOL.FALSE));
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
    }

    private void ReleaseFormats()
    {
        NativeCom.Release(ref _ellipsis);
        NativeCom.Release(ref _nullEllipsis);
        NativeCom.Release(ref _text);
        NativeCom.Release(ref _null);
        NativeCom.Release(ref _number);
    }
}
