namespace TablePro.Storage.Settings;

/// <summary>
/// The app's preferences in <c>settings.json</c>. <see cref="Current"/> is <see cref="AppSettings.Default"/> until
/// <see cref="LoadAsync"/> runs. <see cref="Changed"/> carries the new value and fires on the saving thread.
/// </summary>
public sealed class SettingsStore : IDisposable
{
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private AppSettings _current = AppSettings.Default;

    public SettingsStore(AppPaths paths)
        : this(paths.SettingsFile)
    {
    }

    public SettingsStore(string filePath)
    {
        _path = Path.GetFullPath(filePath);
    }

    public event EventHandler<AppSettings>? Changed;

    public AppSettings Current => Volatile.Read(ref _current);

    public async Task<AppSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        AppSettings loaded;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var stored = await AtomicFile.ReadJsonAsync(
                _path,
                StorageJson.Settings,
                static root => JsonDefaults.Overlay(root, AppSettings.Default, StorageJson.Settings),
                cancellationToken);
            loaded = (stored ?? AppSettings.Default).Normalize();
            Volatile.Write(ref _current, loaded);
        }
        finally
        {
            _gate.Release();
        }

        Changed?.Invoke(this, loaded);
        return loaded;
    }

    public Task<AppSettings> SaveAsync(AppSettings settings, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return UpdateAsync(_ => settings, cancellationToken);
    }

    /// <summary>Applies a change to the latest value, so two quick edits from different pages never undo each other.</summary>
    public async Task<AppSettings> UpdateAsync(Func<AppSettings, AppSettings> change, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(change);
        AppSettings next;
        bool changed;
        await _gate.WaitAsync(cancellationToken);
        try
        {
            next = change(_current).Normalize();
            changed = next != _current;
            if (changed)
            {
                await AtomicFile.WriteJsonAsync(_path, next, StorageJson.Settings, cancellationToken);
                Volatile.Write(ref _current, next);
            }
        }
        finally
        {
            _gate.Release();
        }

        if (changed)
        {
            Changed?.Invoke(this, next);
        }

        return next;
    }

    public void Dispose() => _gate.Dispose();
}
