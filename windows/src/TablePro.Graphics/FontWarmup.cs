using System.Diagnostics;
using System.Globalization;
using TerraFX.Interop.DirectX;
using static TerraFX.Interop.DirectX.D2D1_ALPHA_MODE;
using static TerraFX.Interop.DirectX.D2D1_BITMAP_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_DEVICE_CONTEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_DRAW_TEXT_OPTIONS;
using static TerraFX.Interop.DirectX.D2D1_TEXT_ANTIALIAS_MODE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STRETCH;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_WEIGHT;
using static TerraFX.Interop.DirectX.DXGI_FORMAT;

namespace TablePro.Graphics;

// Loading fallback fonts for a first non-Latin text cost the UI thread 316 to 1,346 ms in the grid spike.
internal static unsafe class FontWarmup
{
    public const string Scripts = "Tiếng Việt 你好 数据库 日本語 한국어 العربية עברית ไทย Ελληνικά Привет देवनागरी Ünïcödé ✓ 😀 🚀";

    private static readonly Dictionary<string, Task> s_started = [];
    private static readonly Lock s_lock = new();

    public static double LastMilliseconds { get; private set; }

    public static Task Start(IDWriteFactory* factory, string family, float fontSize, bool forceSoftware = false)
    {
        lock (s_lock)
        {
            if (s_started.TryGetValue(family, out var running))
            {
                return running;
            }
            factory->AddRef();
            var pointer = (nint)factory;
            var locale = CultureInfo.CurrentUICulture.Name;
            var task = Task.Run(() =>
            {
                var started = Stopwatch.GetTimestamp();
                try
                {
                    Warm((IDWriteFactory*)pointer, family, fontSize, locale.Length == 0 ? "en-us" : locale, forceSoftware);
                    LastMilliseconds = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
                }
                finally
                {
                    ((IDWriteFactory*)pointer)->Release();
                }
            });
            s_started[family] = task;
            return task;
        }
    }

    private static void Warm(IDWriteFactory* factory, string family, float fontSize, string locale, bool forceSoftware)
    {
        IDWriteTextFormat* format = null;
        IDWriteTextLayout* layout = null;
        try
        {
            fixed (char* name = family)
            fixed (char* localeName = locale)
            {
                if (factory->CreateTextFormat(name, null, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
                    DWRITE_FONT_STRETCH_NORMAL, fontSize, localeName, &format).FAILED)
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
            // On a Direct3D device, as the controls draw, which a software target would not warm.
            using var device = new RenderDevice(forceSoftware);
            Draw(layout, device.Direct2D);
        }
        finally
        {
            NativeCom.Release(ref layout);
            NativeCom.Release(ref format);
        }
    }

    private static void Draw(IDWriteTextLayout* layout, ID2D1Device* device)
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
            if (context->CreateBitmap(new D2D_SIZE_U { width = 1600, height = 64 }, null, 0, &properties, &target).FAILED)
            {
                return;
            }
            context->SetTarget((ID2D1Image*)target);
            var black = new DXGI_RGBA { a = 1 };
            if (context->CreateSolidColorBrush(&black, null, &brush).FAILED)
            {
                return;
            }
            context->BeginDraw();
            var clear = default(DXGI_RGBA);
            context->Clear(&clear);
            context->SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            context->DrawTextLayout(default, layout, (ID2D1Brush*)brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            _ = context->EndDraw(null, null);
            context->SetTarget(null);
        }
        finally
        {
            NativeCom.Release(ref brush);
            NativeCom.Release(ref target);
            NativeCom.Release(ref context);
        }
    }
}
