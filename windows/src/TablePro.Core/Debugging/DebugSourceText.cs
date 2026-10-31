namespace TablePro.Core.Debugging;

/// <summary>Routine source as the numbered lines the debugger reports stops on.</summary>
public static class DebugSourceText
{
    /// <summary>
    /// Splits at <c>\r\n</c>, <c>\n</c> or <c>\r</c>, so line N here is line N of the engine's count however the source
    /// was saved. A final line ending adds no empty line.
    /// </summary>
    public static IReadOnlyList<string> Lines(string source)
    {
        if (source.Length == 0)
        {
            return [];
        }

        var lines = new List<string>();
        var start = 0;
        for (var i = 0; i < source.Length; i++)
        {
            if (source[i] is not ('\n' or '\r'))
            {
                continue;
            }

            lines.Add(source[start..i]);
            if (source[i] == '\r' && i + 1 < source.Length && source[i + 1] == '\n')
            {
                i++;
            }

            start = i + 1;
        }

        if (start < source.Length)
        {
            lines.Add(source[start..]);
        }

        return lines;
    }
}
