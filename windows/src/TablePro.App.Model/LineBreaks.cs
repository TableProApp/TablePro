namespace TablePro.App.Model;

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
