using Microsoft.UI.Xaml;
using TablePro.App.ViewModels;

namespace TablePro.App.Services;

public enum BackdropKind
{
    Acrylic,
    Mica,
    MicaAlt,
    None,
}

/// <summary>What a workspace window asks of the application: shared panes, settings and its own lifetime.</summary>
public interface IWorkspaceHost
{
    BackdropKind Backdrop { get; }

    ElementTheme Theme { get; }

    void OpenSettings();

    void ShowWelcome();

    /// <summary>The query history pane, which calls back with SQL to insert into the active editor.</summary>
    UIElement CreateHistoryPane(WorkspaceViewModel workspace, Action<string> insert, Action<string> run);

    UIElement CreateFavoritesPane(WorkspaceViewModel workspace, Action<string> insert);

    UIElement CreateAssistantPane(WorkspaceViewModel workspace, Func<string> currentSql, Action<string> insert);

    Task SaveFavoriteAsync(WorkspaceViewModel workspace, string sql, DialogService dialogs);

    void WorkspaceClosed(object window);
}
