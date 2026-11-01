using System.Collections.Concurrent;
using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Mcp;

/// <summary>A paired MCP client as saved: everything but the token hash, which lives in Credential Manager.</summary>
public sealed record StoredMcpClient
{
    public required Guid Id { get; init; }

    public required string Name { get; init; }

    /// <summary>SHA-256 of the client's token. Read from and written to the vault, never to the JSON file.</summary>
    [JsonIgnore]
    public string? TokenHash { get; init; }

    public string TokenPrefix { get; init; } = string.Empty;

    /// <summary><c>ReadOnly</c> or <c>ReadWrite</c>; the MCP layer owns the meaning.</summary>
    public string Permission { get; init; } = "ReadOnly";

    /// <summary>Null means every connection.</summary>
    public IReadOnlyList<Guid>? ConnectionIds { get; init; }

    public DateTimeOffset CreatedAt { get; init; }

    public DateTimeOffset? LastUsedAt { get; init; }

    public DateTimeOffset? ExpiresAt { get; init; }

    public DateTimeOffset? RevokedAt { get; init; }
}

/// <summary>
/// Paired MCP clients in <c>mcp-clients.json</c>, with each client's token hash in Windows Credential Manager under
/// <see cref="SecretKey"/>. Credential Manager holds at most 2,560 bytes per entry, too little for the whole list, so
/// the list goes to a file and only the part worth guarding goes to the vault. The token itself is stored nowhere:
/// the client got it once, at pairing.
/// </summary>
/// <remarks>
/// Every change reads, edits and replaces the file under one gate per file, shared by every instance in the process,
/// so the settings page and the server can each hold a store without overwriting each other's changes.
/// </remarks>
public sealed class McpClientStore
{
    private static readonly ConcurrentDictionary<string, SemaphoreSlim> Gates = new(StringComparer.OrdinalIgnoreCase);

    private readonly string _path;
    private readonly ISecretStore _secrets;
    private readonly SemaphoreSlim _gate;

    public McpClientStore(AppPaths paths, ISecretStore secrets)
        : this(Path.Combine(paths.Root, "mcp-clients.json"), secrets)
    {
    }

    /// <param name="path">The JSON file, created on the first save.</param>
    /// <param name="secrets">Where token hashes go.</param>
    public McpClientStore(string path, ISecretStore secrets)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        ArgumentNullException.ThrowIfNull(secrets);
        _path = Path.GetFullPath(path);
        _secrets = secrets;
        _gate = Gates.GetOrAdd(_path, _ => new SemaphoreSlim(1, 1));
    }

    /// <summary>Fires after a save or delete, on the saving thread.</summary>
    public event EventHandler? Changed;

    public string FilePath => _path;

    public static string SecretKey(Guid clientId) => SecretKeys.Prefix + "mcp/client/" + clientId.ToString("D");

    /// <summary>Every saved client with its hash read back from the vault. A hash the vault lost reads as null.</summary>
    public async Task<IReadOnlyList<StoredMcpClient>> LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await ReadAsync(cancellationToken);
            return [.. document.Clients.Select(c => c with { TokenHash = ReadHash(c.Id) })];
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Adds the client or replaces the one with its id. A hash that differs from the vault's is written there first.</summary>
    public async Task SaveAsync(StoredMcpClient client, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(client);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (client.TokenHash is { Length: > 0 } hash && !string.Equals(ReadHash(client.Id), hash, StringComparison.Ordinal))
            {
                // The vault first: a crash between the two writes leaves an unused vault entry, never a listed client
                // whose token cannot be checked.
                _secrets.Set(SecretKey(client.Id), hash);
            }

            var document = await ReadAsync(cancellationToken);
            var clients = document.Clients.Where(c => c.Id != client.Id).Append(client with { TokenHash = null }).ToList();
            await AtomicFile.WriteJsonAsync(_path, document with { Clients = clients }, McpStorageJsonContext.Default.McpClientsDocument, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <returns>False when no client had the id.</returns>
    public async Task<bool> DeleteAsync(Guid clientId, CancellationToken cancellationToken = default)
    {
        bool removed;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await ReadAsync(cancellationToken);
            var clients = document.Clients.Where(c => c.Id != clientId).ToList();
            removed = clients.Count != document.Clients.Count;
            if (removed)
            {
                await AtomicFile.WriteJsonAsync(_path, document with { Clients = clients }, McpStorageJsonContext.Default.McpClientsDocument, cancellationToken);
            }

            // Also when the file had no row: a vault entry left by an interrupted save should not outlive it.
            removed |= _secrets.Delete(SecretKey(clientId));
        }
        finally
        {
            _gate.Release();
        }

        if (removed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }

        return removed;
    }

    private async Task<McpClientsDocument> ReadAsync(CancellationToken cancellationToken) =>
        await AtomicFile.ReadJsonAsync(_path, McpStorageJsonContext.Default.McpClientsDocument, null, cancellationToken) ?? new McpClientsDocument();

    private string? ReadHash(Guid clientId)
    {
        try
        {
            return _secrets.Get(SecretKey(clientId)) is { Length: > 0 } hash ? hash : null;
        }
        catch (Win32Exception)
        {
            // One unreadable entry costs that client, not the whole list.
            return null;
        }
    }
}

internal sealed record McpClientsDocument
{
    public int Version { get; init; } = 1;

    public List<StoredMcpClient> Clients { get; init; } = [];
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(McpClientsDocument))]
internal sealed partial class McpStorageJsonContext : JsonSerializerContext;
