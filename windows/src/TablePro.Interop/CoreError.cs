namespace TablePro.Interop;

// The app words Code, the innermost of Codes, which run from the outermost error in. Message is English, for the log.
public sealed record CoreError(
    string Code,
    IReadOnlyList<string> Codes,
    string Message,
    ServerMessage? Server,
    string? Path,
    SecretKind? Secret = null,
    HostKeyFailure? HostKey = null)
{
    public TlsFailure? TlsFailure { get; init; }

    // What an ai.* error is about: its host, status and provider.
    public AiFailure? Ai { get; init; }

    // What a refused sync.* call carries beyond its code.
    public SyncFailure? Sync { get; init; }

    // RFC 9470's challenge of account.step_up_required or sync.step_up_required, which TableProAccount.StepUpAsync takes.
    public StepUpChallenge? StepUp { get; init; }
}

// The methods the sign-in page asks for and the most age the sign-in may have.
public sealed record StepUpChallenge(IReadOnlyList<string> AcrValues, TimeSpan? MaxAge);

public sealed record HostKeyFailure(
    string Host,
    string Algorithm,
    string Fingerprint,
    string KnownHosts,
    ulong Line,
    bool TrustAllowed);

// What the server said, which the app shows as it came.
public sealed record ServerMessage(
    string Message,
    string? Code,
    string? SqlState,
    string? Detail,
    string? Hint,
    // In characters from 1, from the start of the SQL the run was given.
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
