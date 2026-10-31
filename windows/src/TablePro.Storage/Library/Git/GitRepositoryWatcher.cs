namespace TablePro.Storage.Library.Git;

/// <summary>
/// Watches repositories' git folders and raises <see cref="Changed"/> after a commit, checkout, stage or pull made
/// anywhere, including in another tool, so the Git badges in the linked folders follow. A linked folder deep inside a
/// repository does not contain the repository's <c>.git</c>, so the folder watcher alone would miss these.
/// </summary>
public sealed class GitRepositoryWatcher : IDisposable
{
    private readonly object _lock = new();
    private readonly Dictionary<string, FileSystemWatcher> _watchers = new(StringComparer.OrdinalIgnoreCase);
    private readonly DebouncedSignal _debounce;
    private bool _disposed;

    public GitRepositoryWatcher(TimeSpan? delay = null)
    {
        _debounce = new DebouncedSignal(delay ?? TimeSpan.FromMilliseconds(500), () => Changed?.Invoke(this, EventArgs.Empty));
    }

    /// <summary>Fires on a thread-pool thread.</summary>
    public event EventHandler? Changed;

    /// <summary>Watches exactly <paramref name="gitDirectories"/>, keeping the watchers it already has for any of them.</summary>
    public void Watch(IEnumerable<string> gitDirectories)
    {
        var wanted = gitDirectories.Where(Directory.Exists).ToHashSet(StringComparer.OrdinalIgnoreCase);
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            foreach (var stale in _watchers.Keys.Where(k => !wanted.Contains(k)).ToList())
            {
                _watchers[stale].Dispose();
                _watchers.Remove(stale);
            }

            foreach (var directory in wanted.Where(d => !_watchers.ContainsKey(d)))
            {
                try
                {
                    var watcher = new FileSystemWatcher(directory)
                    {
                        IncludeSubdirectories = true,
                        NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite,
                    };
                    watcher.Changed += OnChanged;
                    watcher.Created += OnChanged;
                    watcher.Deleted += OnChanged;
                    watcher.Renamed += OnChanged;
                    watcher.Error += (_, _) => _debounce.Signal();
                    watcher.EnableRaisingEvents = true;
                    _watchers[directory] = watcher;
                }
                catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
                {
                }
            }
        }
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
            foreach (var watcher in _watchers.Values)
            {
                watcher.Dispose();
            }

            _watchers.Clear();
        }

        _debounce.Dispose();
    }

    private void OnChanged(object sender, FileSystemEventArgs e)
    {
        // Object writes and lock files churn during every git command; the index, HEAD and refs are what move when
        // the state the badges show changes.
        var name = Path.GetFileName(e.FullPath);
        if (name.EndsWith(".lock", StringComparison.OrdinalIgnoreCase) || e.FullPath.Contains(@"\objects\", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _debounce.Signal();
    }
}
