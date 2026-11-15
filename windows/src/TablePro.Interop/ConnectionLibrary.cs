using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Every call reads or writes connections.json, so a list the app shows is rebuilt from a snapshot after each change.
public sealed class ConnectionLibrary : IDisposable
{
    private readonly Native.ConnectionLibrary _library;

    internal ConnectionLibrary(Native.ConnectionLibrary library)
    {
        _library = library;
    }

    public async Task<LibrarySnapshot> GetSnapshotAsync()
    {
        var snapshot = await CoreCall.RunAsync(() => _library.Snapshot()).ConfigureAwait(false);
        return Mapping.Snapshot(snapshot);
    }

    public async Task<SavedConnection> SaveAsync(SavedConnection connection, ConnectionSecrets secrets)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(secrets);
        var record = Mapping.Record(connection);
        var typed = Mapping.Secrets(secrets);
        var saved = await CoreCall.RunAsync(() => _library.Save(record, typed)).ConfigureAwait(false);
        return Mapping.Connection(saved);
    }

    public Task DeleteAsync(Guid id) => CoreCall.RunAsync(() => _library.Delete(id.ToString()));

    public Task SetFavoriteAsync(Guid id, bool favorite) =>
        CoreCall.RunAsync(() => _library.SetFavorite(id.ToString(), favorite));

    // Favourites already listed move, which is how a drag reorders them; to the end when before is null.
    public Task AddFavoritesAsync(IReadOnlyList<Guid> ids, Guid? before = null)
    {
        var names = Names(ids);
        return CoreCall.RunAsync(() => _library.AddFavorites(names, before?.ToString()));
    }

    public Task RemoveFavoritesAsync(IReadOnlyList<Guid> ids)
    {
        var names = Names(ids);
        return CoreCall.RunAsync(() => _library.RemoveFavorites(names));
    }

    public Task RenameAsync(Guid id, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return CoreCall.RunAsync(() => _library.RenameConnection(id.ToString(), name));
    }

    public async Task<ConnectionTag> CreateTagAsync(string name, string color)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(color);
        var tag = await CoreCall.RunAsync(() => _library.CreateTag(name, color)).ConfigureAwait(false);
        return new ConnectionTag(Guid.Parse(tag.Id), tag.Name, tag.Color);
    }

    // A rename or a new colour reaches every connection that carries the tag.
    public Task UpdateTagAsync(Guid id, string name, string color)
    {
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(color);
        return CoreCall.RunAsync(() => _library.UpdateTag(id.ToString(), name, color));
    }

    public Task DeleteTagAsync(Guid id) => CoreCall.RunAsync(() => _library.DeleteTag(id.ToString()));

    public Task TagAsync(IReadOnlyList<Guid> ids, Guid tag, bool tagged)
    {
        var names = Names(ids);
        return CoreCall.RunAsync(() => _library.TagConnections(names, tag.ToString(), tagged));
    }

    public async Task<ConnectionGroup> CreateGroupAsync(string name, Guid? parentId)
    {
        ArgumentNullException.ThrowIfNull(name);
        var group = await CoreCall.RunAsync(() => _library.CreateGroup(name, parentId?.ToString()))
            .ConfigureAwait(false);
        return Mapping.Group(group);
    }

    public Task RenameGroupAsync(Guid id, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return CoreCall.RunAsync(() => _library.RenameGroup(id.ToString(), name));
    }

    // The group's subgroups go with it, and its connections move to the top level.
    public Task DeleteGroupAsync(Guid id) => CoreCall.RunAsync(() => _library.DeleteGroup(id.ToString()));

    // Into the group, or the top level when it is null, before the connection named, or at the end.
    public Task MoveToGroupAsync(IReadOnlyList<Guid> ids, Guid? groupId, Guid? before = null)
    {
        var names = Names(ids);
        return CoreCall.RunAsync(() => _library.MoveToGroup(names, groupId?.ToString(), before?.ToString()));
    }

    // Under the parent, or the top level when it is null, before the group named, or at the end.
    public Task MoveGroupsAsync(IReadOnlyList<Guid> ids, Guid? parentId, Guid? before = null)
    {
        var names = Names(ids);
        return CoreCall.RunAsync(() => _library.MoveGroups(names, parentId?.ToString(), before?.ToString()));
    }

    // A TablePro connections file. It carries no passwords.
    public async Task<ImportSummary> ImportAsync(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        var summary = await CoreCall.RunAsync(() => _library.ImportFile(path)).ConfigureAwait(false);
        return new ImportSummary(checked((int)summary.Added), checked((int)summary.Updated));
    }

    // A copy under a new id right after the original, with every secret the original keeps; it is no favourite.
    public async Task<SavedConnection> DuplicateAsync(Guid id, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        var copy = await CoreCall.RunAsync(() => _library.Duplicate(id.ToString(), name)).ConfigureAwait(false);
        return Mapping.Connection(copy);
    }

    // Every connection, group and tag, and no password, in a file that appears at path only once whole.
    public async Task<int> ExportAsync(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        var count = await CoreCall.RunAsync(() => _library.ExportFile(path)).ConfigureAwait(false);
        return checked((int)count);
    }

    public void Dispose() => _library.Dispose();

    private static string[] Names(IReadOnlyList<Guid> ids)
    {
        ArgumentNullException.ThrowIfNull(ids);
        return [.. ids.Select(id => id.ToString())];
    }
}
