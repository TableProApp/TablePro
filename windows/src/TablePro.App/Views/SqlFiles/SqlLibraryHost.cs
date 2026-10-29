using Microsoft.Data.Sqlite;
using TablePro.Core.Licensing;
using TablePro.Storage;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;
using TablePro.Storage.Library.Team;
using TablePro.Storage.Licensing;

namespace TablePro.App.Views.SqlFiles;

/// <summary>
/// The one <see cref="SqlLibrary"/> every window shares, created on first use so a session that never opens the SQL
/// files pane pays nothing for it. The folder watchers and the git lookup live as long as the app.
/// </summary>
internal static class SqlLibraryHost
{
    private static readonly Lazy<SqlLibrary> Instance = new(Create);
    private static readonly HttpClient TeamHttp = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static Task? _started;
    private static LicenseService? _license;

    public static SqlLibrary Shared => Instance.Value;

    public static Task EnsureStartedAsync() => _started ??= Shared.StartAsync();

    /// <summary>
    /// The license that grants the team library: only an active Team license does, as on macOS, and the library follows
    /// it from then on. Launch sets it before a window can open the SQL files pane.
    /// </summary>
    public static void UseLicense(LicenseService license)
    {
        _license = license;
        if (Instance.IsValueCreated)
        {
            Shared.Team?.Follow(license);
        }

        // A library never opened this session still has last session's cache on disk, which must not outlive the license.
        license.Removed += async (_, _) =>
        {
            if (Instance.IsValueCreated)
            {
                return;
            }

            using var store = new TeamLibraryStore(AppPaths.Default);
            try
            {
                await store.ClearAsync();
            }
            catch (IOException ex)
            {
                Services.CrashLog.Write("Removing the team library cache", ex);
            }
        };
    }

    /// <summary>
    /// Keeps the saved file's text as a version of it. The editor calls this after every save; a failure here must
    /// never fail the save, which already reached the disk.
    /// </summary>
    public static async Task RecordSaveAsync(string path)
    {
        try
        {
            await Shared.RecordSaveAsync(path);
        }
        catch (SqliteException ex)
        {
            CrashLogNote(ex);
        }
        catch (IOException ex)
        {
            CrashLogNote(ex);
        }
    }

    private static TeamLibraryCredentials? TeamCredentials() =>
        _license is { } license && license.IsFeatureAvailable(ProFeature.TeamLibrary) && license.License is { } held
            ? new TeamLibraryCredentials(held.Key, license.MachineId)
            : null;

    private static SqlLibrary Create()
    {
        var paths = AppPaths.Default;
        var team = new TeamLibrarySync(new HttpTeamLibraryApiClient(TeamHttp), new TeamLibraryStore(paths), TeamCredentials);
        if (_license is { } license)
        {
            team.Follow(license);
        }

        return new SqlLibrary(new LinkedSqlFolderStore(paths), new LocalSnapshotStore(paths), GitClient.Create(), team, ShellRecycleBin.Instance);
    }

    private static void CrashLogNote(Exception ex) => Services.CrashLog.Write("Keeping a saved version of a file", ex);
}
