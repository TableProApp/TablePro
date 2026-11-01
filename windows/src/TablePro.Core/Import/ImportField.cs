using System.Globalization;

namespace TablePro.Core.Import;

/// <summary>What the values of one field of an import file look like, which proposes the type of a new column.</summary>
public enum ImportFieldType
{
    Text,
    Integer,
    Real,
    Boolean,

    /// <summary>Every value is a JSON object or array.</summary>
    Json,
}

/// <summary>One field of an import file: a CSV column or a JSON key, with the first value seen and the type its values suggest.</summary>
public sealed record ImportField(string Name, string? SampleValue, ImportFieldType InferredType);

/// <summary>Infers a field's type from a sample of its values, as the macOS CSV and JSON import plugins do.</summary>
public static class ImportTypeInference
{
    /// <summary>How many values decide a field, as on macOS: enough to see past a few odd rows, cheap on any file.</summary>
    public const int SampleSize = 200;

    private static readonly string[] BooleanWords = ["true", "false", "yes", "no", "t", "f", "y", "n"];

    /// <summary>
    /// A text sample is an integer when every value parses as one, then a real, then a boolean word; anything else is
    /// text. Dates stay text, since a new column's date type differs too much between engines to propose blindly.
    /// </summary>
    public static ImportFieldType InferText(IEnumerable<string?> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        var sawValue = false;
        bool allInteger = true, allReal = true, allBoolean = true;
        var taken = 0;
        foreach (var value in values)
        {
            if (string.IsNullOrEmpty(value))
            {
                continue;
            }

            sawValue = true;
            var span = value.AsSpan();
            allInteger &= long.TryParse(span, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _);
            allReal &= double.TryParse(span, NumberStyles.Float, CultureInfo.InvariantCulture, out _);
            allBoolean &= IsBooleanWord(span);
            if (!allInteger && !allReal && !allBoolean || ++taken >= SampleSize)
            {
                break;
            }
        }

        if (!sawValue)
        {
            return ImportFieldType.Text;
        }

        return allInteger ? ImportFieldType.Integer : allReal ? ImportFieldType.Real : allBoolean ? ImportFieldType.Boolean : ImportFieldType.Text;
    }

    /// <summary>
    /// JSON values carry their own kind: integers, numbers, booleans and nested values each decide alone, and a mix,
    /// or a string, is text. A JSON string is never read as a number, as on macOS.
    /// </summary>
    public static ImportFieldType InferJson(IEnumerable<object?> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        var sawValue = false;
        bool allNested = true, allBoolean = true, allInteger = true, allNumber = true;
        foreach (var value in values)
        {
            if (value is null)
            {
                continue;
            }

            sawValue = true;
            var nested = value is JsonText;
            allNested &= nested;
            allBoolean &= value is bool;
            allInteger &= value is long;
            allNumber &= value is long or decimal or double;
        }

        if (!sawValue)
        {
            return ImportFieldType.Text;
        }

        return allNested ? ImportFieldType.Json : allBoolean ? ImportFieldType.Boolean : allInteger ? ImportFieldType.Integer : allNumber ? ImportFieldType.Real : ImportFieldType.Text;
    }

    private static bool IsBooleanWord(ReadOnlySpan<char> value)
    {
        foreach (var word in BooleanWords)
        {
            if (value.Equals(word, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }
}

/// <summary>A nested JSON object or array, kept as its JSON text so it can be told apart from a JSON string.</summary>
public sealed record JsonText(string Text)
{
    public override string ToString() => Text;
}

/// <summary>Names the fields of a file that has no header, or a header with blanks and repeats, as macOS does.</summary>
public static class ImportFieldNaming
{
    public static string Placeholder(int index) => string.Create(CultureInfo.InvariantCulture, $"Column {index + 1}");

    /// <summary>Header cells keep their trimmed text; a blank becomes <c>Column N</c> and a repeat gains a number.</summary>
    public static string[] UniqueNames(IReadOnlyList<string?> header)
    {
        ArgumentNullException.ThrowIfNull(header);
        var trimmed = new string[header.Count];
        var names = new string?[header.Count];
        var used = new HashSet<string>(StringComparer.Ordinal);
        for (var i = 0; i < trimmed.Length; i++)
        {
            trimmed[i] = header[i]?.Trim() ?? string.Empty;
            if (trimmed[i].Length > 0 && used.Add(trimmed[i]))
            {
                names[i] = trimmed[i];
            }
        }

        for (var i = 0; i < names.Length; i++)
        {
            if (names[i] is not null)
            {
                continue;
            }

            var baseName = trimmed[i].Length == 0 ? Placeholder(i) : trimmed[i];
            var unique = baseName;
            for (var suffix = 2; !used.Add(unique); suffix++)
            {
                unique = string.Create(CultureInfo.InvariantCulture, $"{baseName} {suffix}");
            }

            names[i] = unique;
        }

        return names!;
    }
}
