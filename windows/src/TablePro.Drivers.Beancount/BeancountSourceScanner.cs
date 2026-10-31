using System.Globalization;
using System.Text;

namespace TablePro.Drivers.Beancount;

internal readonly record struct BeancountSourceToken(string Value, bool Quoted);

internal sealed record BeancountSourceDirective(IReadOnlyList<BeancountSourceToken> Tokens, string SourcePath, int LineNumber);

/// <summary>
/// Splits and tokenizes ledger text for the projections that read the source directly. A ledger reaches this through
/// <see cref="BeancountSourceGraph.Lines"/>, which the include resolver already split, so nothing here reopens a file.
/// </summary>
internal static class BeancountSourceScanner
{
    // The separators Foundation's newline set holds, so line numbers match the macOS app's: LF, CR, VT, FF, NEL and
    // the Unicode line and paragraph separators.
    private static readonly char[] LineSeparators = ['\n', '\r', '\v', '\f', (char)0x85, (char)0x2028, (char)0x2029];

    /// <summary>
    /// Physical lines. A CRLF pair is collapsed first: split as two separators it would leave a phantom empty line
    /// between every pair, shifting every line number.
    /// </summary>
    public static string[] Lines(string contents) => contents.Replace("\r\n", "\n", StringComparison.Ordinal).Split(LineSeparators);

    /// <summary>
    /// Calls <paramref name="body"/> once per dated top-level directive, in source order. A string may span lines, so
    /// a directive is accumulated until its quotes balance; its line number is its first line. A directive left open at
    /// the end of the file is dropped.
    /// </summary>
    public static void ScanDirectives(IReadOnlyList<string> lines, string sourcePath, Action<BeancountSourceDirective> body)
    {
        StringBuilder? statement = null;
        var statementLine = 0;

        for (var offset = 0; offset < lines.Count; offset++)
        {
            var line = lines[offset];
            if (statement is null)
            {
                if (!StartsDirective(line))
                {
                    continue;
                }

                statement = new StringBuilder(line);
                statementLine = offset + 1;
            }
            else
            {
                statement.Append('\n').Append(line);
            }

            var candidate = statement.ToString();
            if (HasOpenQuote(candidate))
            {
                continue;
            }

            body(new BeancountSourceDirective(Tokenize(candidate), sourcePath, statementLine));
            statement = null;
        }
    }

    /// <summary><c>YYYY-MM-DD</c> for a Beancount date written with dashes or slashes, or null.</summary>
    public static string? CanonicalDate(string value)
    {
        var parts = value.Split('-', '/');
        if (parts.Length != 3
            || parts[0].Length != 4
            || !TryParseInt(parts[0], out var year)
            || !TryParseInt(parts[1], out var month)
            || !TryParseInt(parts[2], out var day)
            || month is < 1 or > 12
            || day is < 1 or > 31)
        {
            return null;
        }

        return string.Create(CultureInfo.InvariantCulture, $"{year:D4}-{month:D2}-{day:D2}");
    }

    public static List<BeancountSourceToken> Tokenize(string value)
    {
        var tokens = new List<BeancountSourceToken>();
        var index = 0;
        while (index < value.Length)
        {
            while (index < value.Length && char.IsWhiteSpace(value[index]))
            {
                index++;
            }

            if (index >= value.Length || value[index] == ';')
            {
                break;
            }

            if (value[index] == '"')
            {
                index++;
                tokens.Add(new BeancountSourceToken(QuotedValue(value, ref index), Quoted: true));
            }
            else
            {
                var start = index;
                while (index < value.Length && !char.IsWhiteSpace(value[index]) && value[index] != ';')
                {
                    index++;
                }

                tokens.Add(new BeancountSourceToken(value[start..index], Quoted: false));
            }
        }

        return tokens;
    }

    private static string QuotedValue(string value, ref int index)
    {
        var decoded = new StringBuilder();
        var escaped = false;
        while (index < value.Length)
        {
            var character = value[index++];
            if (escaped)
            {
                switch (character)
                {
                    case 'n':
                        decoded.Append('\n');
                        break;
                    case 'r':
                        decoded.Append('\r');
                        break;
                    case 't':
                        decoded.Append('\t');
                        break;
                    case '"' or '\\':
                        decoded.Append(character);
                        break;
                    default:
                        decoded.Append('\\').Append(character);
                        break;
                }

                escaped = false;
            }
            else if (character == '\\')
            {
                escaped = true;
            }
            else if (character == '"')
            {
                break;
            }
            else
            {
                decoded.Append(character);
            }
        }

        return decoded.ToString();
    }

    private static bool StartsDirective(string line)
    {
        if (line.Length == 0 || char.IsWhiteSpace(line[0]))
        {
            return false;
        }

        var end = 0;
        while (end < line.Length && !char.IsWhiteSpace(line[end]))
        {
            end++;
        }

        return CanonicalDate(line[..end]) is not null;
    }

    private static bool HasOpenQuote(string value)
    {
        var quoted = false;
        var escaped = false;
        foreach (var character in value)
        {
            if (escaped)
            {
                escaped = false;
            }
            else if (character == '\\')
            {
                escaped = quoted;
            }
            else if (character == '"')
            {
                quoted = !quoted;
            }
            else if (character == ';' && !quoted)
            {
                break;
            }
        }

        return quoted;
    }

    // Swift's Int(String) accepts an optional sign and ASCII digits only.
    private static bool TryParseInt(string text, out int value) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);
}
