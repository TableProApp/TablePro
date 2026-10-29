namespace TablePro.Core.Licensing;

/// <summary>What went wrong with a license operation; the app words each one for the screen.</summary>
public enum LicenseErrorKind
{
    InvalidKey,
    SignatureInvalid,
    MachineMismatch,
    PublicKeyInvalid,
    ActivationLimitReached,
    LicenseExpired,
    LicenseSuspended,
    NotActivated,
    Network,
    Server,
    Decoding,

    /// <summary>A seat was given up here but the server never confirmed it, so it may stay taken until it lapses.</summary>
    SeatReleaseUnconfirmed,
}

public sealed class LicenseException : Exception
{
    public LicenseException()
        : this(LicenseErrorKind.Server, "The license operation failed.")
    {
    }

    public LicenseException(string message)
        : this(LicenseErrorKind.Server, message)
    {
    }

    public LicenseException(string message, Exception innerException)
        : this(LicenseErrorKind.Network, message, innerException)
    {
    }

    public LicenseException(LicenseErrorKind kind, string message, Exception? innerException = null, int? statusCode = null)
        : base(message, innerException)
    {
        Kind = kind;
        StatusCode = statusCode;
    }

    public LicenseErrorKind Kind { get; }

    /// <summary>The HTTP status of a <see cref="LicenseErrorKind.Server"/> failure.</summary>
    public int? StatusCode { get; }
}
