using System.Globalization;

namespace TablePro.App.Model;

// A size as File Explorer words one: bytes below 1 KB, then KB, MB, GB and TB of 1,024 each, to one decimal.
public static class ByteSize
{
    private static readonly string[] Units = ["KB", "MB", "GB", "TB", "PB"];

    public static string Format(long bytes, string bytesPattern, IFormatProvider? culture = null)
    {
        ArgumentNullException.ThrowIfNull(bytesPattern);
        culture ??= CultureInfo.CurrentCulture;
        if (bytes < 1024)
        {
            return string.Format(culture, bytesPattern, bytes);
        }

        var value = (double)bytes;
        var unit = -1;
        do
        {
            value /= 1024;
            unit++;
        }
        while (value >= 1024 && unit < Units.Length - 1);

        return string.Create(culture, $"{value:0.#} {Units[unit]}");
    }
}

// A TextBox keeps each line break as CR, so a value edited there gets back the line break style it opened with; one
// that had none takes LF, the break a database's own clients write.
public static class LineBreaks
{
    public static string Of(string? original) =>
        original is null ? "\n"
        : original.Contains("\r\n", StringComparison.Ordinal) ? "\r\n"
        : original.Contains('\n', StringComparison.Ordinal) ? "\n"
        : original.Contains('\r', StringComparison.Ordinal) ? "\r"
        : "\n";

    public static string Restore(string boxText, string newline)
    {
        ArgumentNullException.ThrowIfNull(boxText);
        ArgumentNullException.ThrowIfNull(newline);
        return boxText.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r')
            .Replace("\r", newline, StringComparison.Ordinal);
    }
}
