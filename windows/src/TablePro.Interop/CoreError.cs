namespace TablePro.Interop;

// The app words Code, the innermost of Codes, which run from the outermost error in. Message is English, for the log.
public sealed record CoreError(
    string Code,
    IReadOnlyList<string> Codes,
    string Message,
    ServerMessage? Server,
    string? Path,
    SecretKind? Secret = null)
{
    public TlsFailure? TlsFailure { get; init; }
}

// What the server said, which the app shows as it came.
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

public enum TlsFailure
{
    UnknownIssuer,
    NameMismatch,
    Expired,
    NotYetValid,
    Revoked,
    ServerRefusedTls,
    ServerRequiresTls,
    ServerRefusedStrict,
    ServerRequiresStrict,
    HandshakeRejected,
    CaFileInvalid,
    ClientIdentityInvalid,
    Other,
}
