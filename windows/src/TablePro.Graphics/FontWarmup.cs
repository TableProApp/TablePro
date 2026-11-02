using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.D2D1_ALPHA_MODE;
using static TerraFX.Interop.DirectX.D2D1_DRAW_TEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STRETCH;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_WEIGHT;
using static TerraFX.Interop.DirectX.DXGI_FORMAT;
using static TerraFX.Interop.Windows.COINIT;
using static TerraFX.Interop.Windows.WICBitmapCreateCacheOption;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Graphics;

// The first text in a script the font lacks makes DirectWrite load its fallback fonts, which the grid gate measured at
// 316 to 1,346 ms on the UI thread (lane wingates2). Laying out and drawing every script once per family on a pool
// thread pays that before the first row or keystroke needs it.
internal static unsafe class FontWarmup
{
    public const string Scripts = "Tiếng Việt 你好 日本語 한국어 العربية עברית ไทย Ελληνικά Русский देवनागरी ✓ 😀 🚀";

    private static readonly HashSet<string> s_started = [];
    private static readonly Lock s_lock = new();

    public static Task Start(IDWriteFactory* factory, string family, float fontSize)
    {
        lock (s_lock)
        {
            if (!s_started.Add(family))
            {
                return Task.CompletedTask;
            }
        }
        factory->AddRef();
        var pointer = (nint)factory;
        return Task.Run(() =>
        {
            try
            {
                Warm((IDWriteFactory*)pointer, family, fontSize);
            }
            finally
            {
                ((IDWriteFactory*)pointer)->Release();
            }
        });
    }

    private static void Warm(IDWriteFactory* factory, string family, float fontSize)
    {
        IDWriteTextFormat* format = null;
        IDWriteTextLayout* layout = null;
        try
        {
            fixed (char* name = family)
            fixed (char* locale = "en-us")
            {
                if (factory->CreateTextFormat(name, null, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                    DWRITE_FONT_STRETCH_NORMAL, fontSize, locale, &format).FAILED)
                {
                    return;
                }
            }
            fixed (char* text = Scripts)
            {
                if (factory->CreateTextLayout(text, (uint)Scripts.Length, format, 10_000, 100, &layout).FAILED)
                {
                    return;
                }
            }
            DWRITE_TEXT_METRICS metrics;
            layout->GetMetrics(&metrics);
            Draw(layout);
        }
        finally
        {
            NativeCom.Release(ref layout);
            NativeCom.Release(ref format);
        }
    }

    // Drawing loads the glyphs of the color and fallback fonts as well. A WIC bitmap needs no device of the UI's.
    private static void Draw(IDWriteTextLayout* layout)
    {
        var initialized = CoInitializeEx(null, (uint)COINIT_MULTITHREADED).SUCCEEDED;
        IWICImagingFactory* wic = null;
        IWICBitmap* bitmap = null;
        ID2D1Factory* d2d = null;
        ID2D1RenderTarget* target = null;
        ID2D1SolidColorBrush* brush = null;
        try
        {
            var clsid = CLSID.CLSID_WICImagingFactory;
            if (CoCreateInstance(&clsid, null, (uint)CLSCTX.CLSCTX_INPROC_SERVER, NativeCom.Iid<IWICImagingFactory>(),
                (void**)&wic).FAILED)
            {
                return;
            }
            var pixelFormat = GUID.GUID_WICPixelFormat32bppPBGRA;
            if (wic->CreateBitmap(1200, 64, &pixelFormat, WICBitmapCacheOnLoad, &bitmap).FAILED)
            {
                return;
            }
            if (D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, NativeCom.Iid<ID2D1Factory>(), null, (void**)&d2d)
                .FAILED)
            {
                return;
            }
            var properties = new D2D1_RENDER_TARGET_PROPERTIES
            {
                pixelFormat = new D2D1_PIXEL_FORMAT { format = DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode = D2D1_ALPHA_MODE_PREMULTIPLIED },
            };
            if (d2d->CreateWicBitmapRenderTarget(bitmap, &properties, &target).FAILED)
            {
                return;
            }
            var black = new DXGI_RGBA { a = 1 };
            if (target->CreateSolidColorBrush(&black, null, &brush).FAILED)
            {
                return;
            }
            target->BeginDraw();
            target->DrawTextLayout(default, layout, (ID2D1Brush*)brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            _ = target->EndDraw(null, null);
        }
        finally
        {
            NativeCom.Release(ref brush);
            NativeCom.Release(ref target);
            NativeCom.Release(ref d2d);
            NativeCom.Release(ref bitmap);
            NativeCom.Release(ref wic);
            if (initialized)
            {
                CoUninitialize();
            }
        }
    }
}
