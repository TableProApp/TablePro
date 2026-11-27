using System.Text.Json;
using TablePro.Interop;

namespace TablePro.App.Model;

// A team's saved query and folder as the team library keeps them, with who last changed each.
public sealed record TeamQuery(
    string Team,
    string Id,
    string Name,
    string Sql,
    string? Keyword,
    string? FolderId,
    long SortOrder,
    string? UpdatedBy,
    DateTimeOffset? UpdatedAt);

public sealed record TeamFolder(
    string Team,
    string Id,
    string Name,
    string? ParentId,
    long SortOrder,
    string? UpdatedBy,
    DateTimeOffset? UpdatedAt);

// One team as this account reads it. Connections are counted only: this app reads no team connection yet.
public sealed record TeamView(
    string TeamId,
    string? Name,
    TeamRole? Role,
    bool CanWrite,
    IReadOnlyList<TeamFolder> Folders,
    IReadOnlyList<TeamQuery> Queries,
    int Connections);

// A team as the person picked it, under the sign-in and Team Library owner shown then: a publish goes out only while
// that sign-in holds, and the core refuses it on another owner's engine.
public sealed record TeamDestination(string TeamId, string? Session, TeamLibraryOwner? Owner);

public abstract record TeamPublishOutcome
{
    private TeamPublishOutcome()
    {
    }

    public sealed record Unchanged : TeamPublishOutcome
    {
        public static Unchanged Instance { get; } = new();
    }

    public sealed record Published(int Edits) : TeamPublishOutcome;

    // Both sides changed these items, which wait for Keep mine or Keep theirs.
    public sealed record Conflicts(int Count) : TeamPublishOutcome;

    // Kept on this computer and sent once the team library answers again.
    public sealed record Queued(string? Code) : TeamPublishOutcome;

    public sealed record Failed(string Code) : TeamPublishOutcome;

    // Only the team's owner, admins and editors publish.
    public sealed record NotWritable : TeamPublishOutcome
    {
        public static NotWritable Instance { get; } = new();
    }

    // The sign-in the team was picked under has ended.
    public sealed record SignedOut : TeamPublishOutcome
    {
        public static SignedOut Instance { get; } = new();
    }
}

public static class TeamItems
{
    // The query fields /v2 keeps (tablepro-records, LIBRARY_QUERY); null for an item this build cannot read.
    public static TeamQuery? Query(string team, TeamItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.Kind != TeamItemKind.Query || Read(item.FieldsJson) is not { } fields)
        {
            return null;
        }

        return new TeamQuery(
            team,
            item.Id,
            Text(fields, "name") ?? string.Empty,
            Text(fields, "query") ?? string.Empty,
            Text(fields, "keyword"),
            Text(fields, "folder_client_id"),
            Number(fields, "sort_order"),
            item.UpdatedBy,
            item.UpdatedAt);
    }

    public static TeamFolder? Folder(string team, TeamItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.Kind != TeamItemKind.Folder || Read(item.FieldsJson) is not { } fields)
        {
            return null;
        }

        return new TeamFolder(
            team,
            item.Id,
            Text(fields, "name") ?? string.Empty,
            Text(fields, "parent_client_id"),
            Number(fields, "sort_order"),
            item.UpdatedBy,
            item.UpdatedAt);
    }

    public static TeamView View(TeamLibraryTeam team)
    {
        ArgumentNullException.ThrowIfNull(team);
        return new TeamView(
            team.TeamId,
            team.Name,
            team.Role,
            team.CanWrite,
            [.. team.Items.Select(item => Folder(team.TeamId, item)).OfType<TeamFolder>()
                .OrderBy(folder => folder.SortOrder)
                .ThenBy(folder => folder.Name, StringComparer.CurrentCultureIgnoreCase)],
            [.. team.Items.Select(item => Query(team.TeamId, item)).OfType<TeamQuery>()
                .OrderBy(query => query.SortOrder)
                .ThenBy(query => query.Name, StringComparer.CurrentCultureIgnoreCase)],
            team.Items.Count(item => item.Kind == TeamItemKind.Connection));
    }

    // The engine names a record's kind by its wire name.
    public static string WireKind(TeamItemKind kind) => kind switch
    {
        TeamItemKind.Connection => "library_connection",
        TeamItemKind.Folder => "library_folder",
        _ => "library_query",
    };

    // The record a conflict and a writer share, case aside, as the team stores ids byte for byte and matches without case.
    public static string WriterKey(string scope, string kind, string id) =>
        scope + "\n" + kind + "\n" + id.ToLowerInvariant();

    // Every saved query and folder this computer holds, as a publish sends them: ids in upper-case UUID text.
    public static (IReadOnlyList<TeamFolderEdit> Folders, IReadOnlyList<TeamQueryEdit> Queries) Edits(
        SavedQueryContents contents)
    {
        ArgumentNullException.ThrowIfNull(contents);
        return (
            [.. contents.Folders.Select(folder => new TeamFolderEdit(
                Id(folder.Id),
                folder.Name,
                folder.ParentId is { } parent ? Id(parent) : null,
                folder.Order))],
            [.. contents.Queries.Select(query => new TeamQueryEdit(
                Id(query.Id),
                query.Name,
                query.Sql,
                string.IsNullOrEmpty(query.Keyword) ? null : query.Keyword,
                query.FolderId is { } folder ? Id(folder) : null,
                query.ConnectionId is { } connection ? Id(connection) : null,
                query.Order))]);
    }

    private static string Id(Guid id) => id.ToString().ToUpperInvariant();

    private static JsonElement? Read(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            return document.RootElement.ValueKind == JsonValueKind.Object ? document.RootElement.Clone() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement fields, string key) =>
        fields.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    private static long Number(JsonElement fields, string key) =>
        fields.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number)
            ? number
            : 0;
}

// Team Library on the core engine (core ADR 0054) for the sign-in in front: the teams and their saved queries, the
// edits the teams have not taken yet, and what both sides changed. Nothing of a sign-in shows once it ends, and a
// publish is bound to the sign-in shown when its team was picked. Everything runs on the UI thread.
public sealed class TeamLibraryModel
{
    private static readonly HashSet<string> Retryable = new(StringComparer.Ordinal)
    {
        "sync.network",
        "sync.server",
        "sync.rate_limited",
        "sync.restore_check_unavailable",
        "sync.idempotency_in_progress",
        "sync.use_dpop_nonce",
    };

    private readonly Func<Task<ITeamCalls>> _calls;
    private readonly Func<string?> _session;
    private string? _shown;
    // The owner of what shows, read with it under the sign-in shown.
    private TeamLibraryOwner? _owner;
    // Each read and each change of sign-in takes the next, so an answer begun under an older one changes nothing.
    private int _generation;
    // Each change of sign-in takes the next, so a choice still out when it ends changes nothing after.
    private int _epoch;

    public TeamLibraryModel(Func<Task<ITeamCalls>> calls, Func<string?> session)
    {
        ArgumentNullException.ThrowIfNull(calls);
        ArgumentNullException.ThrowIfNull(session);
        _calls = calls;
        _session = session;
        _shown = session();
    }

    public event EventHandler? Changed;

    // An engine with no sign-in names no owner, so nothing of Team Library is read or written through it.
    public static CoreError NoOwner { get; } =
        new("sync.signed_out", ["sync.signed_out"], "the engine names no Team Library owner", null, null);

    public IReadOnlyList<TeamView> Teams { get; private set; } = [];

    public IReadOnlyList<TeamScopeStatus> Statuses { get; private set; } = [];

    // Edits the teams have not taken yet: pending, in conflict, refused or waiting for a first pull.
    public IReadOnlyList<UnsentTeamEdit> Unsent { get; private set; } = [];

    public IReadOnlyList<TeamConflict> Conflicts { get; private set; } = [];

    public CoreError? LoadFailure { get; private set; }

    // The conflict a choice did not settle, and why.
    public (SyncRecord Record, CoreError Error)? ConflictFailure { get; private set; }

    public SyncRecord? Resolving { get; private set; }

    public bool IsPublishing { get; private set; }

    public IReadOnlyList<TeamView> WritableTeams => [.. Teams.Where(team => team.CanWrite)];

    public string? TeamName(string teamId) => Teams.FirstOrDefault(team => team.TeamId == teamId)?.Name;

    // Taken when the person picks the team, before any confirmation waits.
    public TeamDestination Destination(string teamId) => new(teamId, _shown, _owner);

    // Who last changed the team's copy of a record a conflict names.
    public string? Writer(SyncRecord record)
    {
        ArgumentNullException.ThrowIfNull(record);
        var key = TeamItems.WriterKey(record.Scope, record.Kind, record.RecordId);
        foreach (var team in Teams)
        {
            foreach (var query in team.Queries)
            {
                if (TeamItems.WriterKey(team.TeamId, TeamItems.WireKind(TeamItemKind.Query), query.Id) == key)
                {
                    return query.UpdatedBy;
                }
            }

            foreach (var folder in team.Folders)
            {
                if (TeamItems.WriterKey(team.TeamId, TeamItems.WireKind(TeamItemKind.Folder), folder.Id) == key)
                {
                    return folder.UpdatedBy;
                }
            }
        }

        return null;
    }

    // A failed read keeps what shows. Another sign-in clears it all first.
    public async Task RefreshAsync()
    {
        FollowSignIn();
        if (_shown is null)
        {
            return;
        }

        var generation = ++_generation;
        try
        {
            var calls = await _calls().ConfigureAwait(true);
            var owner = calls.Owner ?? throw new TableProException(NoOwner);
            var teams = await calls.GetTeamLibraryAsync(owner).ConfigureAwait(true);
            var statuses = await calls.GetTeamScopeStatusAsync(owner).ConfigureAwait(true);
            var unsent = await calls.GetUnsentTeamEditsAsync(owner).ConfigureAwait(true);
            var conflicts = await calls.GetConflictsAsync().ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }

            _owner = owner;
            Teams = [.. teams.Select(TeamItems.View)];
            Statuses = statuses;
            Unsent = unsent;
            Conflicts = conflicts;
            LoadFailure = null;
            if (ConflictFailure is { } failure && !conflicts.Any(conflict => conflict.Record == failure.Record))
            {
                ConflictFailure = null;
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (generation == _generation)
            {
                LoadFailure = error;
            }
        }

        if (generation == _generation)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    // Every saved query and folder this computer holds: the core removes what this computer published and no longer
    // holds.
    public Task<TeamPublishOutcome> PublishSavedQueriesAsync(
        TeamDestination destination,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries) =>
        PublishAsync(destination, (calls, owner) =>
            calls.PublishTeamSavedQueriesAsync(owner, destination.TeamId, folders, queries));

    public Task<TeamPublishOutcome> RemoveAsync(TeamDestination destination, IReadOnlyList<TeamItemRef> items) =>
        PublishAsync(destination, (calls, owner) => calls.RemoveTeamItemsAsync(owner, destination.TeamId, items));

    // Null discards every team's edits, refused and imported ones included. Null when it ran; else why not.
    public async Task<CoreError?> DiscardAsync(string? teamId)
    {
        if (_owner is not { } owner)
        {
            return NoOwner;
        }

        try
        {
            await (await _calls().ConfigureAwait(true)).DiscardTeamEditsAsync(owner, teamId).ConfigureAwait(true);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            return error;
        }

        await RefreshAsync().ConfigureAwait(true);
        return null;
    }

    // The choice carries the digest of the conflict shown: one a pull has replaced since is refused and the
    // replacement shown instead, so a choice never keeps a version the person did not see.
    public async Task ResolveAsync(TeamConflict conflict, ConflictChoice keep)
    {
        ArgumentNullException.ThrowIfNull(conflict);
        if (Resolving is not null)
        {
            return;
        }

        var epoch = _epoch;
        Resolving = conflict.Record;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var calls = await _calls().ConfigureAwait(true);
            if (epoch != _epoch)
            {
                return;
            }

            await calls.ResolveConflictAsync(conflict, keep).ConfigureAwait(true);
            if (ConflictFailure?.Record == conflict.Record)
            {
                ConflictFailure = null;
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            // Settled before the choice reached it: nothing to say.
            if (epoch == _epoch && error.Code != "sync.unknown")
            {
                ConflictFailure = (conflict.Record, error);
            }
        }
        finally
        {
            Resolving = null;
        }

        if (epoch == _epoch)
        {
            await RefreshAsync().ConfigureAwait(true);
        }
    }

    // The sign-in ended or changed: nothing of the earlier one shows from here on.
    public void FollowSignIn()
    {
        var session = _session();
        if (session == _shown)
        {
            return;
        }

        _shown = session;
        _owner = null;
        _generation++;
        _epoch++;
        Teams = [];
        Statuses = [];
        Unsent = [];
        Conflicts = [];
        LoadFailure = null;
        ConflictFailure = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public static string Name(UnsentTeamEdit edit)
    {
        ArgumentNullException.ThrowIfNull(edit);
        return string.IsNullOrEmpty(edit.Name) ? edit.Item.Id : edit.Name;
    }

    public static TeamPublishOutcome Outcome(TeamPublish publish)
    {
        ArgumentNullException.ThrowIfNull(publish);
        if (publish.Conflicts > 0)
        {
            return new TeamPublishOutcome.Conflicts(publish.Conflicts);
        }

        if (publish.Unsent > 0)
        {
            return publish.Problem is null || Retryable.Contains(publish.Problem)
                ? new TeamPublishOutcome.Queued(publish.Problem)
                : new TeamPublishOutcome.Failed(publish.Problem);
        }

        return publish.Edits == 0
            ? TeamPublishOutcome.Unchanged.Instance
            : new TeamPublishOutcome.Published(publish.Edits);
    }

    private async Task<TeamPublishOutcome> PublishAsync(
        TeamDestination destination,
        Func<ITeamCalls, TeamLibraryOwner, Task<TeamPublish>> call)
    {
        ArgumentNullException.ThrowIfNull(destination);
        if (destination.Session is null || destination.Session != _shown || _session() != destination.Session
            || destination.Owner is not { } owner)
        {
            return TeamPublishOutcome.SignedOut.Instance;
        }

        // The roles come from the engine's first read of the teams, which may not have answered yet.
        if (!Teams.Any(team => team.TeamId == destination.TeamId && team.CanWrite))
        {
            await RefreshAsync().ConfigureAwait(true);
            if (_shown != destination.Session)
            {
                return TeamPublishOutcome.SignedOut.Instance;
            }
        }

        if (!Teams.Any(team => team.TeamId == destination.TeamId && team.CanWrite))
        {
            return TeamPublishOutcome.NotWritable.Instance;
        }

        IsPublishing = true;
        Changed?.Invoke(this, EventArgs.Empty);
        TeamPublishOutcome outcome;
        try
        {
            var calls = await _calls().ConfigureAwait(true);
            outcome = _session() != destination.Session
                ? TeamPublishOutcome.SignedOut.Instance
                : Outcome(await call(calls, owner).ConfigureAwait(true));
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            outcome = error.Code switch
            {
                "sync.team_library.not_writable" => TeamPublishOutcome.NotWritable.Instance,
                // Another account's engine took the call, or the sign-in changed under it.
                "sync.team_library.other_owner" or "sync.team_library.signed_in_changed" or "sync.changed" =>
                    TeamPublishOutcome.SignedOut.Instance,
                _ => new TeamPublishOutcome.Failed(error.Code),
            };
        }
        finally
        {
            IsPublishing = false;
        }

        await RefreshAsync().ConfigureAwait(true);
        return outcome;
    }
}

public enum TeamSignOutAnswer
{
    Upload,
    Discard,
    Cancel,
}

// Sign out's part for Team Library (the macOS app's TeamLibrary.signOut): edits the teams have not taken are listed
// first, to upload, discard or keep the sign-in for; once signed out, the account's Team Library data goes, verified.
public static class TeamSignOut
{
    // False when the person keeps the sign-in. Ask gets the edits by name and the code of an upload that did not finish.
    // Owner is the one read before the sign-out started, so nothing reaches another account's library.
    public static async Task<bool> SettleUnsentAsync(
        ITeamCalls calls,
        TeamLibraryOwner owner,
        Func<IReadOnlyList<string>, string?, Task<TeamSignOutAnswer>> ask)
    {
        ArgumentNullException.ThrowIfNull(calls);
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(ask);
        string? failure = null;
        while (true)
        {
            IReadOnlyList<UnsentTeamEdit> unsent;
            try
            {
                unsent = await calls.GetUnsentTeamEditsAsync(owner).ConfigureAwait(true);
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is not null)
            {
                // Nothing could be read, so nothing is known to be lost; the sign-out deletes what stays.
                return true;
            }

            if (unsent.Count == 0)
            {
                return true;
            }

            switch (await ask([.. unsent.Select(TeamLibraryModel.Name)], failure).ConfigureAwait(true))
            {
                case TeamSignOutAnswer.Upload:
                    try
                    {
                        await calls.SyncNowAsync().ConfigureAwait(true);
                        failure = null;
                    }
                    catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
                    {
                        failure = error.Code;
                    }

                    // An upload that left edits behind asks again, with why.
                    failure ??= "sync.team_library.not_pulled";
                    break;
                case TeamSignOutAnswer.Discard:
                    try
                    {
                        await calls.DiscardTeamEditsAsync(owner, null).ConfigureAwait(true);
                    }
                    catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
                    {
                        failure = error.Code;
                        break;
                    }

                    return true;
                default:
                    return false;
            }
        }
    }

    // After the sign-out: null when the data is gone; else why it stays, which keeps Team Library off for the account.
    public static async Task<CoreError?> DeleteDataAsync(ITeamCalls calls, TeamLibraryOwner owner)
    {
        ArgumentNullException.ThrowIfNull(calls);
        ArgumentNullException.ThrowIfNull(owner);
        try
        {
            await calls.DeleteTeamLibraryDataAsync(owner).ConfigureAwait(true);
            return null;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            return error;
        }
    }
}

public enum TeamConflictCase
{
    // This computer deleted the item and the team changed it.
    ChangedAfterYouDeleted,

    // The team deleted the item and this computer changed it.
    DeletedFromTeam,

    // Both changed the same fields.
    BothChanged,
}

// A conflict's two sides as the sheet shows them; each side is the record's fields as JSON, null for a deletion.
public static class TeamConflicts
{
    public static TeamConflictCase Case(TeamConflict conflict)
    {
        ArgumentNullException.ThrowIfNull(conflict);
        return conflict.Mine is null
            ? TeamConflictCase.ChangedAfterYouDeleted
            : conflict.Theirs is null ? TeamConflictCase.DeletedFromTeam : TeamConflictCase.BothChanged;
    }

    public static string? Name(TeamConflict conflict)
    {
        ArgumentNullException.ThrowIfNull(conflict);
        return Value(conflict.Mine, "name") ?? Value(conflict.Theirs, "name");
    }

    // One field's value as text: a string as it is, a number or a boolean as JSON writes it, an object or a list as its
    // JSON; null where the side holds none.
    public static string? Value(string? json, string field)
    {
        ArgumentNullException.ThrowIfNull(field);
        if (json is null)
        {
            return null;
        }

        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !document.RootElement.TryGetProperty(field, out var value))
            {
                return null;
            }

            return value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Null or JsonValueKind.Undefined => null,
                _ => value.GetRawText(),
            };
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
