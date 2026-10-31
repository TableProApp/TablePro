using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;

namespace TablePro.Mcp.Auth;

/// <summary>
/// RFC 7636 fixes both halves of PKCE: the verifier is 43 to 128 characters of the unreserved set, and the S256
/// challenge is its unpadded base64url SHA-256, always 43 characters. Anything else is not a PKCE exchange and is
/// refused before it reaches a comparison.
/// </summary>
public static class McpPkce
{
    public const int MinimumVerifierLength = 43;
    public const int MaximumVerifierLength = 128;
    public const int ChallengeLength = 43;

    public static bool IsValidVerifier(string? verifier) =>
        verifier is { Length: >= MinimumVerifierLength and <= MaximumVerifierLength } && verifier.All(IsUnreserved);

    public static bool IsValidChallenge(string? challenge) =>
        challenge is { Length: ChallengeLength } && challenge.All(IsBase64Url);

    /// <summary>The S256 challenge of a verifier.</summary>
    public static string ChallengeOf(string verifier)
    {
        ArgumentNullException.ThrowIfNull(verifier);
        Span<byte> digest = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(Encoding.ASCII.GetBytes(verifier), digest);
        return Base64Url.EncodeToString(digest);
    }

    private static bool IsUnreserved(char c) => char.IsAsciiLetterOrDigit(c) || c is '-' or '.' or '_' or '~';

    private static bool IsBase64Url(char c) => char.IsAsciiLetterOrDigit(c) || c is '-' or '_';
}

internal enum McpCodeOutcome
{
    Exchanged,
    NotFound,
    Expired,
    Mismatch,
}

/// <summary>A code waiting for its exchange: the token it releases and the challenge that guards it.</summary>
internal sealed record McpPendingCode(Guid ClientId, string ClientName, string Token, McpClientPermission Permission, string Challenge, DateTimeOffset ExpiresAt)
{
    public override string ToString() => $"McpPendingCode({ClientName}, ..)";
}

/// <summary>
/// Codes issued by approved pairings, each exchangeable once for its token. A failed verification burns the code:
/// PKCE protects the exchange only while each code allows one attempt, and a code left alive after a mismatch would
/// turn the five-minute window into a guessing game the caller can retry without limit.
/// </summary>
internal sealed class McpPairingCodes(TimeProvider time)
{
    public static readonly TimeSpan ExchangeWindow = TimeSpan.FromMinutes(5);

    public const int MaxPendingCodes = 50;

    private readonly Dictionary<string, McpPendingCode> _pending = new(StringComparer.Ordinal);
    private readonly Lock _lock = new();

    public int Count
    {
        get
        {
            lock (_lock)
            {
                return _pending.Count;
            }
        }
    }

    /// <summary>A fresh code for the record, or null when too many codes are already waiting.</summary>
    /// <param name="record">What the code releases.</param>
    /// <param name="expired">The codes that ran out unexchanged on the way, whose grants nobody holds a token for.</param>
    public string? Insert(McpPendingCode record, out IReadOnlyList<McpPendingCode> expired)
    {
        lock (_lock)
        {
            expired = PruneLocked(time.GetLocalNow());
            if (_pending.Count >= MaxPendingCodes)
            {
                return null;
            }

            Span<byte> bytes = stackalloc byte[32];
            RandomNumberGenerator.Fill(bytes);
            var code = Base64Url.EncodeToString(bytes);
            _pending[code] = record;
            return code;
        }
    }

    public McpCodeOutcome Consume(string code, string verifier, out McpPendingCode? record)
    {
        ArgumentNullException.ThrowIfNull(code);
        ArgumentNullException.ThrowIfNull(verifier);
        record = null;
        var now = time.GetLocalNow();
        lock (_lock)
        {
            if (!_pending.Remove(code, out var entry))
            {
                return McpCodeOutcome.NotFound;
            }

            if (entry.ExpiresAt <= now)
            {
                record = entry;
                return McpCodeOutcome.Expired;
            }

            var computed = Encoding.ASCII.GetBytes(McpPkce.ChallengeOf(verifier));
            var expected = Encoding.ASCII.GetBytes(entry.Challenge);
            if (!CryptographicOperations.FixedTimeEquals(computed, expected))
            {
                record = entry;
                return McpCodeOutcome.Mismatch;
            }

            record = entry;
            return McpCodeOutcome.Exchanged;
        }
    }

    public bool Discard(string code)
    {
        lock (_lock)
        {
            return _pending.Remove(code);
        }
    }

    public IReadOnlyList<McpPendingCode> PruneExpired()
    {
        lock (_lock)
        {
            return PruneLocked(time.GetLocalNow());
        }
    }

    private List<McpPendingCode> PruneLocked(DateTimeOffset now)
    {
        List<McpPendingCode> expired = [];
        foreach (var (code, entry) in _pending.ToArray())
        {
            if (entry.ExpiresAt <= now)
            {
                _pending.Remove(code);
                expired.Add(entry);
            }
        }

        return expired;
    }
}

/// <summary>
/// Counts failures in a sliding window and locks the door for a while once there are too many. Every caller is on
/// 127.0.0.1, so the count is for the whole server rather than per address.
/// </summary>
internal sealed class McpFailureLimiter(int maxFailures, TimeSpan window, TimeSpan lockout, TimeProvider time)
{
    private readonly Queue<DateTimeOffset> _failures = new();
    private readonly Lock _lock = new();
    private DateTimeOffset? _lockedUntil;

    /// <summary>How long the door stays shut, or null when it is open.</summary>
    public TimeSpan? LockedFor()
    {
        var now = time.GetLocalNow();
        lock (_lock)
        {
            if (_lockedUntil is { } until && until > now)
            {
                return until - now;
            }

            _lockedUntil = null;
            return null;
        }
    }

    public void RecordFailure()
    {
        var now = time.GetLocalNow();
        lock (_lock)
        {
            while (_failures.Count > 0 && now - _failures.Peek() > window)
            {
                _failures.Dequeue();
            }

            _failures.Enqueue(now);
            if (_failures.Count >= maxFailures)
            {
                _lockedUntil = now + lockout;
                _failures.Clear();
            }
        }
    }

    public void RecordSuccess()
    {
        lock (_lock)
        {
            _failures.Clear();
        }
    }
}
