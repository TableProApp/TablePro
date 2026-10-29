using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using TablePro.Core.Import;
using TablePro.Storage.Connections;

namespace TablePro.Storage.Import;

/// <summary>The table a remembered import mapping belongs to.</summary>
public sealed record ImportMappingScope(Guid ConnectionId, string? Database, string? Schema, string Table);

/// <summary>One table's remembered mapping: each field that departed from the name match, and the column it went to or null for skipped.</summary>
public sealed record StoredImportMapping
{
    public Guid ConnectionId { get; init; }

    public string? Database { get; init; }

    public string? Schema { get; init; }

    public string Table { get; init; } = string.Empty;

    public Dictionary<string, string?> Fields { get; init; } = [];
}

public sealed record ImportMappingsDocument
{
    public List<StoredImportMapping> Mappings { get; init; } = [];
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(ImportMappingsDocument))]
internal sealed partial class ImportMappingJsonContext : JsonSerializerContext;

/// <summary>
/// Import mappings remembered per table in <c>import-mappings.json</c>, as the macOS app keeps them. Keyed by the table
/// rather than the file, because the same export is downloaded again under new names. Only departures from the name
/// match are stored, so a column the table gains later is still found by name.
/// </summary>
public sealed class ImportMappingStore : IDisposable
{
    public const string FileName = "import-mappings.json";

    private static JsonTypeInfo<ImportMappingsDocument> Json => ImportMappingJsonContext.Default.ImportMappingsDocument;

    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ImportMappingsDocument? _document;

    public ImportMappingStore(AppPaths paths)
        : this(Path.Combine((paths ?? throw new ArgumentNullException(nameof(paths))).Root, FileName))
    {
    }

    public ImportMappingStore(string filePath)
    {
        _path = Path.GetFullPath(filePath);
    }

    /// <summary>The overrides remembered for a table, empty when there are none.</summary>
    public async Task<IReadOnlyDictionary<string, ImportMappingOverride>> OverridesAsync(ImportMappingScope scope, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await LoadAsync(cancellationToken);
            return document.Mappings.FirstOrDefault(m => Matches(m, scope)) is { } stored ? ToOverrides(stored.Fields) : new Dictionary<string, ImportMappingOverride>();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Folds the overrides of one import into what the table already has: entries for fields this file does not hold
    /// stay, so several layouts into one table all come back. Nothing left to remember removes the table's entry.
    /// </summary>
    public async Task RememberAsync(
        ImportMappingScope scope,
        IReadOnlyDictionary<string, ImportMappingOverride> overrides,
        IReadOnlyList<string> fields,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(scope);
        ArgumentNullException.ThrowIfNull(overrides);
        ArgumentNullException.ThrowIfNull(fields);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await LoadAsync(cancellationToken);
            var list = document.Mappings.ToList();
            var index = list.FindIndex(m => Matches(m, scope));
            var saved = index >= 0 ? ToOverrides(list[index].Fields) : new Dictionary<string, ImportMappingOverride>();
            var merged = ImportColumnMatcher.Merging(overrides, fields, saved);
            if (index >= 0)
            {
                list.RemoveAt(index);
            }

            if (merged.Count > 0)
            {
                list.Add(new StoredImportMapping
                {
                    ConnectionId = scope.ConnectionId,
                    Database = scope.Database,
                    Schema = scope.Schema,
                    Table = scope.Table,
                    Fields = merged.ToDictionary(p => p.Key, p => p.Value.Column, StringComparer.Ordinal),
                });
            }

            var next = document with { Mappings = list };
            await AtomicFile.WriteJsonAsync(_path, next, Json, cancellationToken);
            _document = next;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Forgets every mapping a connection saved, because the connection is gone.</summary>
    public async Task ForgetConnectionAsync(Guid connectionId, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await LoadAsync(cancellationToken);
            var list = document.Mappings.Where(m => m.ConnectionId != connectionId).ToList();
            if (list.Count == document.Mappings.Count)
            {
                return;
            }

            var next = document with { Mappings = list };
            await AtomicFile.WriteJsonAsync(_path, next, Json, cancellationToken);
            _document = next;
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Forgets a connection's mappings once it leaves <paramref name="connections"/>, however it was deleted, as the
    /// macOS app purges a deleted connection's table settings. Only a connection the store listed and then lost
    /// counts, so the list being read for the first time forgets nothing. Disposing the result stops following.
    /// </summary>
    public IDisposable ForgetDeletedConnections(ConnectionStore connections)
    {
        ArgumentNullException.ThrowIfNull(connections);
        return new DeletionFollower(this, connections);
    }

    /// <summary>The forgetting the follower last started, so a test can wait for it.</summary>
    internal Task Forgetting { get; private set; } = Task.CompletedTask;

    public void Dispose() => _gate.Dispose();

    private async Task ForgetAllAsync(Task previous, IReadOnlyList<Guid> removed)
    {
        await previous;
        foreach (var id in removed)
        {
            try
            {
                await ForgetConnectionAsync(id);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // A mapping left behind only names a connection that no longer exists; it is never offered again.
            }
        }
    }

    private sealed class DeletionFollower : IDisposable
    {
        private readonly Lock _lock = new();
        private readonly ImportMappingStore _store;
        private readonly ConnectionStore _connections;
        private HashSet<Guid> _known;

        public DeletionFollower(ImportMappingStore store, ConnectionStore connections)
        {
            _store = store;
            _connections = connections;
            _known = Ids();
            connections.Changed += OnChanged;
        }

        public void Dispose() => _connections.Changed -= OnChanged;

        private HashSet<Guid> Ids() => [.. _connections.Connections.Select(c => c.Id)];

        // Changed fires on the saving thread, possibly two at once, so the snapshot moves under a lock.
        private void OnChanged(object? sender, EventArgs e)
        {
            lock (_lock)
            {
                var current = Ids();
                var removed = _known.Where(id => !current.Contains(id)).ToArray();
                _known = current;
                if (removed.Length > 0)
                {
                    _store.Forgetting = _store.ForgetAllAsync(_store.Forgetting, removed);
                }
            }
        }
    }

    private async Task<ImportMappingsDocument> LoadAsync(CancellationToken cancellationToken)
    {
        if (_document is null)
        {
            var read = await AtomicFile.ReadJsonAsync(_path, Json, prepare: null, cancellationToken) ?? new ImportMappingsDocument();

            // A hand-edited file can leave out the list or a table's fields; such an entry has nothing to restore.
            _document = read with
            {
                Mappings = [.. (read.Mappings ?? []).Where(m => m is not null && !string.IsNullOrEmpty(m.Table)).Select(m => m with { Fields = m.Fields ?? [] })],
            };
        }

        return _document;
    }

    private static bool Matches(StoredImportMapping stored, ImportMappingScope scope) =>
        stored.ConnectionId == scope.ConnectionId
        && string.Equals(stored.Database ?? string.Empty, scope.Database ?? string.Empty, StringComparison.Ordinal)
        && string.Equals(stored.Schema ?? string.Empty, scope.Schema ?? string.Empty, StringComparison.Ordinal)
        && string.Equals(stored.Table, scope.Table, StringComparison.Ordinal);

    private static Dictionary<string, ImportMappingOverride> ToOverrides(Dictionary<string, string?> fields) =>
        fields.ToDictionary(p => p.Key, p => new ImportMappingOverride(p.Value), StringComparer.Ordinal);
}
