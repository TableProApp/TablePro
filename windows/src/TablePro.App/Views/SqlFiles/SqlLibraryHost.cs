using Microsoft.Data.Sqlite;
using TablePro.Storage;
using TablePro.Storage.Library;
using TablePro.Storage.Library.Folders;
using TablePro.Storage.Library.Git;
using TablePro.Storage.Library.History;
using TablePro.Storage.Library.Team;

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

    public static SqlLibrary Shared => Instance.Value;

    /// <summary>
    /// The license that grants the team library. The Windows app has no license yet, so the team library stays hidden
    /// until a license provider is set here.
    /// </summary>
    public static Func<TeamLibraryCredentials?> TeamCredentials { get; set; } = static () => null;

    public static Task EnsureStartedAsync() => _started ??= Shared.StartAsync();

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

    private static SqlLibrary Create()
    {
        var paths = AppPaths.Default;
        var team = new TeamLibrarySync(new HttpTeamLibraryApiClient(TeamHttp), new TeamLibraryStore(paths), () => TeamCredentials());
        return new SqlLibrary(new LinkedSqlFolderStore(paths), new LocalSnapshotStore(paths), GitClient.Create(), team, ShellRecycleBin.Instance);
    }

    private static void CrashLogNote(Exception ex) => Services.CrashLog.Write("Keeping a saved version of a file", ex);
}
