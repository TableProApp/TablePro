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

/// <summary>The server dashboard: sessions and what they run, server variables, and logins.</summary>
public sealed partial class ServerTabViewModel : TabViewModel
{
    private readonly WorkspaceContext _context;
    private CancellationTokenSource? _autoRefresh;

    public ServerTabViewModel(WorkspaceContext context)
    {
        _context = context;
        Title = "Server";
        Subtitle = context.Session.Profile.Name;
    }

    public override string Glyph => "";

    public WorkspaceContext Context => _context;

    public bool SupportsActivity => _context.Session.Database is IServerActivityProvider;

    public bool SupportsVariables => _context.Session.Database is IServerVariablesProvider;

    public bool SupportsUsers => _context.Session.Database is IUserListProvider;

    [ObservableProperty]
    public partial ServerSection Section { get; set; }

    [ObservableProperty]
    public partial IGridSource? Grid { get; set; }

    [ObservableProperty]
    public partial bool AutoRefresh { get; set; }

    [ObservableProperty]
    public partial string? Message { get; set; }

    [RelayCommand]
    public async Task RefreshAsync()
    {
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
            Message = result is null ? $"{_context.Session.Profile.Descriptor.DisplayName} has no {Section.ToString().ToLowerInvariant()} view." : null;
            StatusText = result is null ? null : $"{result.RowCount:N0} rows · {DateTime.Now:T}";
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
            || !await _context.Dialogs.ConfirmAsync("End session?", $"Terminate server session {id}? Its running statement is cancelled and its connection closed.", "Terminate", destructive: true))
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
            await _context.Dialogs.ShowErrorAsync("Could not end the session", ex.Message);
        }
    }

    public override ValueTask DisposeAsync()
    {
        _autoRefresh?.Cancel();
        _autoRefresh?.Dispose();
        return base.DisposeAsync();
    }

    async partial void OnSectionChanged(ServerSection value) => await RefreshAsync();

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
                await RefreshAsync();
            }
        }
        catch (OperationCanceledException)
        {
        }
    }
}
