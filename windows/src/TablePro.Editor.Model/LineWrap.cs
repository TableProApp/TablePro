using System.Globalization;

namespace TablePro.Editor.Model;

// Where a line breaks into rows at a width in columns, as a monospaced font lays it out: a wide East Asian character or
// an emoji takes two columns, a combining mark none, and a tab runs to the next stop of its row, since each row is laid
// out on its own.
public static class LineWrap
{
    // Appends where each row after the first starts. A row breaks after its last space, else at the edge; spaces hang
    // past the edge rather than start a row, as Notepad and VS Code wrap.
    public static void Breaks(ReadOnlySpan<char> line, int columns, int tabSize, List<int> breaks)
    {
        ArgumentNullException.ThrowIfNull(breaks);
        columns = Math.Max(1, columns);
        tabSize = Math.Max(1, tabSize);
        var rowStart = 0;
        var column = 0;
        var afterSpace = -1;
        var i = 0;
        while (i < line.Length)
        {
            var c = line[i];
            if (c is ' ' or '\t')
            {
                column += c == '\t' ? tabSize - column % tabSize : 1;
                i++;
                afterSpace = i;
                continue;
            }
            var length = UnitLength(line, i);
            var width = Width(line, i, length);
            // A mark stays with the letter before it, as a caret stop does (TextUnits).
            if (column + width > columns && i > rowStart && !IsMark(c))
            {
                var at = afterSpace > rowStart ? afterSpace : i;
                breaks.Add(at);
                rowStart = at;
                afterSpace = -1;
                column = 0;
                for (var j = at; j < i; j += UnitLength(line, j))
                {
                    column += Width(line, j, UnitLength(line, j));
                }
                continue;
            }
            column += width;
            i += length;
        }
    }

    // Columns the text takes from the start of its row, for a caret aiming at a column in another row.
    public static int Columns(ReadOnlySpan<char> text, int tabSize)
    {
        tabSize = Math.Max(1, tabSize);
        var column = 0;
        for (var i = 0; i < text.Length;)
        {
            var c = text[i];
            if (c == '\t')
            {
                column += tabSize - column % tabSize;
                i++;
                continue;
            }
            var length = UnitLength(text, i);
            column += Width(text, i, length);
            i += length;
        }
        return column;
    }

    // The offset in the row whose columns come nearest to column, never inside a surrogate pair or before a mark.
    public static int OffsetAtColumn(ReadOnlySpan<char> row, int column, int tabSize)
    {
        tabSize = Math.Max(1, tabSize);
        var current = 0;
        var i = 0;
        while (i < row.Length && current < column)
        {
            var c = row[i];
            var end = i + (c == '\t' ? 1 : UnitLength(row, i));
            var next = c == '\t' ? current + tabSize - current % tabSize : current + Width(row, i, end - i);
            // A letter and the marks after it are one step, their columns counted together.
            while (end < row.Length && IsMark(row[end]))
            {
                next += Width(row, end, 1);
                end++;
            }
            if (next > column && next - column > column - current)
            {
                break;
            }
            current = next;
            i = end;
        }
        return i;
    }

    private static int UnitLength(ReadOnlySpan<char> text, int i) =>
        char.IsHighSurrogate(text[i]) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]) ? 2 : 1;

    private static int Width(ReadOnlySpan<char> text, int i, int length)
    {
        if (length == 2)
        {
            return IsWide(char.ConvertToUtf32(text[i], text[i + 1])) ? 2 : 1;
        }
        var c = text[i];
        if (c < 0x300)
        {
            return 1;
        }
        // A spacing mark such as a Devanagari vowel sign takes a column of its own; the others draw over their letter.
        if (CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark
            or UnicodeCategory.Format)
        {
            return 0;
        }
        return IsWide(c) ? 2 : 1;
    }

    private static bool IsMark(char c) => CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark
        or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark;

    // East Asian Wide and Fullwidth, and the emoji blocks, as terminals and VS Code count them.
    private static bool IsWide(int code) => code switch
    {
        >= 0x1100 and <= 0x115F => true,
        >= 0x2E80 and <= 0x303E => true,
        >= 0x3041 and <= 0x33FF => true,
        >= 0x3400 and <= 0x4DBF => true,
        >= 0x4E00 and <= 0x9FFF => true,
        >= 0xA000 and <= 0xA4CF => true,
        >= 0xAC00 and <= 0xD7A3 => true,
        >= 0xF900 and <= 0xFAFF => true,
        >= 0xFE30 and <= 0xFE4F => true,
        >= 0xFF00 and <= 0xFF60 => true,
        >= 0xFFE0 and <= 0xFFE6 => true,
        >= 0x1F300 and <= 0x1F64F => true,
        >= 0x1F900 and <= 0x1F9FF => true,
        >= 0x20000 and <= 0x3FFFD => true,
        _ => false,
    };
}
