using System.Globalization;
using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.DirectX.DWRITE_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STRETCH;
using static TerraFX.Interop.DirectX.DWRITE_FONT_STYLE;
using static TerraFX.Interop.DirectX.DWRITE_FONT_WEIGHT;

namespace TablePro.Graphics;

internal static unsafe class FontFamilies
{
    public static readonly string[] EditorFallbacks = ["Cascadia Mono", "Consolas", "Courier New"];

    public static string Pick(string? requested, string[] fallbacks)
    {
        var factory = SharedFactory();
        try
        {
            return Pick(factory, requested, fallbacks);
        }
        finally
        {
            factory->Release();
        }
    }

    // The requested family when it is installed, else the first installed fallback.
    public static string Pick(IDWriteFactory* factory, string? requested, string[] fallbacks)
    {
        IDWriteFontCollection* fonts;
        NativeCom.Check(factory->GetSystemFontCollection(&fonts, BOOL.FALSE));
        try
        {
            if (!string.IsNullOrWhiteSpace(requested) && Exists(fonts, requested))
            {
                return requested;
            }
            foreach (var name in fallbacks)
            {
                if (Exists(fonts, name))
                {
                    return name;
                }
            }
        }
        finally
        {
            fonts->Release();
        }
        return fallbacks[^1];
    }

    public static List<string> Installed(bool monospacedOnly)
    {
        var factory = SharedFactory();
        IDWriteFontCollection* fonts = null;
        var locale = CultureInfo.CurrentUICulture.Name;
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            NativeCom.Check(factory->GetSystemFontCollection(&fonts, BOOL.FALSE));
            var count = fonts->GetFontFamilyCount();
            for (var i = 0u; i < count; i++)
            {
                IDWriteFontFamily* family = null;
                try
                {
                    if (fonts->GetFontFamily(i, &family).FAILED)
                    {
                        continue;
                    }
                    // A name that starts with '@' is the vertical form of an East Asian family.
                    var name = FamilyName(family, locale);
                    if (string.IsNullOrEmpty(name) || name[0] == '@' || (monospacedOnly && !IsMonospaced(family)))
                    {
                        continue;
                    }
                    names.Add(name);
                }
                finally
                {
                    NativeCom.Release(ref family);
                }
            }
        }
        finally
        {
            NativeCom.Release(ref fonts);
            factory->Release();
        }
        var sorted = names.ToList();
        sorted.Sort(StringComparer.CurrentCulture);
        return sorted;
    }

    private static IDWriteFactory* SharedFactory()
    {
        IDWriteFactory* factory;
        NativeCom.Check(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, NativeCom.Iid<IDWriteFactory>(),
            (IUnknown**)&factory));
        return factory;
    }

    private static bool Exists(IDWriteFontCollection* fonts, string name)
    {
        uint index;
        BOOL exists;
        fixed (char* chars = name)
        {
            return fonts->FindFamilyName(chars, &index, &exists).SUCCEEDED && exists;
        }
    }

    private static string? FamilyName(IDWriteFontFamily* family, string locale)
    {
        IDWriteLocalizedStrings* names = null;
        try
        {
            if (family->GetFamilyNames(&names).FAILED)
            {
                return null;
            }
            var index = FindLocale(names, locale) ?? FindLocale(names, "en-us") ?? 0;
            uint length;
            if (names->GetStringLength(index, &length).FAILED)
            {
                return null;
            }
            var buffer = new char[length + 1];
            fixed (char* chars = buffer)
            {
                if (names->GetString(index, chars, length + 1).FAILED)
                {
                    return null;
                }
            }
            return new string(buffer, 0, (int)length);
        }
        finally
        {
            NativeCom.Release(ref names);
        }
    }

    private static uint? FindLocale(IDWriteLocalizedStrings* names, string locale)
    {
        if (locale.Length == 0)
        {
            return null;
        }
        uint index;
        BOOL exists;
        fixed (char* chars = locale)
        {
            return names->FindLocaleName(chars, &index, &exists).SUCCEEDED && exists ? index : null;
        }
    }

    private static bool IsMonospaced(IDWriteFontFamily* family)
    {
        IDWriteFont* font = null;
        IDWriteFont1* font1 = null;
        try
        {
            if (family->GetFirstMatchingFont(DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                DWRITE_FONT_STYLE_NORMAL, &font).FAILED)
            {
                return false;
            }
            if (font->QueryInterface(NativeCom.Iid<IDWriteFont1>(), (void**)&font1).FAILED)
            {
                return false;
            }
            return font1->IsMonospacedFont();
        }
        finally
        {
            NativeCom.Release(ref font1);
            NativeCom.Release(ref font);
        }
    }
}
