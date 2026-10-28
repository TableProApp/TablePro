using TablePro.Mcp.Audit;

namespace TablePro.Mcp.Auth;

/// <summary>Why a presented token was refused.</summary>
public enum McpAuthFailure
{
    Unknown,
    Revoked,
    Expired,
}

/// <summary>
/// The paired clients, held in memory for the request path and saved through <see cref="IMcpHost"/>. Tokens are looked
/// up by their SHA-256: hashing the presented value first means the lookup's timing depends on a digest the caller
/// cannot steer, never on how much of a stored token a guess matched.
/// </summary>
public sealed class McpClientRegistry : IDisposable
{
    /// <summary>Stamping the last use on every request would write the vault on every request; once a minute is enough for the list.</summary>
    internal static readonly TimeSpan LastUsedSaveInterval = TimeSpan.FromSeconds(60);

    private readonly IMcpHost _host;
    private readonly Func<McpAuditEntry, ValueTask> _audit;
    private readonly TimeProvider _time;
    private readonly Lock _lock = new();
    private readonly SemaphoreSlim _writes = new(1, 1);
    private readonly Dictionary<Guid, McpClientGrant> _grants = [];
    private readonly Dictionary<string, Guid> _byHash = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, DateTimeOffset> _lastUseSaved = [];

    /// <param name="host">Where grants are loaded from and saved to.</param>
    /// <param name="audit">Where issue, revoke and delete are recorded. Null writes them straight to the host's persisted log.</param>
    /// <param name="time">The clock, which tests replace.</param>
    public McpClientRegistry(IMcpHost host, Func<McpAuditEntry, ValueTask>? audit = null, TimeProvider? time = null)
    {
        ArgumentNullException.ThrowIfNull(host);
        _host = host;
        _time = time ?? TimeProvider.System;
        _audit = audit ?? (entry => host.RecordAuditAsync(entry, CancellationToken.None));
    }

    /// <summary>Raised after a grant was added, changed or removed, on the thread that changed it.</summary>
    public event EventHandler? Changed;

    /// <summary>Every grant, revoked and expired ones included, oldest first.</summary>
    public IReadOnlyList<McpClientGrant> Clients
    {
        get
        {
            lock (_lock)
            {
                return [.. _grants.Values.OrderBy(g => g.CreatedAt).ThenBy(g => g.Id)];
            }
        }
    }

    public McpClientGrant? Find(Guid id)
    {
        lock (_lock)
        {
            return _grants.GetValueOrDefault(id);
        }
    }

    /// <summary>Replaces what is in memory with what the host has saved.</summary>
    public async Task ReloadAsync(CancellationToken cancellationToken = default)
    {
        var saved = await _host.LoadClientsAsync(cancellationToken);
        lock (_lock)
        {
            _grants.Clear();
            _byHash.Clear();
            foreach (var grant in saved)
            {
                Index(grant);
            }
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Mints a token for a client and saves its grant. The plaintext is in the result only.</summary>
    public async Task<McpIssuedToken> IssueAsync(
        string name,
        McpClientPermission permission,
        IReadOnlyCollection<Guid>? connectionIds,
        DateTimeOffset? expiresAt,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        var token = McpAccessToken.Generate().Value;
        var grant = new McpClientGrant
        {
            Id = Guid.NewGuid(),
            Name = name.Trim(),
            TokenHash = McpTokenHash.Of(token),
            TokenPrefix = token[..Math.Min(token.Length, 10)],
            Permission = permission,
            ConnectionIds = connectionIds is null ? null : [.. connectionIds.Distinct()],
            CreatedAt = _time.GetLocalNow(),
            ExpiresAt = expiresAt,
        };

        await SaveAsync(grant, cancellationToken);
        await _audit(Admin("client.created", grant, Describe(grant)));
        return new McpIssuedToken(grant, token);
    }

    /// <summary>
    /// The grant an <c>Authorization</c> header presents, with no failure when it may be used. A revoked or expired
    /// grant comes back with its failure, so the refusal can be logged against the client. A hit stamps the last use,
    /// saved at most once a minute per client; a failed save never fails the request it came with.
    /// </summary>
    public async ValueTask<(McpClientGrant? Grant, McpAuthFailure? Failure)> AuthenticateAsync(string? authorizationHeader, CancellationToken cancellationToken = default)
    {
        if (!McpTokenHash.TryReadBearer(authorizationHeader, out var presented))
        {
            return (null, McpAuthFailure.Unknown);
        }

        var hash = McpTokenHash.Of(presented);
        var now = _time.GetLocalNow();
        McpClientGrant? toSave = null;
        McpClientGrant grant;
        lock (_lock)
        {
            if (!_byHash.TryGetValue(hash, out var id) || !_grants.TryGetValue(id, out var found))
            {
                return (null, McpAuthFailure.Unknown);
            }

            if (found.IsRevoked)
            {
                return (found, McpAuthFailure.Revoked);
            }

            if (found.IsExpired(now))
            {
                return (found, McpAuthFailure.Expired);
            }

            grant = found with { LastUsedAt = now };
            _grants[id] = grant;
            if (!_lastUseSaved.TryGetValue(id, out var saved) || now - saved >= LastUsedSaveInterval)
            {
                _lastUseSaved[id] = now;
                toSave = grant;
            }
        }

        if (toSave is not null)
        {
            try
            {
                await PersistAsync(toSave.Id, cancellationToken);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // The last-used time is a convenience for the list, and the host's store may fail however its disk or
                // vault does; the request it rode in on still goes through.
                System.Diagnostics.Debug.WriteLine(ex.Message);
            }
        }

        return (grant, null);
    }

    /// <summary>Turns a client away from its next request. The grant stays listed as revoked.</summary>
    public async Task<bool> RevokeAsync(Guid id, CancellationToken cancellationToken = default)
    {
        McpClientGrant revoked;
        lock (_lock)
        {
            if (!_grants.TryGetValue(id, out var grant) || grant.IsRevoked)
            {
                return false;
            }

            revoked = grant with { RevokedAt = _time.GetLocalNow() };
            Index(revoked);
        }

        await PersistAsync(id, cancellationToken);
        Changed?.Invoke(this, EventArgs.Empty);
        await _audit(Admin("client.revoked", revoked, null));
        return true;
    }

    /// <summary>Forgets a grant and its token entirely. An active one is turned away as an unknown token.</summary>
    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        McpClientGrant? removed;
        lock (_lock)
        {
            if (!_grants.Remove(id, out removed))
            {
                return false;
            }

            if (removed.TokenHash is { } hash)
            {
                _byHash.Remove(hash);
            }

            _lastUseSaved.Remove(id);
        }

        await _writes.WaitAsync(cancellationToken);
        try
        {
            await _host.DeleteClientAsync(id, cancellationToken);
        }
        finally
        {
            _writes.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
        await _audit(Admin("client.deleted", removed, null));
        return true;
    }

    public void Dispose() => _writes.Dispose();

    internal static string Describe(McpClientGrant grant) =>
        $"{(grant.Permission == McpClientPermission.ReadWrite ? "read and write" : "read only")}, " +
        $"{(grant.ConnectionIds is null ? "all connections" : grant.ConnectionIds.Count == 1 ? "1 connection" : $"{grant.ConnectionIds.Count} connections")}" +
        (grant.ExpiresAt is { } expiry ? $", until {expiry:yyyy-MM-dd}" : string.Empty);

    private async Task SaveAsync(McpClientGrant grant, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            Index(grant);
        }

        await PersistAsync(grant.Id, cancellationToken);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private async Task PersistAsync(Guid id, CancellationToken cancellationToken)
    {
        // One write at a time, each of the grant as it is now, so a last-used stamp taken before a revoke cannot land
        // after it and bring the grant back.
        await _writes.WaitAsync(cancellationToken);
        try
        {
            var current = Find(id);
            if (current is null)
            {
                return;
            }

            await _host.SaveClientAsync(current, cancellationToken);
        }
        finally
        {
            _writes.Release();
        }
    }

    private void Index(McpClientGrant grant)
    {
        if (_grants.TryGetValue(grant.Id, out var previous) && previous.TokenHash is { } oldHash)
        {
            _byHash.Remove(oldHash);
        }

        _grants[grant.Id] = grant;
        if (grant.TokenHash is { Length: > 0 } hash)
        {
            _byHash[hash] = grant.Id;
        }
    }

    private McpAuditEntry Admin(string action, McpClientGrant grant, string? message) =>
        new(_time.GetLocalNow(), action, null, null, McpAuditOutcome.Succeeded, null, message, null, TimeSpan.Zero, grant.Id, grant.Name, McpAuditCategory.Admin);
}
