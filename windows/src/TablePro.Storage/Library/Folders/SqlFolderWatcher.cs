namespace TablePro.Storage.Library.Folders;

/// <summary>
/// Watches the linked folders with <see cref="FileSystemWatcher"/> and rescans them a moment after their files
/// change, as the macOS app does with FSEvents. <see cref="Scanned"/> fires on a thread-pool thread with the new
/// <see cref="Current"/> list.
/// </summary>
public sealed class SqlFolderWatcher : IDisposable
{
    public static readonly TimeSpan DefaultDelay = TimeSpan.FromSeconds(1);

    private readonly object _lock = new();
    private readonly List<FileSystemWatcher> _watchers = [];
    private readonly DebouncedSignal _debounce;
    private readonly SemaphoreSlim _scanGate = new(1, 1);
    private IReadOnlyList<LinkedSqlFolder> _folders = [];
    private IReadOnlyList<SqlFolderScan> _current = [];
    private bool _disposed;

    public SqlFolderWatcher(TimeSpan? delay = null)
    {
        _debounce = new DebouncedSignal(delay ?? DefaultDelay, () => _ = RescanAsync());
    }

    public event EventHandler? Scanned;

    public IReadOnlyList<SqlFolderScan> Current => Volatile.Read(ref _current);

    public IReadOnlyList<LinkedSqlFolder> Folders => Volatile.Read(ref _folders);

    /// <summary>Starts watching exactly <paramref name="folders"/> (the enabled ones) and scans them now.</summary>
    public Task WatchAsync(IEnumerable<LinkedSqlFolder> folders, CancellationToken cancellationToken = default)
    {
        var enabled = folders.Where(f => f.IsEnabled).ToList();
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            DisposeWatchers();
            Volatile.Write(ref _folders, enabled);
            foreach (var folder in enabled)
            {
                if (CreateWatcher(folder.ExpandedPath) is { } watcher)
                {
                    _watchers.Add(watcher);
                }
            }
        }

        _debounce.Cancel();
        return RescanAsync(cancellationToken);
    }

    /// <summary>Scans every watched folder now, replacing <see cref="Current"/>.</summary>
    public async Task RescanAsync(CancellationToken cancellationToken = default)
    {
        await _scanGate.WaitAsync(cancellationToken);
        try
        {
            var folders = Folders;
            var scans = await Task.Run(() => folders.Select(f => SqlFolderScanner.Scan(f, cancellationToken)).ToList(), cancellationToken);
            Volatile.Write(ref _current, scans);
        }
        finally
        {
            _scanGate.Release();
        }

        Scanned?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            DisposeWatchers();
        }

        _debounce.Dispose();
    }

    /// <summary>
    /// True when every changed path is inside a <c>.git</c> folder: git's own bookkeeping, which the repository
    /// watcher handles, rather than a change to the queries.
    /// </summary>
    public static bool TouchesOnlyRepositoryMetadata(IEnumerable<string> paths)
    {
        var any = false;
        foreach (var path in paths)
        {
            any = true;
            if (!path.Split(['\\', '/']).Contains(".git", StringComparer.OrdinalIgnoreCase))
            {
                return false;
            }
        }

        return any;
    }

    private FileSystemWatcher? CreateWatcher(string path)
    {
        if (!Directory.Exists(path))
        {
            return null;
        }

        try
        {
            var watcher = new FileSystemWatcher(path)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,

                // The largest buffer Windows allows for a network share; an overflow still rescans through Error.
                InternalBufferSize = 64 * 1024,
            };
            watcher.Changed += OnChanged;
            watcher.Created += OnChanged;
            watcher.Deleted += OnChanged;
            watcher.Renamed += OnRenamed;
            watcher.Error += (_, _) => _debounce.Signal();
            watcher.EnableRaisingEvents = true;
            return watcher;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void OnChanged(object sender, FileSystemEventArgs e)
    {
        if (!TouchesOnlyRepositoryMetadata([e.FullPath]))
        {
            _debounce.Signal();
        }
    }

    private void OnRenamed(object sender, RenamedEventArgs e)
    {
        if (!TouchesOnlyRepositoryMetadata([e.FullPath, e.OldFullPath]))
        {
            _debounce.Signal();
        }
    }

    private void DisposeWatchers()
    {
        foreach (var watcher in _watchers)
        {
            watcher.EnableRaisingEvents = false;
            watcher.Dispose();
        }

        _watchers.Clear();
    }
}
