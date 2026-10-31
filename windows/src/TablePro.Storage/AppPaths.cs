namespace TablePro.Storage;

/// <summary>
/// Where every store keeps its files. The app uses <see cref="Default"/>; tests pass a temporary root so they never
/// touch the user's data.
/// </summary>
public sealed class AppPaths
{
    private static readonly Lazy<AppPaths> DefaultPaths = new(() => new AppPaths());

    /// <param name="root">The folder that holds everything. Null means <c>%LOCALAPPDATA%\TablePro</c>.</param>
    public AppPaths(string? root = null)
    {
        Root = Path.GetFullPath(root ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData, Environment.SpecialFolderOption.Create),
            "TablePro"));
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(WorkspaceDirectory);
    }

    public static AppPaths Default => DefaultPaths.Value;

    public string Root { get; }

    public string ConnectionsFile => Path.Combine(Root, "connections.json");

    public string FavoritesFile => Path.Combine(Root, "favorites.json");

    public string SettingsFile => Path.Combine(Root, "settings.json");

    public string HistoryDatabase => Path.Combine(Root, "history.db");

    public string WorkspaceDirectory => Path.Combine(Root, "workspaces");

    public string WorkspaceFile(Guid connectionId) => Path.Combine(WorkspaceDirectory, connectionId.ToString("D") + ".json");
}
