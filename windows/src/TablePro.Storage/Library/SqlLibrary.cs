using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;
using TablePro.Storage.Library.Team;

namespace TablePro.Storage.Library;

/// <summary>A Git command running in a repository, shown on its folders while it lasts.</summary>
public enum GitOperation
{
    Commit,
    Pull,
    Push,
}

/// <summary>
/// Everything the SQL files pane works with, behind one object the app keeps for its lifetime: the linked folders and
/// their watcher, each folder's Git state, the saved copies kept on every save, and the team library. Events fire on
/// background threads; UI subscribers marshal to their dispatcher.
/// </summary>
public sealed class SqlLibrary : IAsyncDisposable
{
    private readonly GitRepositoryWatcher _repositories = new();
    private readonly DebouncedSignal _gitRefresh;
    private readonly SemaphoreSlim _gitGate = new(1, 1);
    private readonly Dictionary<string, GitOperation> _operations = new(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyDictionary<Guid, LinkedFolderGitSnapshot> _gitSnapshots = new Dictionary<Guid, LinkedFolderGitSnapshot>();
    private bool _started;

    public SqlLibrary(LinkedSqlFolderStore folders, LocalSnapshotStore snapshots, GitClient? git, TeamLibrarySync? team, IRecycleBin recycleBin, TimeSpan? scanDelay = null)
    {
        Folders = folders;
        Snapshots = snapshots;
        Git = git;
        Team = team;
        RecycleBin = recycleBin;
        Watcher = new SqlFolderWatcher(scanDelay);
        _gitRefresh = new DebouncedSignal(TimeSpan.FromMilliseconds(400), () => _ = RefreshGitAsync());
        Folders.Changed += OnFoldersChanged;
        Watcher.Scanned += OnScanned;
        _repositories.Changed += (_, _) => _gitRefresh.Signal();
    }

    public LinkedSqlFolderStore Folders { get; }

    public SqlFolderWatcher Watcher { get; }

    public LocalSnapshotStore Snapshots { get; }

    /// <summary>Null when no git executable was found.</summary>
    public GitClient? Git { get; }

    /// <summary>Null when the app was built without the team service.</summary>
    public TeamLibrarySync? Team { get; }

    public IRecycleBin RecycleBin { get; }

    /// <summary>The folders were rescanned; <see cref="Watcher"/>'s <see cref="SqlFolderWatcher.Current"/> holds the files.</summary>
    public event EventHandler? FilesChanged;

    /// <summary>The Git state of a folder changed, or a Git operation started or ended.</summary>
    public event EventHandler? GitChanged;

    public IReadOnlyDictionary<Guid, LinkedFolderGitSnapshot> GitSnapshots => Volatile.Read(ref _gitSnapshots);

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_started)
        {
            return;
        }

        _started = true;
        await Folders.LoadAsync(cancellationToken);
        if (Team is not null)
        {
            await Team.StartAsync(cancellationToken);
        }
    }

    /// <summary>The scans of the folders a connection's window lists.</summary>
    public IReadOnlyList<SqlFolderScan> ScansFor(Guid? connectionId) =>
        [.. Watcher.Current.Where(s => s.Folder.IsVisibleTo(connectionId))];

    public LinkedFileGitState? GitStateOf(LinkedSqlFile file) =>
        GitSnapshots.TryGetValue(file.FolderId, out var snapshot) ? snapshot.StateOf(file.RelativePath) : null;

    public GitOperation? OperationFor(Guid folderId)
    {
        if (!GitSnapshots.TryGetValue(folderId, out var snapshot))
        {
            return null;
        }

        lock (_operations)
        {
            return _operations.TryGetValue(snapshot.Repository.TopLevel, out var operation) ? operation : null;
        }
    }

    /// <summary>Keeps the file's text on disk as a saved copy. The editor calls this after it saves a file.</summary>
    public Task<bool> RecordSaveAsync(string path, CancellationToken cancellationToken = default) =>
        FileVersionHistoryProvider.RecordFileAsync(Snapshots, path, cancellationToken);

    /// <summary>The versions of a file: saved copies and, in a repository, its commits.</summary>
    public FileVersionHistoryProvider HistoryOf(string path) => new(path, Snapshots, Git);

    public async Task<string> CreateFileAsync(string directory, string? name = null, CancellationToken cancellationToken = default)
    {
        var path = await SqlFileOperations.CreateAsync(directory, name, cancellationToken: cancellationToken);
        await Watcher.RescanAsync(cancellationToken);
        return path;
    }

    /// <summary>Renames a file and moves its saved copies with it.</summary>
    public async Task<string> RenameFileAsync(string path, string newName, CancellationToken cancellationToken = default)
    {
        var target = SqlFileOperations.Rename(path, newName);
        await Snapshots.MoveAsync(LocalSnapshotStore.FileSubject(path), LocalSnapshotStore.FileSubject(target), cancellationToken);
        await Watcher.RescanAsync(cancellationToken);
        return target;
    }

    /// <summary>Moves a file to the Recycle Bin. Its saved copies are kept, so restoring it from the bin brings its history back.</summary>
    public async Task DeleteFileAsync(string path, CancellationToken cancellationToken = default)
    {
        RecycleBin.MoveToRecycleBin(path);
        await Watcher.RescanAsync(cancellationToken);
    }

    /// <summary>The commit dialog's draft for a folder, with one file checked alone when <paramref name="file"/> is given.</summary>
    public async Task<(GitCommitDraft Draft, GitRepositoryInfo Repository)?> CommitDraftAsync(LinkedSqlFolder folder, LinkedSqlFile? file = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(folder);
        var git = Git ?? throw new GitUnavailableException();
        if (await git.RepositoryInfoAsync(folder.ExpandedPath, cancellationToken) is not { } repository)
        {
            return null;
        }

        var records = await git.StatusAsync(repository.TopLevel, cancellationToken: cancellationToken);
        return (new GitCommitDraft(records, repository.Prefix, file?.RelativePath), repository);
    }

    public Task CommitAsync(GitCommitDraft draft, GitRepositoryInfo repository, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(repository);
        return PerformAsync(GitOperation.Commit, repository, git => git.CommitAsync(draft.CommitPaths, draft.UntrackedPaths, draft.Message, repository.TopLevel, cancellationToken));
    }

    /// <summary>Pulls with fast-forward only and returns the files the pull changed, so open tabs of them can reload.</summary>
    public async Task<IReadOnlyList<string>> PullAsync(LinkedSqlFolder folder, CancellationToken cancellationToken = default)
    {
        var repository = RepositoryOf(folder);
        IReadOnlyList<string> changed = [];
        await PerformAsync(GitOperation.Pull, repository, async git =>
        {
            var before = await git.HeadCommitAsync(repository.TopLevel, cancellationToken);
            await git.PullAsync(repository.TopLevel, cancellationToken);
            var after = await git.HeadCommitAsync(repository.TopLevel, cancellationToken);
            if (before is not null && after is not null && before != after)
            {
                changed = [.. (await git.ChangedPathsAsync(before, after, repository.TopLevel, cancellationToken))
                    .Select(p => Path.GetFullPath(Path.Combine(repository.TopLevel, p)))];
            }
        });
        await Watcher.RescanAsync(cancellationToken);
        return changed;
    }

    public Task PushAsync(LinkedSqlFolder folder, CancellationToken cancellationToken = default)
    {
        var repository = RepositoryOf(folder);
        return PerformAsync(GitOperation.Push, repository, git => git.PushAsync(repository.TopLevel, cancellationToken));
    }

    /// <summary>Reads every folder's Git state again now.</summary>
    public async Task RefreshGitAsync(CancellationToken cancellationToken = default)
    {
        await _gitGate.WaitAsync(cancellationToken);
        try
        {
            var loaded = await LinkedFolderGitStatus.LoadAsync(Folders.Folders, Git, GitSnapshots, cancellationToken);
            Volatile.Write(ref _gitSnapshots, loaded);
            _repositories.Watch(loaded.Values.Select(s => s.Repository.GitDirectory).Distinct(StringComparer.OrdinalIgnoreCase));
        }
        finally
        {
            _gitGate.Release();
        }

        GitChanged?.Invoke(this, EventArgs.Empty);
    }

    public ValueTask DisposeAsync()
    {
        Folders.Changed -= OnFoldersChanged;
        Watcher.Scanned -= OnScanned;
        Watcher.Dispose();
        _repositories.Dispose();
        _gitRefresh.Dispose();
        return ValueTask.CompletedTask;
    }

    private GitRepositoryInfo RepositoryOf(LinkedSqlFolder folder) =>
        GitSnapshots.TryGetValue(folder.Id, out var snapshot)
            ? snapshot.Repository
            : throw new InvalidOperationException("This folder is not in a Git repository.");

    private async Task PerformAsync(GitOperation operation, GitRepositoryInfo repository, Func<GitClient, Task> body)
    {
        var git = Git ?? throw new GitUnavailableException();
        lock (_operations)
        {
            if (!_operations.TryAdd(repository.TopLevel, operation))
            {
                throw new InvalidOperationException("Another Git command is still running in this repository.");
            }
        }

        GitChanged?.Invoke(this, EventArgs.Empty);
        try
        {
            await body(git);
        }
        finally
        {
            lock (_operations)
            {
                _operations.Remove(repository.TopLevel);
            }

            await RefreshGitAsync();
        }
    }

    private void OnFoldersChanged(object? sender, EventArgs e)
    {
        _ = Watcher.WatchAsync(Folders.Folders);
        _gitRefresh.Signal();
    }

    private void OnScanned(object? sender, EventArgs e)
    {
        FilesChanged?.Invoke(this, EventArgs.Empty);
        _gitRefresh.Signal();
    }
}
