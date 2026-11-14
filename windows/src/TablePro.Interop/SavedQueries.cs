using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// FolderId is null at the top level; Order is dense from 0 within the folder.
public sealed record SavedQuery(
    long Id,
    string Name,
    string Sql,
    string? Keyword,
    long? FolderId,
    long Order,
    DateTimeOffset UpdatedAt);

public sealed record SavedQueryFolder(long Id, string Name, long? ParentId, long Order);

// Read in one transaction, each list in its place's order.
public sealed record SavedQueryList(IReadOnlyList<SavedQuery> Queries, IReadOnlyList<SavedQueryFolder> Folders);

// A connection's saved queries and their folders, kept in the query history's database (core ADR 0017).
public sealed class SavedQueries : IDisposable
{
    private readonly Native.SavedQueryStore _store;

    internal SavedQueries(Native.SavedQueryStore store)
    {
        _store = store;
    }

    public async Task<SavedQueryList> GetAsync(Guid connectionId, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // A read, so one the caller stopped waiting for is left to finish.
        var list = await CoreCall.RunAsync(() => _store.Snapshot(connectionId.ToString()))
            .WaitAsync(cancellationToken)
            .ConfigureAwait(false);
        return new SavedQueryList(
            [.. list.Queries.Select(query => new SavedQuery(
                query.Id,
                query.Name,
                query.Sql,
                query.Keyword,
                query.FolderId,
                query.Order,
                DateTimeOffset.FromUnixTimeMilliseconds(query.UpdatedAtMs)))],
            [.. list.Folders.Select(folder => new SavedQueryFolder(folder.Id, folder.Name, folder.ParentId, folder.Order))]);
    }

    // Null when the connection has a query of that name and replace is false; nothing is written then.
    public Task<long?> SaveAsync(Guid connectionId, string connectionName, string name, string sql, bool replace)
    {
        ArgumentNullException.ThrowIfNull(connectionName);
        ArgumentNullException.ThrowIfNull(name);
        ArgumentNullException.ThrowIfNull(sql);
        var draft = new Native.SavedQueryDraft(connectionId.ToString(), connectionName, name, sql);
        return CoreCall.RunAsync(() => _store.Save(draft, replace));
    }

    public Task RenameAsync(long id, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return CoreCall.RunAsync(() => _store.Rename(id, name));
    }

    // Null or blank clears it.
    public Task SetKeywordAsync(long id, string? keyword) => CoreCall.RunAsync(() => _store.SetKeyword(id, keyword));

    // Into the folder, null for the top level, before the query named there or at the end.
    public Task MoveAsync(long id, long? folderId, long? before = null) =>
        CoreCall.RunAsync(() => _store.MoveQuery(id, folderId, before));

    public Task DeleteAsync(long id) => CoreCall.RunAsync(() => _store.Delete(id));

    public Task<long> CreateFolderAsync(Guid connectionId, string name, long? parentId)
    {
        ArgumentNullException.ThrowIfNull(name);
        return CoreCall.RunAsync(() => _store.CreateFolder(connectionId.ToString(), name, parentId));
    }

    public Task RenameFolderAsync(long id, string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return CoreCall.RunAsync(() => _store.RenameFolder(id, name));
    }

    public Task MoveFolderAsync(long id, long? parentId) => CoreCall.RunAsync(() => _store.MoveFolder(id, parentId));

    // The folders inside go too, and every query they held moves to the top level.
    public Task DeleteFolderAsync(long id) => CoreCall.RunAsync(() => _store.DeleteFolder(id));

    // Its queries, folders and favourite tables and databases, for a connection the user deleted.
    public async Task<long> DeleteForConnectionAsync(Guid connectionId)
    {
        var removed = await CoreCall.RunAsync(() => _store.DeleteForConnection(connectionId.ToString())).ConfigureAwait(false);
        return Mapping.Count(removed);
    }

    public void Dispose() => _store.Dispose();
}
