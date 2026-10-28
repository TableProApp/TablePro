using System.Text.Json.Nodes;

namespace TablePro.Storage.Library.Folders;

/// <summary>What happened when a folder was linked.</summary>
public enum LinkFolderOutcome
{
    Added,

    /// <summary>The folder was linked but turned off; linking it again turns it back on.</summary>
    ReEnabled,
    AlreadyLinked,
}

/// <summary>
/// The linked SQL folders in <c>linked_sql_folders.json</c>. As in the other stores, a change reaches the disk before
/// the in-memory list moves, and <see cref="Changed"/> fires on the saving thread.
/// </summary>
public sealed class LinkedSqlFolderStore : IDisposable
{
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private LinkedSqlFoldersDocument _document = new();

    public LinkedSqlFolderStore(AppPaths paths)
        : this(System.IO.Path.Combine(paths.Root, "linked_sql_folders.json"))
    {
    }

    public LinkedSqlFolderStore(string filePath)
    {
        _path = System.IO.Path.GetFullPath(filePath);
    }

    public event EventHandler? Changed;

    public IReadOnlyList<LinkedSqlFolder> Folders => Volatile.Read(ref _document).Folders;

    /// <summary>The enabled folders a connection's window lists: the global ones and its own.</summary>
    public IReadOnlyList<LinkedSqlFolder> VisibleTo(Guid? connectionId) =>
        [.. Folders.Where(f => f.IsEnabled && f.IsVisibleTo(connectionId))];

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await AtomicFile.ReadJsonAsync(_path, LibraryJson.Folders, RestoreDefaults, cancellationToken) ?? new LinkedSqlFoldersDocument();
            Volatile.Write(ref _document, document with { Folders = document.Folders ?? [] });
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Links a folder. Choosing one that is linked but turned off turns it on again, since refusing it would point the
    /// user at a list the folder is invisible in.
    /// </summary>
    public async Task<LinkFolderOutcome> AddAsync(string folderPath, Guid? connectionId = null, CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(folderPath);
        var full = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(folderPath));
        var outcome = LinkFolderOutcome.Added;
        await MutateAsync(document =>
        {
            var list = document.Folders.ToList();
            var index = list.FindIndex(f => SamePath(f.ExpandedPath, full));
            if (index < 0)
            {
                list.Add(new LinkedSqlFolder { Path = full, ConnectionId = connectionId });
                return document with { Folders = list };
            }

            if (list[index].IsEnabled)
            {
                outcome = LinkFolderOutcome.AlreadyLinked;
                return null;
            }

            outcome = LinkFolderOutcome.ReEnabled;
            list[index] = list[index] with { IsEnabled = true };
            return document with { Folders = list };
        }, cancellationToken);
        return outcome;
    }

    public Task UpdateAsync(LinkedSqlFolder folder, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(folder);
        return MutateAsync(document =>
        {
            var list = document.Folders.ToList();
            var index = list.FindIndex(f => f.Id == folder.Id);
            if (index < 0)
            {
                return null;
            }

            list[index] = folder;
            return document with { Folders = list };
        }, cancellationToken);
    }

    public Task SetEnabledAsync(Guid folderId, bool enabled, CancellationToken cancellationToken = default) =>
        Folders.FirstOrDefault(f => f.Id == folderId) is { } folder
            ? UpdateAsync(folder with { IsEnabled = enabled }, cancellationToken)
            : Task.CompletedTask;

    /// <summary>Forgets a folder. Its files are left alone.</summary>
    public Task RemoveAsync(Guid folderId, CancellationToken cancellationToken = default) =>
        MutateAsync(document => document.Folders.Any(f => f.Id == folderId)
            ? document with { Folders = [.. document.Folders.Where(f => f.Id != folderId)] }
            : null, cancellationToken);

    public void Dispose() => _gate.Dispose();

    internal static bool SamePath(string left, string right) =>
        string.Equals(
            System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(left)),
            System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(right)),
            StringComparison.OrdinalIgnoreCase);

    private static JsonObject RestoreDefaults(JsonObject root)
    {
        JsonDefaults.OverlayEach(root, "folders", () => new LinkedSqlFolder { Path = string.Empty }, LibraryJsonContext.Default.LinkedSqlFolder);
        return root;
    }

    private async Task MutateAsync(Func<LinkedSqlFoldersDocument, LinkedSqlFoldersDocument?> change, CancellationToken cancellationToken)
    {
        bool changed;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var next = change(_document);
            changed = next is not null;
            if (next is not null)
            {
                await AtomicFile.WriteJsonAsync(_path, next, LibraryJson.Folders, cancellationToken);
                Volatile.Write(ref _document, next);
            }
        }
        finally
        {
            _gate.Release();
        }

        if (changed)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }
}
