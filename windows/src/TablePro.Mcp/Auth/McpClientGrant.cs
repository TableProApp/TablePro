using System.Security.Cryptography;
using System.Text;
using TablePro.Core.Connections;

namespace TablePro.Mcp.Auth;

/// <summary>The most a paired client may do. A connection's External Clients level still applies on top of it.</summary>
public enum McpClientPermission
{
    ReadOnly,
    ReadWrite,
}

/// <summary>
/// One paired client: the name it asked under, what the user granted, and the hash of the token it was issued. The
/// token itself is shown once, at pairing, and never kept.
/// </summary>
public sealed record McpClientGrant
{
    public required Guid Id { get; init; }

    public required string Name { get; init; }

    /// <summary>
    /// SHA-256 of the token, lowercase hex. Null when the vault lost it (the user removed the credential by hand); such a
    /// grant authorizes nothing and can only be removed.
    /// </summary>
    public string? TokenHash { get; init; }

    /// <summary>The token's first characters, so the user can match a grant to the client config that holds it.</summary>
    public string TokenPrefix { get; init; } = string.Empty;

    public McpClientPermission Permission { get; init; }

    /// <summary>The connections the grant reaches. Null means every connection whose External Clients level lets clients in.</summary>
    public IReadOnlyList<Guid>? ConnectionIds { get; init; }

    public DateTimeOffset CreatedAt { get; init; }

    public DateTimeOffset? LastUsedAt { get; init; }

    public DateTimeOffset? ExpiresAt { get; init; }

    /// <summary>Set by a revoke. A revoked grant stays listed, so the user can still tell who once had access.</summary>
    public DateTimeOffset? RevokedAt { get; init; }

    public bool IsRevoked => RevokedAt is not null;

    public bool IsExpired(DateTimeOffset now) => ExpiresAt is { } expiry && now >= expiry;

    public bool IsActive(DateTimeOffset now) => !IsRevoked && !IsExpired(now) && TokenHash is not null;
}

/// <summary>A token just issued: the grant to keep and the plaintext to hand to the client once.</summary>
public sealed record McpIssuedToken(McpClientGrant Grant, string Token)
{
    public override string ToString() => $"McpIssuedToken({Grant.Name}, ..)";
}

/// <summary>Who made a request: the owner's settings token or a paired client, and what that caller may reach.</summary>
public sealed record McpPrincipal(Guid? ClientId, string Name, McpClientPermission Permission, IReadOnlySet<Guid>? ConnectionIds)
{
    /// <summary>The single token on the settings page. It predates pairing and keeps the reach it always had.</summary>
    public static McpPrincipal Owner { get; } = new(null, "Access token", McpClientPermission.ReadWrite, null);

    public static McpPrincipal For(McpClientGrant grant)
    {
        ArgumentNullException.ThrowIfNull(grant);
        return new McpPrincipal(grant.Id, grant.Name, grant.Permission, grant.ConnectionIds is null ? null : grant.ConnectionIds.ToHashSet());
    }

    /// <summary>
    /// The profile as this caller may see it: null when the grant does not reach it, otherwise the profile with its
    /// External Clients level lowered to the grant's ceiling. Lowering the level, rather than checking the grant in each
    /// tool, means every existing refusal (and the level <c>list_connections</c> reports) already accounts for it.
    /// </summary>
    public ConnectionProfile? Apply(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (ConnectionIds is not null && !ConnectionIds.Contains(profile.Id))
        {
            return null;
        }

        return Permission == McpClientPermission.ReadOnly && profile.ExternalAccess == ExternalAccessLevel.ReadWrite
            ? profile with { ExternalAccess = ExternalAccessLevel.ReadOnly }
            : profile;
    }
}

internal static class McpTokenHash
{
    public static string Of(ReadOnlySpan<char> token)
    {
        Span<byte> utf8 = token.Length <= 256 ? stackalloc byte[Encoding.UTF8.GetMaxByteCount(token.Length)] : new byte[Encoding.UTF8.GetMaxByteCount(token.Length)];
        var written = Encoding.UTF8.GetBytes(token, utf8);
        Span<byte> digest = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(utf8[..written], digest);
        return Convert.ToHexStringLower(digest);
    }

    /// <summary>The token a <c>Bearer</c> header presents, or false. The scheme is case-insensitive (RFC 9110, 11.1).</summary>
    public static bool TryReadBearer(string? authorizationHeader, out ReadOnlySpan<char> token)
    {
        token = default;
        if (authorizationHeader is null || authorizationHeader.Length <= 7
            || !authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        token = authorizationHeader.AsSpan(7).Trim();
        return !token.IsEmpty && token.Length <= 512;
    }
}
