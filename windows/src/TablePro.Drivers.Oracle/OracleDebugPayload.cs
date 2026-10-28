using System.Globalization;
using System.Text;

namespace TablePro.Drivers.Oracle;

/// <summary>
/// What a debug block hands back: fields written as <c>length:text</c>, or <c>~</c> for NULL, read through a cursor of
/// pieces. DBMS_DEBUG's runtime_info and program_info records cannot be bound, and a VARCHAR2 out bind stops at 4000
/// bytes, so each block gathers its fields into a CLOB and a REF CURSOR reads it 990 characters at a time.
/// </summary>
internal static class OracleDebugPayload
{
    public const string CursorBindName = "rows";

    // A field longer than this is cut, so length:text stays inside one VARCHAR2(32767) at four bytes a character.
    public const int FieldLimit = 8_000;

    private const int PieceLength = 990;

    public static readonly string Declarations = string.Create(CultureInfo.InvariantCulture, $$"""
          l_out CLOB;
          l_chunk VARCHAR2(32767);
          PROCEDURE put(p VARCHAR2) IS
            l_piece VARCHAR2(32767);
          BEGIN
            IF p IS NULL THEN
              l_piece := '~';
            ELSE
              l_piece := LENGTH(SUBSTR(p, 1, {{FieldLimit}})) || ':' || SUBSTR(p, 1, {{FieldLimit}});
            END IF;
            IF NVL(LENGTHB(l_chunk), 0) + LENGTHB(l_piece) > 32000 THEN
              l_out := l_out || l_chunk;
              l_chunk := NULL;
            END IF;
            l_chunk := l_chunk || l_piece;
          END;
        """);

    public static readonly string OpenCursor = string.Create(CultureInfo.InvariantCulture, $$"""
          IF l_chunk IS NOT NULL THEN
            l_out := l_out || l_chunk;
          END IF;
          OPEN :{{CursorBindName}} FOR
            SELECT TO_CHAR(SUBSTR(l_out, (LEVEL - 1) * {{PieceLength}} + 1, {{PieceLength}}))
            FROM SYS.DUAL
            CONNECT BY LEVEL <= GREATEST(CEIL(NVL(LENGTH(l_out), 0) / {{PieceLength}}), 1);
        """);

    public static string Join(IEnumerable<string?> pieces) => string.Concat(pieces.Select(p => p ?? string.Empty));

    /// <summary>
    /// The fields of a payload. Lengths count characters as Oracle's LENGTH does in AL32UTF8, one per Unicode scalar,
    /// so a character outside the BMP is one, not the two UTF-16 units it takes here.
    /// </summary>
    public static IReadOnlyList<string?> Parse(string text)
    {
        var fields = new List<string?>();
        var position = 0;
        while (position < text.Length)
        {
            if (text[position] == '~')
            {
                fields.Add(null);
                position++;
                continue;
            }

            var length = 0;
            var digits = 0;
            while (position < text.Length && char.IsAsciiDigit(text[position]))
            {
                // A field never exceeds FieldLimit, so more than nine digits is not a length this side wrote.
                if (digits == 9)
                {
                    throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"The debugger's answer is malformed at offset {position}."));
                }

                length = (length * 10) + (text[position] - '0');
                digits++;
                position++;
            }

            if (digits == 0 || position >= text.Length || text[position] != ':')
            {
                throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"The debugger's answer is malformed at offset {position}."));
            }

            position++;
            var start = position;
            for (var scalars = 0; scalars < length; scalars++)
            {
                if (position >= text.Length)
                {
                    throw new FormatException(string.Create(CultureInfo.InvariantCulture, $"The debugger's answer is malformed at offset {start}."));
                }

                position += char.IsHighSurrogate(text[position]) && position + 1 < text.Length && char.IsLowSurrogate(text[position + 1]) ? 2 : 1;
            }

            fields.Add(text[start..position]);
        }

        return fields;
    }

    /// <summary>The C# side of the blocks' put, for tests and for recorded answers.</summary>
    public static string Encode(IEnumerable<string?> fields)
    {
        var text = new StringBuilder();
        foreach (var field in fields)
        {
            if (field is null)
            {
                text.Append('~');
            }
            else
            {
                text.Append(field.EnumerateRunes().Count().ToString(CultureInfo.InvariantCulture)).Append(':').Append(field);
            }
        }

        return text.ToString();
    }
}

/// <summary>Reads payload fields in order; running out means the answer did not have the shape its block writes.</summary>
internal sealed class OracleDebugPayloadReader(IReadOnlyList<string?> fields)
{
    private int _position;

    public bool IsAtEnd => _position >= fields.Count;

    public string? Next() =>
        _position < fields.Count ? fields[_position++] : throw new FormatException("The debugger's answer ended early.");

    public int? Int() =>
        int.TryParse(Next()?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;
}
