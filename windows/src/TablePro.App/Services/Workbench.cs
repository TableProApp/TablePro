using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed class Workbench : IDisposable
{
    private readonly SettingsStore _settings;

    public Workbench(TableProCore core, string folder)
    {
        Core = core;
        Folder = folder;
        _settings = new SettingsStore(Path.Combine(folder, "settings.json"));
        Sessions = new SessionStore(Path.Combine(folder, "session.json"));
        Settings = _settings.Load();
    }

    public event EventHandler? SettingsChanged;

    // Raised after this app changed the saved connections, so every list rebuilds from a new snapshot.
    public event EventHandler? LibraryChanged;

    public TableProCore Core { get; }

    public string Folder { get; }

    public ConnectionLibrary Library => Core.Library;

    public IReadOnlyList<DatabaseEngine> Engines => Core.Engines;

    public SessionStore Sessions { get; }

    public AppSettings Settings { get; private set; }

    // Shared by every workspace and kept in the session file.
    public double ObjectPaneWidth { get; set; } = ObjectPane.DefaultWidth;

    public DatabaseEngine? Engine(string id) => Engines.FirstOrDefault(engine => engine.Id == id);

    public string EngineName(string id) => Engine(id)?.DisplayName ?? id;

    public bool IsFileEngine(string id) => Engine(id) is { DefaultPort: null };

    public void UpdateSettings(Func<AppSettings, AppSettings> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        var next = change(Settings).Normalized();
        if (next == Settings)
        {
            return;
        }

        Settings = next;
        _settings.Save(next);
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void NotifyLibraryChanged() => LibraryChanged?.Invoke(this, EventArgs.Empty);

    // The Chinook sample is copied out of the app once, so edits to it stay.
    public async Task<SavedConnection> InstallSampleAsync()
    {
        var target = Path.Combine(Folder, "Samples", "Chinook.sqlite");
        if (!File.Exists(target))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var source = Path.Combine(AppContext.BaseDirectory, "Assets", "Samples", "Chinook.sqlite");
            File.Copy(source, target);
        }

        var snapshot = await Library.GetSnapshotAsync().ConfigureAwait(true);
        var existing = snapshot.Connections.FirstOrDefault(connection =>
            connection.EngineId == "sqlite" && string.Equals(connection.Database, target, StringComparison.OrdinalIgnoreCase));
        if (existing is not null)
        {
            return existing;
        }

        var sample = new SavedConnection(
            null, Strings.Get("SampleConnectionName"), "sqlite", string.Empty, 0, target, string.Empty, TlsSettings.Disabled);
        var saved = await Library.SaveAsync(sample, ConnectionSecrets.None).ConfigureAwait(true);
        NotifyLibraryChanged();
        return saved;
    }

    // A ContentDialog opens one at a time on a thread, so prompts that may meet wait for each other.
    public SemaphoreSlim Dialogs { get; } = new(1, 1);

    public void Dispose()
    {
        Dialogs.Dispose();
        Core.Dispose();
    }
}
