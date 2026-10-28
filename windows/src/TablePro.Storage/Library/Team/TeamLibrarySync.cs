using System.Text.Json.Nodes;
using TablePro.Storage.Favorites;

namespace TablePro.Storage.Library.Team;

/// <summary>
/// Keeps the team library: loads the cache at start, pulls from the service at most once a week (or when asked), and
/// publishes this user's saved queries and connections, which replaces what they published before. It is the macOS
/// app's sync coordinator; the license that grants the library reaches it through <c>credentials</c>.
/// </summary>
public sealed class TeamLibrarySync(ITeamLibraryApiClient api, TeamLibraryStore store, Func<TeamLibraryCredentials?> credentials, TimeProvider? clock = null)
{
    public static readonly TimeSpan PullInterval = TimeSpan.FromDays(7);

    private readonly TimeProvider _clock = clock ?? TimeProvider.System;
    private TeamLibraryPullResponse _library = TeamLibraryPullResponse.Empty;

    /// <summary>Fires on the thread that changed the library.</summary>
    public event EventHandler? Changed;

    /// <summary>What the panes show. Empty until loaded, and empty again after <see cref="ClearAsync"/>.</summary>
    public TeamLibraryPullResponse Library => Volatile.Read(ref _library);

    /// <summary>Whether this machine holds a license that grants the team library.</summary>
    public bool IsAvailable => credentials() is not null;

    public bool IsPublishing { get; private set; }

    /// <summary>Shows the cached library at once, then pulls when a pull is due.</summary>
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return;
        }

        if (await store.LoadAsync(cancellationToken) is { } cached)
        {
            SetLibrary(cached);
        }

        await PullIfDueAsync(cancellationToken);
    }

    public async Task PullIfDueAsync(CancellationToken cancellationToken = default)
    {
        if (!IsAvailable)
        {
            return;
        }

        var last = await store.LastPullAtAsync(cancellationToken);
        if (last is null || _clock.GetUtcNow() - last.Value >= PullInterval)
        {
            await PullAsync(cancellationToken);
        }
    }

    /// <summary>Pulls now. A failure keeps the cached library and returns the reason.</summary>
    public async Task<string?> PullAsync(CancellationToken cancellationToken = default)
    {
        if (credentials() is not { } license)
        {
            return null;
        }

        try
        {
            var response = await api.PullAsync(license, cancellationToken);
            await store.ReplaceAsync(response, _clock.GetUtcNow(), cancellationToken);
            SetLibrary(response.Sanitized());
            return null;
        }
        catch (TeamLibraryException ex)
        {
            return ex.Message;
        }
    }

    /// <summary>Drops the team's library from disk and from what every pane shows.</summary>
    public async Task ClearAsync(CancellationToken cancellationToken = default)
    {
        await store.ClearAsync(cancellationToken);
        SetLibrary(TeamLibraryPullResponse.Empty);
    }

    /// <summary>
    /// Publishes saved queries, their folders and connection payloads (the macOS export format, without passwords),
    /// then pulls so the panes show what the team now sees.
    /// </summary>
    public async Task<TeamLibraryPublishResponse> PublishAsync(
        IEnumerable<SqlFavorite> favorites,
        IEnumerable<SqlFavoriteFolder> folders,
        IEnumerable<(Guid SourceId, JsonObject Payload)>? connections = null,
        CancellationToken cancellationToken = default)
    {
        var license = credentials() ?? throw new TeamLibraryException("Activate a Team license to publish to the team library.");
        IsPublishing = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var request = BuildPublishRequest(license, favorites, folders, connections ?? []);
            var response = await api.PublishAsync(request, cancellationToken);
            await PullAsync(cancellationToken);
            return response;
        }
        finally
        {
            IsPublishing = false;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>The publish request for these items. Ids are written as the macOS app writes UUIDs, upper case, so both apps name an item the same way.</summary>
    public static TeamLibraryPublishRequest BuildPublishRequest(
        TeamLibraryCredentials license,
        IEnumerable<SqlFavorite> favorites,
        IEnumerable<SqlFavoriteFolder> folders,
        IEnumerable<(Guid SourceId, JsonObject Payload)> connections)
    {
        ArgumentNullException.ThrowIfNull(license);
        return new TeamLibraryPublishRequest(
            license.LicenseKey,
            license.MachineId,
            [.. connections.Select(c => new TeamLibraryConnectionPayload(Id(c.SourceId), c.Payload))],
            [.. folders.Select(f => new TeamLibraryQueryFolderPayload(Id(f.Id), f.ParentId is { } parent ? Id(parent) : null, f.Name, f.SortOrder))],
            [.. favorites.Select(f => new TeamLibraryQueryPayload(Id(f.Id), f.FolderId is { } folder ? Id(folder) : null, f.ConnectionId is { } connection ? Id(connection) : null, f.Name, f.Query, f.Keyword, f.SortOrder))]);
    }

    /// <summary>The team queries a connection's window lists: the unscoped ones and those published for this connection.</summary>
    public IReadOnlyList<TeamLibraryQuery> QueriesFor(Guid? connectionId)
    {
        var id = connectionId is { } value ? Id(value) : null;
        return [.. Library.Queries
            .Where(q => q.ConnectionClientId is null || string.Equals(q.ConnectionClientId, id, StringComparison.OrdinalIgnoreCase))
            .OrderBy(q => q.SortOrder)
            .ThenBy(q => q.Name, StringComparer.CurrentCultureIgnoreCase)];
    }

    private static string Id(Guid id) => id.ToString("D").ToUpperInvariant();

    private void SetLibrary(TeamLibraryPullResponse library)
    {
        Volatile.Write(ref _library, library);
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
