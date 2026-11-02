using System.Text;

namespace TablePro.DataGrid.Model;

// The first strong character decides, as TextBlock's DetectFromContent does (Unicode bidi rules P2 and P3).
public static class TextDirection
{
    public static bool IsRightToLeft(ReadOnlySpan<char> text)
    {
        foreach (var rune in text.EnumerateRunes())
        {
            if (!Rune.IsLetter(rune))
            {
                continue;
            }
            return IsRightToLeftScript(rune.Value);
        }
        return false;
    }

    // Hebrew to Mandaic and their presentation forms, and the right-to-left blocks past the BMP.
    private static bool IsRightToLeftScript(int value) => value switch
    {
        >= 0x0590 and <= 0x08FF => true,
        >= 0xFB1D and <= 0xFDFF => true,
        >= 0xFE70 and <= 0xFEFF => true,
        >= 0x10800 and <= 0x10FFF => true,
        >= 0x1E800 and <= 0x1EFFF => true,
        _ => false,
    };
}
