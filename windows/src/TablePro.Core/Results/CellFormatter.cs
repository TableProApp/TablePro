using System.Buffers;
using System.Globalization;
using System.Text;
using TablePro.Core.Localization;

namespace TablePro.Core.Results;

/// <summary>Turns a cell value into text. The grid calls it only for visible cells, so it formats lazily.</summary>
public static class CellFormatter
{
    public const string NullText = "NULL";

    /// <summary>Cells show at most this many characters; the detail pane and copy use the full value.</summary>
    public const int CellPreviewLength = 300;

    private static readonly SearchValues<char> LineBreaks = SearchValues.Create("\r\n\t");

    public static string Format(object? value) => value switch
    {
        null or DBNull => NullText,
        string s => s,
        bool b => b ? "true" : "false",
        byte[] bytes => FormatBytes(bytes, int.MaxValue),
        DateTime dt => dt.TimeOfDay == TimeSpan.Zero && dt.Kind == DateTimeKind.Unspecified
            ? dt.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
            : dt.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        DateTimeOffset dto => dto.ToString("yyyy-MM-dd HH:mm:ss.FFFFFFFzzz", CultureInfo.InvariantCulture),
        DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        TimeOnly t => t.ToString("HH:mm:ss.FFFFFFF", CultureInfo.InvariantCulture),
        TimeSpan ts => ts.ToString("c", CultureInfo.InvariantCulture),
        float f => f.ToString("R", CultureInfo.InvariantCulture),
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        Array array => FormatArray(array),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };

    /// <summary>A single line for a grid cell: line breaks become spaces and long values are cut.</summary>
    public static string FormatForCell(object? value)
    {
        if (value is byte[] bytes)
        {
            return FormatBytes(bytes, 64);
        }

        var text = Format(value);
        if (text.Length > CellPreviewLength)
        {
            // Cutting between the halves of a surrogate pair would leave an invalid character at the end.
            var cut = char.IsHighSurrogate(text[CellPreviewLength - 1]) ? CellPreviewLength - 1 : CellPreviewLength;
            text = string.Concat(text.AsSpan(0, cut), "…");
        }

        if (text.AsSpan().IndexOfAny(LineBreaks) < 0)
        {
            return text;
        }

        return string.Create(text.Length, text, static (span, source) =>
        {
            for (var i = 0; i < source.Length; i++)
            {
                var c = source[i];
                span[i] = c is '\r' or '\n' or '\t' ? ' ' : c;
            }
        });
    }

    public static string FormatBytes(byte[] bytes, int maxBytes)
    {
        var shown = Math.Min(bytes.Length, maxBytes);
        var hex = Convert.ToHexString(bytes, 0, shown);
        return shown < bytes.Length ? CoreStrings.Plural("Results/TruncatedBytes", bytes.Length, hex) : "0x" + hex;
    }

    private static string FormatArray(Array array)
    {
        var sb = new StringBuilder("{");
        var first = true;
        foreach (var item in array)
        {
            if (!first)
            {
                sb.Append(',');
            }

            sb.Append(Format(item));
            first = false;
        }

        return sb.Append('}').ToString();
    }
}
