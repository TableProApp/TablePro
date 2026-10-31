using System.Text.Json;
using System.Text.Json.Serialization;
using TablePro.Core.Connections;

namespace TablePro.Storage.Connections;

/// <summary>
/// The SQLite extensions a person has agreed to load on this PC, per connection, in
/// <c>loadable_extension_approvals.json</c>.
/// </summary>
/// <remarks>
/// An extension is native code that runs inside TablePro, and a connection's list travels through exports, imports and
/// the team library. So the list alone never authorizes a load: an entry loads only once it was added in the
/// connection form on this PC or confirmed in the prompt a connect shows. Approval is keyed to the connection as well
/// as the file, so trusting a library for one connection does not approve it for another that arrives later naming
/// the same path. The file is never exported, which is what makes a list that arrived from elsewhere ask first.
/// </remarks>
public sealed class LoadableExtensionApprovalStore : IDisposable
{
    private static readonly Lazy<LoadableExtensionApprovalStore> DefaultStore = new(() => new LoadableExtensionApprovalStore(AppPaths.Default));

    private readonly string _path;
    private readonly Lock _lock = new();
    private readonly SemaphoreSlim _write = new(1, 1);
    private Dictionary<Guid, HashSet<LoadableExtension>>? _approvals;

    public LoadableExtensionApprovalStore(AppPaths paths)
    {
        ArgumentNullException.ThrowIfNull(paths);
        _path = Path.Combine(paths.Root, "loadable_extension_approvals.json");
    }

    public static LoadableExtensionApprovalStore Default => DefaultStore.Value;

    /// <summary>The entries of <paramref name="extensions"/> this PC has not approved for the connection.</summary>
    public IReadOnlyList<LoadableExtension> Unapproved(IEnumerable<LoadableExtension> extensions, Guid connectionId)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        lock (_lock)
        {
            var approved = Approvals().GetValueOrDefault(connectionId);
            return [.. extensions.Where(e => approved is null || !approved.Contains(e.Canonical()))];
        }
    }

    /// <summary>
    /// The declared extensions of <paramref name="profile"/> still to be approved. Nothing stored with the connection
    /// exempts a list, since every field of it can arrive from an import. A list that fails validation is not asked
    /// about, because the connect refuses it before loading anything, and a path with a line break in it could
    /// otherwise write its own lines into the prompt.
    /// </summary>
    public IReadOnlyList<LoadableExtension> Pending(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        IReadOnlyList<LoadableExtension> declared;
        try
        {
            declared = LoadableExtensionList.Declared(profile);
            LoadableExtensionPreflight.Validate(declared);
        }
        catch (LoadableExtensionException)
        {
            return [];
        }

        return declared.Count == 0 ? [] : Unapproved(declared, profile.Id);
    }

    public Task ApproveAsync(IEnumerable<LoadableExtension> extensions, Guid connectionId, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(extensions);
        var added = false;
        lock (_lock)
        {
            var all = Approvals();
            foreach (var item in extensions)
            {
                if (!all.TryGetValue(connectionId, out var set))
                {
                    set = [];
                    all[connectionId] = set;
                }

                added |= set.Add(item.Canonical());
            }
        }

        return added ? SaveAsync(cancellationToken) : Task.CompletedTask;
    }

    /// <summary>Forgets what was approved for the connections, as when they are deleted.</summary>
    public Task RevokeAsync(IEnumerable<Guid> connectionIds, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(connectionIds);
        var removed = false;
        lock (_lock)
        {
            var all = Approvals();
            foreach (var id in connectionIds)
            {
                removed |= all.Remove(id);
            }
        }

        return removed ? SaveAsync(cancellationToken) : Task.CompletedTask;
    }

    private Dictionary<Guid, HashSet<LoadableExtension>> Approvals()
    {
        if (_approvals is not null)
        {
            return _approvals;
        }

        _approvals = [];
        try
        {
            using var stream = File.OpenRead(_path);
            var document = JsonSerializer.Deserialize(stream, ApprovalJsonContext.Default.ApprovalDocument);
            foreach (var (id, entries) in document?.Connections ?? [])
            {
                _approvals[id] = [.. entries.Where(e => !string.IsNullOrEmpty(e.Path)).Select(e => new LoadableExtension(e.Path, e.EntryPoint).Canonical())];
            }
        }
        catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException or JsonException)
        {
            // No file, or one that no longer parses, approves nothing: every list asks again, which is the safe side.
        }

        return _approvals;
    }

    public void Dispose() => _write.Dispose();

    // Writes take turns and each writes the state as it is when its turn comes, so the last answer is what stays on disk.
    private async Task SaveAsync(CancellationToken cancellationToken)
    {
        await _write.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            ApprovalDocument document;
            lock (_lock)
            {
                document = new ApprovalDocument
                {
                    Connections = Approvals()
                        .Where(p => p.Value.Count > 0)
                        .ToDictionary(p => p.Key, p => p.Value.Select(e => new ApprovedExtension { Path = e.Path, EntryPoint = e.EntryPoint }).ToList()),
                };
            }

            if (document.Connections.Count == 0)
            {
                File.Delete(_path);
                return;
            }

            await AtomicFile.WriteJsonAsync(_path, document, ApprovalJsonContext.Default.ApprovalDocument, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _write.Release();
        }
    }
}

internal sealed class ApprovalDocument
{
    public Dictionary<Guid, List<ApprovedExtension>> Connections { get; set; } = [];
}

internal sealed class ApprovedExtension
{
    public string Path { get; set; } = string.Empty;

    public string? EntryPoint { get; set; }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull)]
[JsonSerializable(typeof(ApprovalDocument))]
internal sealed partial class ApprovalJsonContext : JsonSerializerContext;
