using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace TablePro.Graphics;

// CLDR's plural category of a number in a language, from the ICU that Windows ships: icu.dll from Windows 10 1903,
// icuin.dll from 1703 on (learn.microsoft.com, International Components for Unicode).
internal static unsafe class PluralRules
{
    public const string Other = "other";

    private static readonly Lock s_lock = new();
    private static readonly Dictionary<string, nint> s_rules = new(StringComparer.OrdinalIgnoreCase);
    private static delegate* unmanaged[Cdecl]<byte*, int*, nint> s_open;
    private static delegate* unmanaged[Cdecl]<nint, double, char*, int, int*, int> s_select;
    private static bool s_loaded;

    // zero, one, two, few, many or other; other when ICU is missing or does not know the language.
    public static string Select(string language, double number)
    {
        ArgumentNullException.ThrowIfNull(language);
        lock (s_lock)
        {
            var rules = RulesFor(language);
            if (rules == 0)
            {
                return Other;
            }
            const int Capacity = 16;
            var keyword = stackalloc char[Capacity];
            var status = 0;
            var length = s_select(rules, number, keyword, Capacity, &status);
            return status > 0 || length <= 0 || length > Capacity ? Other : new string(keyword, 0, length);
        }
    }

    private static nint RulesFor(string language)
    {
        if (s_rules.TryGetValue(language, out var known))
        {
            return known;
        }
        nint rules = 0;
        if (Load())
        {
            var name = Encoding.ASCII.GetBytes(LocaleId(language) + "\0");
            var status = 0;
            fixed (byte* locale = name)
            {
                rules = s_open(locale, &status);
            }
            // The rules stay open for the process: one per language the strings were ever read in.
            rules = status > 0 ? 0 : rules;
        }
        s_rules[language] = rules;
        return rules;
    }

    // ICU's form of a BCP 47 tag, such as en_US for EN-US, which is how MRT names a string's language.
    private static string LocaleId(string language)
    {
        try
        {
            return CultureInfo.GetCultureInfo(language).Name.Replace('-', '_');
        }
        catch (CultureNotFoundException)
        {
            return language.Replace('-', '_');
        }
    }

    private static bool Load()
    {
        if (!s_loaded)
        {
            s_loaded = true;
            if ((FromSystem("icu.dll", out var library) || FromSystem("icuin.dll", out library))
                && NativeLibrary.TryGetExport(library, "uplrules_open", out var open)
                && NativeLibrary.TryGetExport(library, "uplrules_select", out var select))
            {
                s_open = (delegate* unmanaged[Cdecl]<byte*, int*, nint>)open;
                s_select = (delegate* unmanaged[Cdecl]<nint, double, char*, int, int*, int>)select;
            }
        }
        return s_open is not null;
    }

    private static bool FromSystem(string name, out nint library) =>
        NativeLibrary.TryLoad(name, typeof(PluralRules).Assembly, DllImportSearchPath.System32, out library);
}
