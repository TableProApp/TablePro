using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

public enum TeamRole
{
    Owner,
    Admin,
    Editor,
    Member,
}

public enum TeamItemKind
{
    Connection,
    Folder,
    Query,
}

// The id the team stores, byte for byte; the core matches it without case.
public sealed record TeamItemRef(TeamItemKind Kind, string Id);

// FieldsJson is a folder's and a query's JSON object as /v2 keeps them; a connection comes as the core's record instead.
// UpdatedBy is who last changed it as the server names them to this account, null until a pull names anyone.
public sealed record TeamItem(
    TeamItemKind Kind,
    string Id,
    string FieldsJson,
    string? UpdatedBy,
    DateTimeOffset? UpdatedAt,
    SavedConnection? Connection = null);

// Who Team Library belongs to on this sign-in: the API's origin and the account. Every Team Library call names the
// owner it means, so a call started for one account is refused on the next one's engine.
public sealed record TeamLibraryOwner(string ApiOrigin, string AccountId);

// Role is null until the first scopes answer this run; a team's name comes from the profile.
public sealed record TeamLibraryTeam(
    string TeamId,
    string? Name,
    TeamRole? Role,
    bool CanWrite,
    IReadOnlyList<TeamItem> Items);

public sealed record TeamFolderEdit(string Id, string Name, string? ParentId, long SortOrder);

public sealed record TeamQueryEdit(
    string Id,
    string Name,
    string Query,
    string? Keyword,
    string? FolderId,
    string? ConnectionId,
    long SortOrder);

// After the pass a publish starts: Edits 0 when the team already held everything as sent. Conflicts wait for Keep mine
// or Keep theirs; Unsent stay on this device, with the pass's error code.
public sealed record TeamPublish(int Edits, int Conflicts, int Unsent, string? Problem);

public enum UnsentTeamEditState
{
    Pending,
    Conflict,

    // Refused by the server with Code, until it is discarded or a later publish of the item is taken.
    Refused,

    // An imported edit waiting for the team's first pull.
    Waiting,
}

public sealed record UnsentTeamEdit(
    string TeamId,
    TeamItemRef Item,
    string? Name,
    bool Deletion,
    UnsentTeamEditState State,
    string? Code);

// Past grace or after a lapse a team pulls only and its edits wait.
public sealed record TeamScopeStatus(
    string TeamId,
    DateTimeOffset? LastSynced,
    bool PullOnly,
    bool WriteForbidden,
    string? Problem);

// A synced record by its scope as the wire names it (personal, history or team_...), its kind and its id.
public sealed record SyncRecord(string Scope, string Kind, string RecordId);

// What both sides changed in one team record: values are JSON text, null for a deletion. Digest goes back with the
// choice, so a conflict a pull replaced since is not decided.
public sealed record TeamConflict(
    SyncRecord Record,
    IReadOnlyList<string> Fields,
    string? Mine,
    string? Theirs,
    string Digest);

public enum ConflictChoice
{
    KeepMine,
    KeepTheirs,
}

public enum TeamKeyState
{
    Ok,
    Stopped,
    Ended,
}

public enum MemberKeyStatus
{
    NoKeys,
    AwaitingConfirmation,
    Holder,
    Alert,
}

public sealed record MemberKeys(
    string Account,
    string? Name,
    string? Email,
    bool IsSelf,
    TeamRole Role,
    MemberKeyStatus Status);

// A device a team stopped on, which an owner or admin confirms again by rotating when CanReconfirm.
public sealed record StoppedDevice(
    string Account,
    string? Name,
    string? Email,
    bool IsSelf,
    string Device,
    long Version,
    bool CanReconfirm);

public sealed record TeamKeys(
    string Team,
    string? TeamName,
    long? Version,
    TeamKeyState State,
    StopCause? StoppedCause,
    bool RotationDue,
    bool Holder,
    IReadOnlyList<MemberKeys> Members,
    IReadOnlyList<StoppedDevice> Stopped);

// A team restart this device holds until the person compares the restarting owner's words (core ADR 0064).
public sealed record HeldRestart(string Team, long Version, string Signer, string SignerIdentityKey, KeyFingerprint Words);

// Team Library and the team keys (core ADRs 0054 and 0056). A team is its scope name, team_..., the id the profile's
// teams carry; every call reaches TablePro Sync's engine, which runs the team scopes whatever the personal provider.
public sealed partial class TableProSync
{
    // Null while the service holds no engine. Each Team Library call below takes it back and is refused with
    // sync.team_library.other_owner on another account's engine.
    public TeamLibraryOwner? GetTeamLibraryOwner() =>
        _service.TeamLibraryOwner() is { } owner ? new TeamLibraryOwner(owner.ApiOrigin, owner.AccountId) : null;

    // Names come from the profile in the background, so this never waits on the network.
    public async Task<IReadOnlyList<TeamLibraryTeam>> GetTeamLibraryAsync(TeamLibraryOwner owner)
    {
        var expected = Owner(owner);
        return [.. (await CoreCall.RunAsync(() => _service.TeamLibrary(expected)).ConfigureAwait(false)).Select(Mapping.Team)];
    }

    public async Task<IReadOnlyList<TeamScopeStatus>> GetTeamScopeStatusAsync(TeamLibraryOwner owner)
    {
        var expected = Owner(owner);
        return
        [
            .. (await CoreCall.RunAsync(() => _service.TeamScopeStatus(expected)).ConfigureAwait(false))
                .Select(Mapping.TeamStatus),
        ];
    }

    // Every saved query and folder this device holds: the core removes what it published before and no longer holds.
    public async Task<TeamPublish> PublishTeamSavedQueriesAsync(
        TeamLibraryOwner owner,
        string teamId,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries)
    {
        var expected = Owner(owner);
        ArgumentException.ThrowIfNullOrEmpty(teamId);
        ArgumentNullException.ThrowIfNull(folders);
        ArgumentNullException.ThrowIfNull(queries);
        Native.TeamFolderArg[] folderArgs =
            [.. folders.Select(folder => new Native.TeamFolderArg(folder.Id, folder.Name, folder.ParentId, folder.SortOrder))];
        Native.TeamQueryArg[] queryArgs =
        [
            .. queries.Select(query => new Native.TeamQueryArg(
                query.Id,
                query.Name,
                query.Query,
                query.Keyword,
                query.FolderId,
                query.ConnectionId,
                query.SortOrder)),
        ];
        return Mapping.Publish(await CoreCall.RunAsync(
            () => _service.PublishTeamSavedQueries(expected, teamId, folderArgs, queryArgs)).ConfigureAwait(false));
    }

    public async Task<TeamPublish> RemoveTeamItemsAsync(TeamLibraryOwner owner, string teamId, IReadOnlyList<TeamItemRef> items)
    {
        var expected = Owner(owner);
        ArgumentException.ThrowIfNullOrEmpty(teamId);
        ArgumentNullException.ThrowIfNull(items);
        Native.TeamLibraryItemRef[] refs = [.. items.Select(Mapping.ItemRef)];
        return Mapping.Publish(await CoreCall.RunAsync(() => _service.RemoveTeamItems(expected, teamId, refs))
            .ConfigureAwait(false));
    }

    public async Task<IReadOnlyList<UnsentTeamEdit>> GetUnsentTeamEditsAsync(TeamLibraryOwner owner)
    {
        var expected = Owner(owner);
        return [.. (await CoreCall.RunAsync(() => _service.UnsentTeamEdits(expected)).ConfigureAwait(false)).Select(Mapping.Unsent)];
    }

    // A null team discards every team's, refused and imported edits included.
    public Task DiscardTeamEditsAsync(TeamLibraryOwner owner, string? teamId)
    {
        var expected = Owner(owner);
        return CoreCall.RunAsync(() => _service.DiscardTeamEdits(expected, teamId));
    }

    // After the sign-in ended too, as Sign Out deletes once it has signed out. On failure Team Library stays off for
    // this account until a later delete succeeds.
    public Task DeleteTeamLibraryDataAsync(TeamLibraryOwner owner)
    {
        var expected = Owner(owner);
        return CoreCall.RunAsync(() => _service.DeleteTeamLibraryData(expected));
    }

    public async Task<IReadOnlyList<TeamConflict>> GetConflictsAsync() =>
        [.. (await CoreCall.RunAsync(() => _service.Conflicts()).ConfigureAwait(false)).Select(Mapping.Conflict)];

    // Digest is the conflict's as listed; a pull that replaced it since answers sync.changed.
    public Task ResolveConflictAsync(TeamConflict conflict, ConflictChoice keep)
    {
        ArgumentNullException.ThrowIfNull(conflict);
        var record = Mapping.Record(conflict.Record);
        var choice = keep == ConflictChoice.KeepMine ? Native.ConflictChoiceTag.KeepMine : Native.ConflictChoiceTag.KeepTheirs;
        return CoreCall.RunAsync(() => _service.ResolveConflict(record, conflict.Digest, choice));
    }

    public async Task<TeamKeys> GetTeamKeysAsync(string team)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        return Mapping.Keys(await CoreCall.RunAsync(() => _service.TeamKeys(team)).ConfigureAwait(false));
    }

    public Task CreateTeamKeysAsync(string team)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        return CoreCall.RunAsync(() => _service.CreateTeamKeys(team));
    }

    public Task ConfirmMemberAsync(string team, string account)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        ArgumentException.ThrowIfNullOrEmpty(account);
        return CoreCall.RunAsync(() => _service.ConfirmMember(team, account));
    }

    // Remove names the accounts the new team key leaves out.
    public Task RotateTeamKeyAsync(string team, IReadOnlyList<string> remove)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        ArgumentNullException.ThrowIfNull(remove);
        var accounts = remove.ToArray();
        return CoreCall.RunAsync(() => _service.RotateTeamKey(team, accounts));
    }

    // Confirm names the accounts the restarted team key goes to.
    public Task RestartTeamKeyAsync(string team, IReadOnlyList<string> confirm)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        ArgumentNullException.ThrowIfNull(confirm);
        var accounts = confirm.ToArray();
        return CoreCall.RunAsync(() => _service.RestartTeamKey(team, accounts));
    }

    public async Task<HeldRestart?> GetHeldTeamRestartAsync(string team)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        var held = await CoreCall.RunAsync(() => _service.HeldTeamRestart(team)).ConfigureAwait(false);
        return held is null
            ? null
            : new HeldRestart(held.Team, held.Version, held.Signer, held.SignerIk, Mapping.Fingerprint(held.Words));
    }

    // SignerIdentityKey is the one GetHeldTeamRestartAsync showed; there is no accept without comparing.
    public Task AcceptTeamRestartAsync(string team, string signerIdentityKey)
    {
        ArgumentException.ThrowIfNullOrEmpty(team);
        ArgumentException.ThrowIfNullOrEmpty(signerIdentityKey);
        return CoreCall.RunAsync(() => _service.AcceptTeamRestart(team, signerIdentityKey));
    }

    // This account's words, which a teammate compares when confirming it.
    public async Task<KeyFingerprint> GetOwnFingerprintAsync() =>
        Mapping.Fingerprint(await CoreCall.RunAsync(() => _service.OwnFingerprint()).ConfigureAwait(false));

    public async Task<KeyFingerprint> GetAccountFingerprintAsync(string account)
    {
        ArgumentException.ThrowIfNullOrEmpty(account);
        return Mapping.Fingerprint(await CoreCall.RunAsync(() => _service.AccountFingerprint(account)).ConfigureAwait(false));
    }

    private static Native.TeamLibraryOwnerArg Owner(TeamLibraryOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        return new Native.TeamLibraryOwnerArg(owner.ApiOrigin, owner.AccountId);
    }
}
