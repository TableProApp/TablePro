using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The saved connections, their group tree and the favourites, in the core's connections.json. Every call reads
// or writes the file, so a list the app shows is rebuilt from a snapshot after each change.
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

    public Task MoveToGroupAsync(IReadOnlyList<Guid> ids, Guid? groupId)
    {
        ArgumentNullException.ThrowIfNull(ids);
        var names = ids.Select(id => id.ToString()).ToArray();
        return CoreCall.RunAsync(() => _library.MoveToGroup(names, groupId?.ToString()));
    }

    // A TablePro connections file. It carries no passwords.
    public async Task<ImportSummary> ImportAsync(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        var summary = await CoreCall.RunAsync(() => _library.ImportFile(path)).ConfigureAwait(false);
        return new ImportSummary(checked((int)summary.Added), checked((int)summary.Updated));
    }

    public void Dispose() => _library.Dispose();
}
