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

    // First draws of a column of mixed scripts cost the grid gate's first process 57 to 245 ms, a glyph at a time.
    public static string Glyphs { get; } = BuildGlyphs();

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

    private static string BuildGlyphs()
    {
        var text = new System.Text.StringBuilder();
        foreach (var (first, last) in new[]
        {
            (0x21, 0x7E), (0xA1, 0x24F), (0x370, 0x3FF), (0x400, 0x45F), (0x5D0, 0x5EA), (0x621, 0x64A), (0x905, 0x939),
            (0xE01, 0xE3A), (0x1EA0, 0x1EF9), (0x2010, 0x2044), (0x3041, 0x3096), (0x30A1, 0x30FA),
        })
        {
            for (var code = first; code <= last; code++)
            {
                if (char.IsLetterOrDigit((char)code) || char.IsPunctuation((char)code) || char.IsSymbol((char)code))
                {
                    text.Append((char)code);
                }
            }
        }
        text.Append("的一是不了人我在有他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高意进把法此实回二理美点月明其种声全工己话儿者向情部正名定女问力机给等几很业最间新什打便位因重被走电四第门相次东政海口使教西再平真听世气信北少关并内加化由却代军产入先山五太水万市眼体别处总才场师书比住员九笑性通目华报立马命张活难神数件安表原车白应路期叫死常提感金何更反合放做系计或司利受光王果亲界及今京务制解各任至清物台象记边共风战干接它许八特觉望直服毛林题建南度统色字请交爱让认算论百吃义科怎元社术结六功指思非流每青管夫连远资队跟带花快条院变联言权往展该领传近留红治决周保达办运武半候七必城父强步完革深区即求品士转量空甚众技轻程告江语英基派满式李息写呢识极令黄德收脸钱党倒未持取设始版双历越史商千片容研像找友孩站广改议形委早房音火际则首单据导影失拿网香似斯专石若兵弟谁校读志飞观争究包组造落视济喜离虽坐集编宝谈府拉黑且随格尽剑讲布杀微怕母调局根曾准团段终乐切级克精哪官示冷域数据库查询日本語");
        text.Append("가나다라마바사아자차카타파하한국어글");
        text.Append("😀😁😂🤣😃😄😅😆😉😊😋😎😍😘🙂🤗🤔😐😑😶🙄😏😣😥😮🤐😯😪😫😴😌😛😜😝🤤😒😓😔😕🙃🤑😲🙁😖😞😟😤😢😭😦😧😨😩🤯😬😰😱😳🤪😵😡😠🤬😷🤒🤕👍👎👏🙏💪🔥✨🎉❤️💯✅❌⚠️🚀⭐🌍📈📉🔒🔑");
        return text.ToString();
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
            var warm = Scripts + " " + Glyphs;
            fixed (char* text = warm)
            {
                if (factory->CreateTextLayout(text, (uint)warm.Length, format, 100_000, 100, &layout).FAILED)
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
            if (context->CreateBitmap(new D2D_SIZE_U { width = 4096, height = 64 }, null, 0, &properties, &target).FAILED)
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
            // The layout is one long line; drawing it shifted left page by page puts every glyph on the target once.
            DWRITE_TEXT_METRICS metrics;
            layout->GetMetrics(&metrics);
            for (var x = 0f; x < metrics.width; x += 4000)
            {
                context->DrawTextLayout(new D2D_POINT_2F(-x, 0), layout, (ID2D1Brush*)brush, D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT);
            }
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
