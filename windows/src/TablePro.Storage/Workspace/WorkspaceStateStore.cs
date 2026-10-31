using System.Collections.Concurrent;
using System.Text.Json.Nodes;

namespace TablePro.Storage.Workspace;

/// <summary>
/// One file per connection under <c>workspaces\</c>, so saving the tabs of one window never rewrites another's.
/// Saves for the same connection are serialized; the UI should debounce, since every call writes the file.
/// </summary>
public sealed class WorkspaceStateStore : IDisposable
{
    private readonly AppPaths _paths;
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _gates = new();

    public WorkspaceStateStore(AppPaths paths)
    {
        _paths = paths;
    }

    public async Task<WorkspaceState?> LoadAsync(Guid connectionId, CancellationToken cancellationToken = default)
    {
        var gate = GateFor(connectionId);
        await gate.WaitAsync(cancellationToken);
        try
        {
            var state = await AtomicFile.ReadJsonAsync(_paths.WorkspaceFile(connectionId), StorageJson.Workspace, RestoreDefaults, cancellationToken);
            if (state is null || state.ConnectionId != connectionId)
            {
                return null;
            }

            var tabs = state.Tabs ?? [];
            return state with
            {
                Tabs = tabs,
                SelectedIndex = tabs.Count == 0 ? 0 : Math.Clamp(state.SelectedIndex, 0, tabs.Count - 1),
            };
        }
        finally
        {
            gate.Release();
        }
    }

    public async Task SaveAsync(WorkspaceState state, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(state);
        var gate = GateFor(state.ConnectionId);
        await gate.WaitAsync(cancellationToken);
        try
        {
            await AtomicFile.WriteJsonAsync(
                _paths.WorkspaceFile(state.ConnectionId),
                state with { SavedAt = DateTimeOffset.UtcNow },
                StorageJson.Workspace,
                cancellationToken);
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>Forgets a connection's session, as when the connection itself is deleted.</summary>
    public async Task DeleteAsync(Guid connectionId, CancellationToken cancellationToken = default)
    {
        var gate = GateFor(connectionId);
        await gate.WaitAsync(cancellationToken);
        try
        {
            File.Delete(_paths.WorkspaceFile(connectionId));
        }
        finally
        {
            gate.Release();
        }
    }

    public void Dispose()
    {
        foreach (var gate in _gates.Values)
        {
            gate.Dispose();
        }

        _gates.Clear();
    }

    private static JsonObject RestoreDefaults(JsonObject root)
    {
        var merged = JsonDefaults.Overlay(root, new WorkspaceState { ConnectionId = Guid.Empty }, StorageJson.Workspace);
        JsonDefaults.OverlayEach(merged, "tabs", static () => new WorkspaceTab(), StorageJson.Tab);
        return merged;
    }

    private SemaphoreSlim GateFor(Guid connectionId) => _gates.GetOrAdd(connectionId, static _ => new SemaphoreSlim(1, 1));
}
