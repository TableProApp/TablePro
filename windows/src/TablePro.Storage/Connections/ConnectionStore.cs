using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using TablePro.Core.Connections;

namespace TablePro.Storage.Connections;

/// <summary>
/// The saved connections and their groups, kept in <c>connections.json</c>. Reads come from an in-memory snapshot;
/// every change is written to disk before the snapshot moves, so the list on screen never shows something the file
/// lost. <see cref="Changed"/> fires on a thread-pool thread after each change lands.
/// </summary>
public sealed class ConnectionStore : IDisposable
{
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ConnectionsDocument _document = new();

    public ConnectionStore(AppPaths paths)
        : this(paths.ConnectionsFile)
    {
    }

    public ConnectionStore(string filePath)
    {
        _path = Path.GetFullPath(filePath);
    }

    public event EventHandler? Changed;

    /// <summary>In the user's manual order.</summary>
    public IReadOnlyList<ConnectionProfile> Connections => Volatile.Read(ref _document).Connections;

    public IReadOnlyList<ConnectionGroup> Groups => Volatile.Read(ref _document).Groups;

    public ConnectionProfile? Find(Guid id) => Connections.FirstOrDefault(c => c.Id == id);

    public ConnectionGroup? FindGroup(Guid id) => Groups.FirstOrDefault(g => g.Id == id);

    /// <summary>The group a profile sits in. Accepts a group name as well as its key, for profiles written by hand.</summary>
    public ConnectionGroup? GroupOf(ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (string.IsNullOrEmpty(profile.Group))
        {
            return null;
        }

        var groups = Groups;
        return groups.FirstOrDefault(g => string.Equals(g.Key, profile.Group, StringComparison.OrdinalIgnoreCase))
            ?? groups.FirstOrDefault(g => string.Equals(g.Name, profile.Group, StringComparison.OrdinalIgnoreCase));
    }

    public IReadOnlyList<ConnectionProfile> GetOrdered(ConnectionSortOrder order)
    {
        var connections = Connections;
        return order switch
        {
            ConnectionSortOrder.Name => [.. connections.OrderBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase)],
            ConnectionSortOrder.LastConnected => [.. connections
                .OrderByDescending(c => c.LastConnectedAt ?? DateTimeOffset.MinValue)
                .ThenBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase)],
            _ => connections,
        };
    }

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await AtomicFile.ReadJsonAsync(_path, StorageJson.Connections, RestoreDefaults, cancellationToken) ?? new ConnectionsDocument();
            Volatile.Write(ref _document, document with
            {
                Connections = document.Connections ?? [],
                Groups = document.Groups ?? [],
            });
        }
        finally
        {
            _gate.Release();
        }

        OnChanged();
    }

    /// <summary>Adds the profile, or replaces the one with the same id where it stands in the list.</summary>
    public Task UpsertAsync(ConnectionProfile profile, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        return MutateAsync(document =>
        {
            var list = document.Connections.ToList();
            var index = list.FindIndex(c => c.Id == profile.Id);
            if (index >= 0)
            {
                list[index] = profile;
            }
            else
            {
                list.Add(profile);
            }

            return document with { Connections = list };
        }, cancellationToken);
    }

    public async Task<bool> DeleteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = false;
        await MutateAsync(document =>
        {
            var list = document.Connections.Where(c => c.Id != id).ToList();
            removed = list.Count != document.Connections.Count;
            return removed ? document with { Connections = list } : null;
        }, cancellationToken);
        return removed;
    }

    /// <summary>Copies a profile under a new id and a "copy" name, right after the original. The password is not copied.</summary>
    public async Task<ConnectionProfile?> DuplicateAsync(Guid id, CancellationToken cancellationToken = default)
    {
        ConnectionProfile? copy = null;
        await MutateAsync(document =>
        {
            var list = document.Connections.ToList();
            var index = list.FindIndex(c => c.Id == id);
            if (index < 0)
            {
                return null;
            }

            var source = list[index];
            copy = source with
            {
                Id = Guid.NewGuid(),
                Name = UniqueCopyName(source.Name, list),
                LastConnectedAt = null,
            };
            list.Insert(index + 1, copy);
            return document with { Connections = list };
        }, cancellationToken);
        return copy;
    }

    public Task MarkConnectedAsync(Guid id, DateTimeOffset? at = null, CancellationToken cancellationToken = default)
    {
        var stamp = at ?? DateTimeOffset.UtcNow;
        return MutateAsync(document =>
        {
            var list = document.Connections.ToList();
            var index = list.FindIndex(c => c.Id == id);
            if (index < 0)
            {
                return null;
            }

            list[index] = list[index] with { LastConnectedAt = stamp };
            return document with { Connections = list };
        }, cancellationToken);
    }

    /// <summary>Moves a connection to <paramref name="newIndex"/> in the manual order, clamped to the list.</summary>
    public Task MoveAsync(Guid id, int newIndex, CancellationToken cancellationToken = default) =>
        MutateAsync(document =>
        {
            var list = document.Connections.ToList();
            var index = list.FindIndex(c => c.Id == id);
            if (index < 0)
            {
                return null;
            }

            var item = list[index];
            list.RemoveAt(index);
            list.Insert(Math.Clamp(newIndex, 0, list.Count), item);
            return document with { Connections = list };
        }, cancellationToken);

    public Task UpsertGroupAsync(ConnectionGroup group, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(group);
        if (group.ParentId == group.Id)
        {
            throw new ArgumentException("A group cannot contain itself.", nameof(group));
        }

        return MutateAsync(document =>
        {
            var list = document.Groups.ToList();
            if (group.ParentId is { } parent && IsDescendant(list, parent, group.Id))
            {
                throw new InvalidOperationException("A group cannot move inside one of its own subgroups.");
            }

            var index = list.FindIndex(g => g.Id == group.Id);
            if (index >= 0)
            {
                list[index] = group;
            }
            else
            {
                list.Add(group);
            }

            return document with { Groups = list };
        }, cancellationToken);
    }

    /// <summary>Removes a group. Its subgroups and connections move up to its parent, so nothing disappears with it.</summary>
    public async Task<bool> DeleteGroupAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = false;
        await MutateAsync(document =>
        {
            var target = document.Groups.FirstOrDefault(g => g.Id == id);
            if (target is null)
            {
                return null;
            }

            removed = true;
            var parentKey = target.ParentId is { } parentId ? parentId.ToString("D") : null;
            var groups = document.Groups
                .Where(g => g.Id != id)
                .Select(g => g.ParentId == id ? g with { ParentId = target.ParentId } : g)
                .ToList();
            var connections = document.Connections
                .Select(c => IsInGroup(c, target) ? c with { Group = parentKey } : c)
                .ToList();
            return document with { Groups = groups, Connections = connections };
        }, cancellationToken);
        return removed;
    }

    /// <summary>Writes the chosen connections, or all of them, to a portable file with no passwords in it.</summary>
    public async Task ExportAsync(string filePath, IEnumerable<Guid>? connectionIds = null, CancellationToken cancellationToken = default)
    {
        var document = Volatile.Read(ref _document);
        IEnumerable<ConnectionProfile> profiles = document.Connections;
        if (connectionIds is not null)
        {
            var wanted = connectionIds.ToHashSet();
            profiles = profiles.Where(p => wanted.Contains(p.Id));
        }

        var file = ConnectionPortability.Export(profiles, document.Groups, AppVersion, DateTimeOffset.UtcNow);
        await AtomicFile.WriteJsonAsync(filePath, file, StorageJson.Portable, cancellationToken);
    }

    /// <summary>
    /// Reads a portable file from this app or the macOS app and adds its connections under new ids, creating the
    /// groups they name. Passwords are never in the file, so imported connections ask for one on first connect.
    /// </summary>
    public async Task<ConnectionImportResult> ImportAsync(string filePath, CancellationToken cancellationToken = default)
    {
        PortableConnectionFile? file;
        var stream = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.Read, 16 * 1024, FileOptions.Asynchronous);
        await using (stream)
        {
            try
            {
                file = await JsonSerializer.DeserializeAsync(stream, StorageJson.Portable, cancellationToken);
            }
            catch (JsonException ex)
            {
                throw new InvalidDataException("The file is not a TablePro connection export.", ex);
            }
        }

        if (file is null)
        {
            throw new InvalidDataException("The file is not a TablePro connection export.");
        }

        file.Connections ??= [];
        ConnectionImportResult? result = null;
        await MutateAsync(document =>
        {
            result = ConnectionPortability.Import(file, document.Groups);
            if (result.Imported.Count == 0 && result.CreatedGroups.Count == 0)
            {
                return null;
            }

            return document with
            {
                Connections = [.. document.Connections, .. result.Imported],
                Groups = [.. document.Groups, .. result.CreatedGroups],
            };
        }, cancellationToken);
        return result!;
    }

    public void Dispose() => _gate.Dispose();

    private static string AppVersion =>
        typeof(ConnectionStore).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? "0.0.0";

    // change returns the new document, or null when nothing changed and the file should stay as it is.
    private async Task MutateAsync(Func<ConnectionsDocument, ConnectionsDocument?> change, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var next = change(_document);
            if (next is null)
            {
                return;
            }

            await AtomicFile.WriteJsonAsync(_path, next, StorageJson.Connections, cancellationToken);
            Volatile.Write(ref _document, next);
        }
        finally
        {
            _gate.Release();
        }

        OnChanged();
    }

    private void OnChanged() => Changed?.Invoke(this, EventArgs.Empty);

    private static JsonObject RestoreDefaults(JsonObject root)
    {
        JsonDefaults.OverlayEach(root, "connections", static () => new ConnectionProfile { Name = string.Empty, Engine = default }, StorageJson.Profile);
        JsonDefaults.OverlayEach(root, "groups", static () => new ConnectionGroup { Name = string.Empty }, StorageJson.Group);
        if (root["connections"] is JsonArray connections)
        {
            foreach (var connection in connections.OfType<JsonObject>())
            {
                if (connection["ssh"] is JsonObject ssh)
                {
                    connection["ssh"] = JsonDefaults.Overlay(ssh.DeepClone().AsObject(), new SshTunnelSettings(), StorageJson.Ssh);
                }
            }
        }

        return root;
    }

    private static bool IsInGroup(ConnectionProfile profile, ConnectionGroup group) =>
        string.Equals(profile.Group, group.Key, StringComparison.OrdinalIgnoreCase)
        || string.Equals(profile.Group, group.Name, StringComparison.OrdinalIgnoreCase);

    private static bool IsDescendant(List<ConnectionGroup> groups, Guid candidate, Guid ancestor)
    {
        var seen = new HashSet<Guid>();
        Guid? current = candidate;
        while (current is { } id && seen.Add(id))
        {
            if (id == ancestor)
            {
                return true;
            }

            current = groups.FirstOrDefault(g => g.Id == id)?.ParentId;
        }

        return false;
    }

    private static string UniqueCopyName(string name, List<ConnectionProfile> existing)
    {
        var names = existing.Select(c => c.Name).ToHashSet(StringComparer.CurrentCultureIgnoreCase);
        var candidate = name + " copy";
        for (var n = 2; names.Contains(candidate); n++)
        {
            candidate = $"{name} copy {n}";
        }

        return candidate;
    }
}
