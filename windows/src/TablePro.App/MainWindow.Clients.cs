using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.App.Views;
using TablePro.Interop;

namespace TablePro.App;

// What an MCP client or the tablepro command asks of the windows, through McpBridge, as the Linux app answers it.
public sealed partial class MainWindow
{
    // As Connect opens it; a workspace whose connect failed keeps that until the user acts there.
    internal async Task<bool> OpenForClientAsync(Guid connectionId)
    {
        if (!IsPrimary)
        {
            return await _primary.OpenForClientAsync(connectionId).ConfigureAwait(true);
        }

        if (OpenFor(connectionId, null) is { } open)
        {
            WindowOf(open).Bring(open);
            return open.State != ConnectionState.Failed;
        }

        SavedConnection? saved;
        try
        {
            var snapshot = await _workbench.Library.GetSnapshotAsync().ConfigureAwait(true);
            saved = snapshot.Connections.FirstOrDefault(connection => connection.Id == connectionId);
        }
        catch (TableProException)
        {
            return false;
        }

        if (saved is null || _closing)
        {
            return false;
        }

        Activate();
        Connect(saved);
        return true;
    }

    internal bool IsConnecting(Guid connectionId) =>
        _primary.OpenFor(connectionId, null) is { State: ConnectionState.Connecting };

    // Whatever the Safe Mode level: a client asking is not the user asking.
    internal async Task<bool> ApproveForClientAsync(McpWriteRequest request, CancellationToken withdrawn)
    {
        if (_primary.OpenFor(request.ConnectionId, request.Database) is not { Session: not null } open)
        {
            return false;
        }

        WindowOf(open).Bring(open);
        return await open.View.ConfirmClientWriteAsync(request, open.Title, withdrawn).ConfigureAwait(true);
    }

    // The hidden spare is left out: it only holds a tab while a drag is under way.
    private IEnumerable<MainWindow> ShownWindows => _primary.AllWindows.Where(window => !window._isSpare);

    private OpenConnection? OpenFor(Guid connectionId, string? database) =>
        ShownWindows
            .SelectMany(window => window._open)
            .FirstOrDefault(open => open.ConnectionId == connectionId
                && string.Equals(open.Database, database, StringComparison.Ordinal));

    private MainWindow WindowOf(OpenConnection open) =>
        ShownWindows.FirstOrDefault(window => window._open.Contains(open)) ?? _primary;

    private void Bring(OpenConnection open)
    {
        try
        {
            SingleInstance.BringToFront(this);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
        }

        if (IsPrimary)
        {
            Select(open);
        }
        else
        {
            Show(open);
        }
    }
}
