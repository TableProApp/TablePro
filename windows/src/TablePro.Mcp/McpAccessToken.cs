using System.Security.Cryptography;
using System.Text;

namespace TablePro.Mcp;

/// <summary>
/// The bearer token every request carries. Any program of any user on the machine can reach 127.0.0.1, so the token
/// is what tells the user's own client apart from them.
/// </summary>
public sealed class McpAccessToken
{
    /// <summary>Marks the text as a TablePro token, so a secret scanner or a person reading a client's config can tell what it is.</summary>
    public const string Prefix = "tp_";

    private const int RandomBytes = 32;

    private readonly byte[] _utf8;

    private McpAccessToken(string value)
    {
        Value = value;
        _utf8 = Encoding.UTF8.GetBytes(value);
    }

    /// <summary>The token text the preferences page copies into a client's config and the vault stores.</summary>
    public string Value { get; }

    public static McpAccessToken Generate()
    {
        Span<byte> bytes = stackalloc byte[RandomBytes];
        RandomNumberGenerator.Fill(bytes);
        return new McpAccessToken(Prefix + Convert.ToHexStringLower(bytes));
    }

    /// <summary>A token read back from the vault. A blank one would let any <c>Bearer </c> header in, so it is refused.</summary>
    public static McpAccessToken? FromStored(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : new McpAccessToken(value.Trim());

    /// <summary>
    /// Whether an <c>Authorization</c> header value presents this token. The scheme is case-insensitive (RFC 9110,
    /// 11.1); the token is not. The comparison takes as long whatever the header holds, so timing a guess tells
    /// nothing about how much of it was right.
    /// </summary>
    public bool Authorizes(string? authorizationHeader)
    {
        if (authorizationHeader is null || authorizationHeader.Length <= 7
            || !authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var presented = authorizationHeader.AsSpan(7).Trim();
        if (presented.IsEmpty || presented.Length > 512)
        {
            return false;
        }

        Span<byte> buffer = stackalloc byte[Encoding.UTF8.GetMaxByteCount(presented.Length)];
        var written = Encoding.UTF8.GetBytes(presented, buffer);
        return CryptographicOperations.FixedTimeEquals(buffer[..written], _utf8);
    }

    public override string ToString() => "McpAccessToken(..)";
}
