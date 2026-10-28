namespace TablePro.Drivers.MongoDb.Shell;

/// <summary>A statement the shell reader refused, with the place it stopped so the editor can point at it.</summary>
public sealed class ShellSyntaxException : FormatException
{
    public ShellSyntaxException()
    {
    }

    public ShellSyntaxException(string message)
        : base(message)
    {
    }

    public ShellSyntaxException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    internal ShellSyntaxException(string reason, string text, int position)
        : base(Describe(reason, text, position))
    {
        Reason = reason;
        Position = Math.Clamp(position, 0, text.Length);
        (Line, Column) = LineAndColumn(text, Position);
    }

    /// <summary>What is wrong, without the place.</summary>
    public string Reason { get; } = string.Empty;

    /// <summary>The offset in the statement, from 0.</summary>
    public int Position { get; }

    /// <summary>The line, from 1.</summary>
    public int Line { get; } = 1;

    /// <summary>The column, from 1.</summary>
    public int Column { get; } = 1;

    private static string Describe(string reason, string text, int position)
    {
        var (line, column) = LineAndColumn(text, Math.Clamp(position, 0, text.Length));
        return $"SyntaxError: {reason} (line {line}, column {column})";
    }

    private static (int Line, int Column) LineAndColumn(string text, int position)
    {
        var line = 1;
        var lineStart = 0;
        for (var i = 0; i < position && i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                line++;
                lineStart = i + 1;
            }
        }

        return (line, position - lineStart + 1);
    }
}

/// <summary>A statement that reads correctly but asks for something the interpreter does not run.</summary>
public sealed class ShellUnsupportedException : NotSupportedException
{
    public ShellUnsupportedException()
    {
    }

    public ShellUnsupportedException(string message)
        : base(message)
    {
    }

    public ShellUnsupportedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
