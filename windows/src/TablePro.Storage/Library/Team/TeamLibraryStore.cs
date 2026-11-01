using System.Text.Json;

namespace TablePro.Storage.Library.Team;

/// <summary>
/// The local copy of the pulled team library in <c>team_library.json</c>, in the pull response's own format as the
/// macOS app caches it, and when it was last pulled in <c>team_library_state.json</c>. Every read and write is
/// sanitized, so a hand-edited cache cannot bring back a startup command.
/// </summary>
public sealed class TeamLibraryStore : IDisposable
{
    private readonly string _libraryPath;
    private readonly string _statePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private TeamLibraryPullResponse? _cached;

    public TeamLibraryStore(AppPaths paths)
        : this(Path.Combine(paths.Root, "team_library.json"), Path.Combine(paths.Root, "team_library_state.json"))
    {
    }

    public TeamLibraryStore(string libraryPath, string statePath)
    {
        _libraryPath = Path.GetFullPath(libraryPath);
        _statePath = Path.GetFullPath(statePath);
    }

    public async Task<TeamLibraryPullResponse?> LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (_cached is not null)
            {
                return _cached;
            }

            try
            {
                var loaded = await AtomicFile.ReadJsonAsync(_libraryPath, LibraryJson.PullResponse, null, cancellationToken);
                _cached = loaded?.Sanitized();
            }
            catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException)
            {
                _cached = null;
            }

            return _cached;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task ReplaceAsync(TeamLibraryPullResponse response, DateTimeOffset pulledAt, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(response);
        var sanitized = response.Sanitized();
        await _gate.WaitAsync(cancellationToken);
        try
        {
            await AtomicFile.WriteJsonAsync(_libraryPath, sanitized, LibraryJson.PullResponse, cancellationToken);
            await AtomicFile.WriteJsonAsync(_statePath, new TeamLibraryState { LastPullAt = pulledAt }, LibraryJson.TeamState, cancellationToken);
            _cached = sanitized;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<DateTimeOffset?> LastPullAtAsync(CancellationToken cancellationToken = default) =>
        (await AtomicFile.ReadJsonAsync(_statePath, LibraryJson.TeamState, null, cancellationToken))?.LastPullAt;

    /// <summary>Drops the cache and the pull time, as when the license that granted the library is removed.</summary>
    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            _cached = TeamLibraryPullResponse.Empty;
            File.Delete(_libraryPath);
            File.Delete(_statePath);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose() => _gate.Dispose();
}
