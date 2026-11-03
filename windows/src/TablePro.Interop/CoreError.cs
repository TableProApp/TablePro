namespace TablePro.Interop;

/// <summary>
/// The app words an error from <see cref="Code"/>, the innermost of <see cref="Codes"/>, which run from the
/// outermost error in. <see cref="Message"/> is English, for the log.
/// </summary>
public sealed record CoreError(
    string Code,
    IReadOnlyList<string> Codes,
    string Message,
    ServerMessage? Server,
    string? Path,
    SecretKind? Secret = null);

/// <summary>What the server said, which the app shows as it came.</summary>
public sealed record ServerMessage(
    string Message,
    string? Code,
    string? SqlState,
    string? Detail,
    string? Hint,
    int? Position);

public sealed class TableProException : Exception
{
    public TableProException(CoreError error)
        : base((error ?? throw new ArgumentNullException(nameof(error))).Message)
    {
        Error = error;
    }

    public CoreError Error { get; }

    public string Code => Error.Code;
}
