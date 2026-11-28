using TablePro.Interop;

namespace TablePro.App.Model;

// The core's Team Library and team key calls as the team models make them, so each model is tested without the core.
public interface ITeamCalls
{
    // The owner the engine's sign-in binds Team Library to, null while there is no engine. A Team Library call takes the
    // owner the caller read under the sign-in it means, and another account's engine refuses it.
    TeamLibraryOwner? Owner { get; }

    Task<IReadOnlyList<TeamLibraryTeam>> GetTeamLibraryAsync(TeamLibraryOwner owner);

    Task<IReadOnlyList<TeamScopeStatus>> GetTeamScopeStatusAsync(TeamLibraryOwner owner);

    Task<TeamPublish> PublishTeamSavedQueriesAsync(
        TeamLibraryOwner owner,
        string teamId,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries);

    Task<TeamPublish> RemoveTeamItemsAsync(TeamLibraryOwner owner, string teamId, IReadOnlyList<TeamItemRef> items);

    Task<IReadOnlyList<UnsentTeamEdit>> GetUnsentTeamEditsAsync(TeamLibraryOwner owner);

    Task DiscardTeamEditsAsync(TeamLibraryOwner owner, string? teamId);

    Task DeleteTeamLibraryDataAsync(TeamLibraryOwner owner);

    Task<IReadOnlyList<TeamConflict>> GetConflictsAsync();

    Task ResolveConflictAsync(TeamConflict conflict, ConflictChoice keep);

    // One pass now, as Upload before a sign-out asks.
    Task SyncNowAsync();

    Task<TeamKeys> GetTeamKeysAsync(string team);

    Task CreateTeamKeysAsync(string team);

    Task ConfirmMemberAsync(string team, string account);

    Task RotateTeamKeyAsync(string team, IReadOnlyList<string> remove);

    Task RestartTeamKeyAsync(string team, IReadOnlyList<string> confirm);

    Task<HeldRestart?> GetHeldTeamRestartAsync(string team);

    Task AcceptTeamRestartAsync(string team, string signerIdentityKey);

    Task<KeyFingerprint> GetOwnFingerprintAsync();

    Task<KeyFingerprint> GetAccountFingerprintAsync(string account);

    Task<KeyChange?> GetKeyChangeAsync(string account);

    Task AcceptKeyChangeAsync(string account, string offeredIdentityKey, bool compared);

    Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync();

    Task DismissKeyNoticeAsync(string notice);
}
