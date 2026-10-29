using System.Text.Json.Nodes;
using TablePro.Storage.Localization;

namespace TablePro.Storage.Favorites;

/// <summary>Why a keyword cannot be saved, or <see cref="None"/> when it can.</summary>
public enum KeywordProblem
{
    None,
    ContainsWhitespace,
    TooLong,
    AlreadyUsed,
}

/// <summary>
/// Saved SQL favorites and their folders in <c>favorites.json</c>. Like the other stores, a change reaches the disk
/// before the in-memory snapshot moves, and <see cref="Changed"/> fires on the saving thread.
/// </summary>
public sealed class FavoritesStore : IDisposable
{
    public const int MaxKeywordLength = 32;

    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private FavoritesDocument _document = new();

    public FavoritesStore(AppPaths paths)
        : this(paths.FavoritesFile)
    {
    }

    public FavoritesStore(string filePath)
    {
        _path = Path.GetFullPath(filePath);
    }

    public event EventHandler? Changed;

    public IReadOnlyList<SqlFavorite> Favorites => Volatile.Read(ref _document).Favorites;

    public IReadOnlyList<SqlFavoriteFolder> Folders => Volatile.Read(ref _document).Folders;

    /// <summary>What a connection's favorites panel lists: the global favorites and folders plus its own.</summary>
    public (IReadOnlyList<SqlFavoriteFolder> Folders, IReadOnlyList<SqlFavorite> Favorites) GetVisible(Guid? connectionId)
    {
        var document = Volatile.Read(ref _document);
        return (
            [.. document.Folders.Where(f => f.ConnectionId is null || f.ConnectionId == connectionId).OrderBy(f => f.SortOrder).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)],
            [.. document.Favorites.Where(f => f.ConnectionId is null || f.ConnectionId == connectionId).OrderBy(f => f.SortOrder).ThenBy(f => f.Name, StringComparer.CurrentCultureIgnoreCase)]);
    }

    /// <summary>
    /// The favorite a typed keyword expands to. A favorite scoped to the connection wins over a global one with the
    /// same keyword, so a team can override a shared snippet for one database.
    /// </summary>
    public SqlFavorite? FindByKeyword(string keyword, Guid? connectionId)
    {
        if (string.IsNullOrWhiteSpace(keyword))
        {
            return null;
        }

        SqlFavorite? global = null;
        foreach (var favorite in Favorites)
        {
            if (!string.Equals(favorite.Keyword, keyword, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (favorite.ConnectionId is { } scope && scope == connectionId)
            {
                return favorite;
            }

            if (favorite.ConnectionId is null)
            {
                global ??= favorite;
            }
        }

        return global;
    }

    /// <summary>
    /// Checks a keyword before saving. Two favorites may share a keyword only when they are scoped to different
    /// connections, or when one is global and the other scoped, since lookup prefers the scoped one.
    /// </summary>
    public KeywordProblem ValidateKeyword(string? keyword, Guid? connectionId, Guid? excludingFavoriteId = null) =>
        ValidateKeyword(Favorites, keyword, connectionId, excludingFavoriteId);

    private static KeywordProblem ValidateKeyword(IReadOnlyList<SqlFavorite> favorites, string? keyword, Guid? connectionId, Guid? excludingFavoriteId)
    {
        if (string.IsNullOrEmpty(keyword))
        {
            return KeywordProblem.None;
        }

        if (keyword.Any(char.IsWhiteSpace))
        {
            return KeywordProblem.ContainsWhitespace;
        }

        if (keyword.Length > MaxKeywordLength)
        {
            return KeywordProblem.TooLong;
        }

        var clash = favorites.Any(f =>
            f.Id != excludingFavoriteId
            && f.ConnectionId == connectionId
            && string.Equals(f.Keyword, keyword, StringComparison.OrdinalIgnoreCase));
        return clash ? KeywordProblem.AlreadyUsed : KeywordProblem.None;
    }

    private static string Describe(KeywordProblem problem) => problem switch
    {
        KeywordProblem.ContainsWhitespace => StorageStrings.Get("Stores/KeywordContainsSpaces"),
        KeywordProblem.TooLong => StorageStrings.Plural("Stores/KeywordTooLong", MaxKeywordLength),
        _ => StorageStrings.Get("Stores/KeywordUsed"),
    };

    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var document = await AtomicFile.ReadJsonAsync(_path, StorageJson.Favorites, RestoreDefaults, cancellationToken) ?? new FavoritesDocument();
            Volatile.Write(ref _document, document with { Folders = document.Folders ?? [], Favorites = document.Favorites ?? [] });
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Adds or replaces a favorite, stamping <see cref="SqlFavorite.UpdatedAt"/>.</summary>
    public async Task<SqlFavorite> UpsertFavoriteAsync(SqlFavorite favorite, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(favorite);
        var keyword = string.IsNullOrWhiteSpace(favorite.Keyword) ? null : favorite.Keyword.Trim();
        var saved = favorite with { Keyword = keyword, UpdatedAt = DateTimeOffset.UtcNow };
        await MutateAsync(document =>
        {
            // Checked under the lock, so two saves racing for one keyword cannot both pass.
            var problem = ValidateKeyword(document.Favorites, keyword, favorite.ConnectionId, favorite.Id);
            if (problem != KeywordProblem.None)
            {
                throw new ArgumentException(Describe(problem), nameof(favorite));
            }

            var list = document.Favorites.ToList();
            var index = list.FindIndex(f => f.Id == saved.Id);
            if (index >= 0)
            {
                saved = saved with { CreatedAt = list[index].CreatedAt };
                list[index] = saved;
            }
            else
            {
                list.Add(saved);
            }

            return document with { Favorites = list };
        }, cancellationToken);
        return saved;
    }

    public async Task<bool> DeleteFavoriteAsync(Guid id, CancellationToken cancellationToken = default)
    {
        var removed = false;
        await MutateAsync(document =>
        {
            var list = document.Favorites.Where(f => f.Id != id).ToList();
            removed = list.Count != document.Favorites.Count;
            return removed ? document with { Favorites = list } : null;
        }, cancellationToken);
        return removed;
    }

    public async Task<SqlFavoriteFolder> UpsertFolderAsync(SqlFavoriteFolder folder, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(folder);
        if (folder.ParentId == folder.Id)
        {
            throw new ArgumentException(StorageStrings.Get("Stores/FolderContainsItself"), nameof(folder));
        }

        var saved = folder with { UpdatedAt = DateTimeOffset.UtcNow };
        await MutateAsync(document =>
        {
            var list = document.Folders.ToList();
            if (saved.ParentId is { } parent && IsWithin(list, parent, saved.Id))
            {
                throw new InvalidOperationException(StorageStrings.Get("Stores/FolderIntoSubfolder"));
            }

            var index = list.FindIndex(f => f.Id == saved.Id);
            if (index >= 0)
            {
                saved = saved with { CreatedAt = list[index].CreatedAt };
                list[index] = saved;
            }
            else
            {
                list.Add(saved);
            }

            return document with { Folders = list };
        }, cancellationToken);
        return saved;
    }

    /// <summary>
    /// Removes a folder. With <paramref name="deleteContents"/> its favorites and subfolders go too; otherwise they
    /// move up to the folder's parent.
    /// </summary>
    public async Task<bool> DeleteFolderAsync(Guid id, bool deleteContents = false, CancellationToken cancellationToken = default)
    {
        var removed = false;
        await MutateAsync(document =>
        {
            var target = document.Folders.FirstOrDefault(f => f.Id == id);
            if (target is null)
            {
                return null;
            }

            removed = true;
            if (deleteContents)
            {
                var doomed = new HashSet<Guid> { id };
                foreach (var folder in document.Folders)
                {
                    if (folder.ParentId is { } parent && IsWithin(document.Folders, parent, id))
                    {
                        doomed.Add(folder.Id);
                    }
                }

                return document with
                {
                    Folders = [.. document.Folders.Where(f => !doomed.Contains(f.Id))],
                    Favorites = [.. document.Favorites.Where(f => f.FolderId is not { } folderId || !doomed.Contains(folderId))],
                };
            }

            return document with
            {
                Folders = [.. document.Folders.Where(f => f.Id != id).Select(f => f.ParentId == id ? f with { ParentId = target.ParentId } : f)],
                Favorites = [.. document.Favorites.Select(f => f.FolderId == id ? f with { FolderId = target.ParentId } : f)],
            };
        }, cancellationToken);
        return removed;
    }

    public void Dispose() => _gate.Dispose();

    private static JsonObject RestoreDefaults(JsonObject root)
    {
        JsonDefaults.OverlayEach(root, "folders", static () => new SqlFavoriteFolder { Name = string.Empty }, StorageJson.Folder);
        JsonDefaults.OverlayEach(root, "favorites", static () => new SqlFavorite { Name = string.Empty, Query = string.Empty }, StorageJson.Favorite);
        return root;
    }

    private async Task MutateAsync(Func<FavoritesDocument, FavoritesDocument?> change, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var next = change(_document);
            if (next is null)
            {
                return;
            }

            await AtomicFile.WriteJsonAsync(_path, next, StorageJson.Favorites, cancellationToken);
            Volatile.Write(ref _document, next);
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>True when <paramref name="folderId"/> is <paramref name="ancestorId"/> or sits somewhere beneath it.</summary>
    private static bool IsWithin(IReadOnlyList<SqlFavoriteFolder> folders, Guid folderId, Guid ancestorId)
    {
        var seen = new HashSet<Guid>();
        Guid? current = folderId;
        while (current is { } id && seen.Add(id))
        {
            if (id == ancestorId)
            {
                return true;
            }

            current = folders.FirstOrDefault(f => f.Id == id)?.ParentId;
        }

        return false;
    }
}
