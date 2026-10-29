using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.App.ViewModels;

public enum ServerSection
{
    Activity,
    Variables,
    Users,
}

/// <summary>
/// The server dashboard: sessions and what they run, server variables, and logins. Where the engine has a Users and
/// Roles editor, the Users section is that editor rather than a read-only list.
/// </summary>
public sealed partial class ServerTabViewModel : TabViewModel
{
    private readonly WorkspaceContext _context;
    private CancellationTokenSource? _autoRefresh;
    private UsersRolesViewModel? _usersRoles;
    private IDatabaseSession? _usersRolesSession;

    public ServerTabViewModel(WorkspaceContext context)
    {
        _context = context;
        Title = Strings.Get("Server/TabTitle");
        Subtitle = context.Session.Profile.Name;
    }

    public override string Glyph => "";

    public WorkspaceContext Context => _context;

    public bool SupportsActivity => _context.Session.Database is IServerActivityProvider;

    public bool SupportsVariables => _context.Session.Database is IServerVariablesProvider;

    public bool SupportsUsers => _context.Session.Database is IUserListProvider || UsersRoles is not null;

    /// <summary>
    /// The Users and Roles editor, or null where the engine has none. A database switch replaces the session it reads
    /// through, so the editor is made again for the new one.
    /// </summary>
    public UsersRolesViewModel? UsersRoles
    {
        get
        {
            var database = _context.Session.Database;
            if (!ReferenceEquals(database, _usersRolesSession))
            {
                _usersRolesSession = database;
                _usersRoles = database is IUserAdministration { Features: { } features } administration
                    ? new UsersRolesViewModel(_context, administration, features)
                    : null;
            }

            return _usersRoles;
        }
    }

    public bool ShowsUsersEditor => Section == ServerSection.Users && UsersRoles is not null;

    public override string? UnsavedWork => _usersRoles?.UnsavedWork;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowsUsersEditor))]
    public partial ServerSection Section { get; set; }

    [ObservableProperty]
    public partial IGridSource? Grid { get; set; }

    [ObservableProperty]
    public partial bool AutoRefresh { get; set; }

    [ObservableProperty]
    public partial string? Message { get; set; }

    [RelayCommand]
    public Task RefreshAsync() => ShowSectionAsync(reload: true);

    private async Task ShowSectionAsync(bool reload)
    {
        if (ShowsUsersEditor)
        {
            // The editor keeps what it staged across a reload, so Refresh never loses work.
            Grid = null;
            Message = null;
            StatusText = null;
            await UsersRoles!.LoadAsync(force: reload);
            return;
        }

        IsBusy = true;
        Message = null;
        try
        {
            var database = _context.Session.Database;
            var result = Section switch
            {
                ServerSection.Activity when database is IServerActivityProvider activity => await activity.GetActivityAsync(CancellationToken.None),
                ServerSection.Variables when database is IServerVariablesProvider variables => await variables.GetVariablesAsync(CancellationToken.None),
                ServerSection.Users when database is IUserListProvider users => await users.GetUsersAsync(CancellationToken.None),
                _ => null,
            };
            Grid = result is null ? null : new ResultGridSource(result);
            Message = result is null ? NoViewMessage(_context.Session.Profile.Descriptor.DisplayName) : null;
            StatusText = result is null ? null : Strings.Plural("Server/StatusRows", result.RowCount, DateTime.Now);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Grid = null;
            Message = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    private string NoViewMessage(string engine) => Section switch
    {
        ServerSection.Activity => Strings.Format("Server/NoActivityView", engine),
        ServerSection.Variables => Strings.Format("Server/NoVariablesView", engine),
        _ => Strings.Format("Server/NoUsersView", engine),
    };

    /// <summary>Ends the server session on the selected row, after asking.</summary>
    public async Task TerminateAsync(int row)
    {
        if (_context.Session.Database is not IServerActivityProvider activity || Grid is null || Section != ServerSection.Activity)
        {
            return;
        }

        var column = -1;
        for (var i = 0; i < Grid.Columns.Count; i++)
        {
            if (string.Equals(Grid.Columns[i].Name, activity.ProcessIdColumn, StringComparison.OrdinalIgnoreCase))
            {
                column = i;
                break;
            }
        }

        if (column < 0 || Grid.GetValue(row, column) is not { } id)
        {
            return;
        }

        if (_context.Session.Profile.SafeMode.BlocksAllWrites()
            || !await _context.Dialogs.ConfirmAsync(Strings.Get("Server/EndSessionTitle"), Strings.Format("Server/EndSessionMessage", id), Strings.Get("Server/Terminate"), destructive: true))
        {
            return;
        }

        try
        {
            await activity.TerminateAsync(id, CancellationToken.None);
            await RefreshAsync();
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            await _context.Dialogs.ShowErrorAsync(Strings.Get("Server/EndSessionFailed"), ex.Message);
        }
    }

    public override ValueTask DisposeAsync()
    {
        _autoRefresh?.Cancel();
        _autoRefresh?.Dispose();
        return base.DisposeAsync();
    }

    // Coming back to the editor shows what was staged there; only Refresh rereads the server.
    async partial void OnSectionChanged(ServerSection value) => await ShowSectionAsync(reload: false);

    async partial void OnAutoRefreshChanged(bool value)
    {
        _autoRefresh?.Cancel();
        if (!value)
        {
            return;
        }

        _autoRefresh = new CancellationTokenSource();
        var token = _autoRefresh.Token;
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                // Rereading every principal and grant every few seconds would only fight the editor.
                if (!ShowsUsersEditor)
                {
                    await RefreshAsync();
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }
}
