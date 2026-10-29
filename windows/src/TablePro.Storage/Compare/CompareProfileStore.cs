using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace TablePro.Storage.Compare;

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UseStringEnumConverter = true,
    WriteIndented = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    AllowTrailingCommas = true,
    ReadCommentHandling = JsonCommentHandling.Skip)]
[JsonSerializable(typeof(CompareProfilesDocument))]
internal sealed partial class CompareJsonContext : JsonSerializerContext;

/// <summary>
/// Saved comparisons in <c>compare-profiles.json</c>, as the other stores keep theirs: a change reaches the disk before
/// the in-memory list moves, and <see cref="Changed"/> fires on the saving thread.
/// </summary>
public sealed class CompareProfileStore : IDisposable
{
    public const string FileName = "compare-profiles.json";

    private static JsonTypeInfo<CompareProfilesDocument> Json => CompareJsonContext.Default.CompareProfilesDocument;

    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private CompareProfilesDocument _document = new();
    private Task? _load;

    public CompareProfileStore(AppPaths paths)
        : this(Path.Combine((paths ?? throw new ArgumentNullException(nameof(paths))).Root, FileName))
    {
    }

    public CompareProfileStore(string filePath)
    {
        _path = Path.GetFullPath(filePath);
    }

    public event EventHandler? Changed;

    /// <summary>Every saved comparison, by name, not only those for one connection: loading one sets both sides.</summary>
    public IReadOnlyList<CompareProfile> Profiles => Volatile.Read(ref _document).Profiles;

    public CompareProfile? Find(Guid id) => Profiles.FirstOrDefault(p => p.Id == id);

    public CompareProfile? FindByName(string name) =>
        Profiles.FirstOrDefault(p => string.Equals(p.Name, name.Trim(), StringComparison.CurrentCultureIgnoreCase));

    /// <summary>
    /// Reads the file once; later calls wait for the same read. The read is not tied to the first caller's token, so
    /// one cancelled caller cannot leave every later one with a cancelled load.
    /// </summary>
    public Task EnsureLoadedAsync() =>
        LazyInitializer.EnsureInitialized(ref _load, () => LoadAsync(CancellationToken.None));

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await AtomicFile.ReadJsonAsync(_path, Json, RestoreDefaults, cancellationToken) ?? new CompareProfilesDocument();
            Volatile.Write(ref _document, Normalize(document));
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Adds or replaces a profile by id, trimming its name and stamping <see cref="CompareProfile.UpdatedAt"/>.</summary>
    public async Task<CompareProfile> SaveAsync(CompareProfile profile, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var name = profile.Name?.Trim();
        if (string.IsNullOrEmpty(name))
        {
            throw new ArgumentException("A saved comparison needs a name.", nameof(profile));
        }

        var saved = profile with { Name = name, UpdatedAt = DateTimeOffset.UtcNow };
        await MutateAsync(document =>
        {
            var list = document.Profiles.ToList();
            var index = list.FindIndex(p => p.Id == saved.Id);
            if (index >= 0)
            {
                saved = saved with { CreatedAt = list[index].CreatedAt };
                list[index] = saved;
            }
            else
            {
                list.Add(saved);
            }

            return document with { Profiles = Sorted(list) };
        }, cancellationToken);
        return saved;
    }

    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = false;
        await MutateAsync(document =>
        {
            var list = document.Profiles.Where(p => p.Id != id).ToList();
            removed = list.Count != document.Profiles.Count;
            return removed ? document with { Profiles = list } : null;
        }, cancellationToken);
        return removed;
    }

    public void Dispose() => _gate.Dispose();

    private static JsonObject RestoreDefaults(JsonObject root)
    {
        JsonDefaults.OverlayEach(root, "profiles", static () => new CompareProfile(), CompareJsonContext.Default.CompareProfile);
        if (root["profiles"] is JsonArray profiles)
        {
            // Arrays replace rather than merge, so each saved table needs its own defaults laid under it.
            foreach (var profile in profiles.OfType<JsonObject>())
            {
                JsonDefaults.OverlayEach(profile, "tables", static () => new CompareProfileTable(), CompareJsonContext.Default.CompareProfileTable);
            }
        }

        return root;
    }

    /// <summary>
    /// Puts back what a hand-edited or older file can leave out. A profile with no source or target connection cannot
    /// be loaded at all, so it is dropped rather than offered.
    /// </summary>
    private static CompareProfilesDocument Normalize(CompareProfilesDocument document) => document with
    {
        Profiles = Sorted((document.Profiles ?? [])
            .Where(p => p is { Source.ConnectionId: var source, Target.ConnectionId: var target } && source != Guid.Empty && target != Guid.Empty)
            .Select(p => p with
            {
                Name = p.Name ?? string.Empty,
                Options = p.Options ?? new CompareProfileOptions(),
                Tables = [.. (p.Tables ?? []).Where(t => t is not null && !string.IsNullOrEmpty(t.Source)).Select(t => t with
                {
                    Target = string.IsNullOrEmpty(t.Target) ? t.Source : t.Target,
                    Scope = (t.Scope ?? Core.Compare.CompareTableScope.Default).Normalized(),
                })],
            })),
    };

    private static List<CompareProfile> Sorted(IEnumerable<CompareProfile> profiles) =>
        [.. profiles.OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase)];

    private async Task MutateAsync(Func<CompareProfilesDocument, CompareProfilesDocument?> change, CancellationToken cancellationToken)
    {
        await EnsureLoadedAsync().WaitAsync(cancellationToken);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var next = change(_document);
            if (next is null)
            {
                return;
            }

            await AtomicFile.WriteJsonAsync(_path, next, Json, cancellationToken);
            Volatile.Write(ref _document, next);
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }
}
