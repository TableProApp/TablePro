using System.Text;

namespace TablePro.Editor.Model.Vim;

// Unicode's full case mapping, as Swift's uppercased() gives it on macOS: .NET maps one character to one, so the
// unconditional entries of SpecialCasing.txt that change the length are added here.
internal static class VimCase
{
    private static readonly Dictionary<int, string> s_upper = new()
    {
        [0x00DF] = "SS",
        [0x0149] = "ʼN",
        [0x01F0] = "J̌",
        [0x0390] = "Ϊ́",
        [0x03B0] = "Ϋ́",
        [0x0587] = "ԵՒ",
        [0x1E96] = "H̱",
        [0x1E97] = "T̈",
        [0x1E98] = "W̊",
        [0x1E99] = "Y̊",
        [0x1E9A] = "Aʾ",
        [0xFB00] = "FF",
        [0xFB01] = "FI",
        [0xFB02] = "FL",
        [0xFB03] = "FFI",
        [0xFB04] = "FFL",
        [0xFB05] = "ST",
        [0xFB06] = "ST",
        [0xFB13] = "ՄՆ",
        [0xFB14] = "ՄԵ",
        [0xFB15] = "ՄԻ",
        [0xFB16] = "ՎՆ",
        [0xFB17] = "ՄԽ",
    };

    private static readonly Dictionary<int, string> s_lower = new()
    {
        [0x0130] = "i̇",
    };

    public static string Upper(string text) => Map(text, upper: true);

    public static string Lower(string text) => Map(text, upper: false);

    // Each letter to the other case; anything else, a combining mark included, stays.
    public static string Toggle(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            if (Rune.IsUpper(rune))
            {
                Append(result, rune, upper: false);
            }
            else if (Rune.IsLower(rune))
            {
                Append(result, rune, upper: true);
            }
            else
            {
                result.Append(rune.ToString());
            }
        }
        return result.ToString();
    }

    private static string Map(string text, bool upper)
    {
        var result = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            Append(result, rune, upper);
        }
        return result.ToString();
    }

    private static void Append(StringBuilder result, Rune rune, bool upper)
    {
        if ((upper ? s_upper : s_lower).TryGetValue(rune.Value, out var special))
        {
            result.Append(special);
            return;
        }
        result.Append((upper ? Rune.ToUpperInvariant(rune) : Rune.ToLowerInvariant(rune)).ToString());
    }
}
