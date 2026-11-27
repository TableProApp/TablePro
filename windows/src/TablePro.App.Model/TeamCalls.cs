using TablePro.Interop;

namespace TablePro.App.Model;

// The core's Team Library and team key calls as the team models make them, so each model is tested without the core.
public interface ITeamCalls
{
    Task<IReadOnlyList<TeamLibraryTeam>> GetTeamLibraryAsync();

    Task<IReadOnlyList<TeamScopeStatus>> GetTeamScopeStatusAsync();

    Task<TeamPublish> PublishTeamSavedQueriesAsync(
        string teamId,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries);

    Task<TeamPublish> RemoveTeamItemsAsync(string teamId, IReadOnlyList<TeamItemRef> items);

    Task<IReadOnlyList<UnsentTeamEdit>> GetUnsentTeamEditsAsync();

    Task DiscardTeamEditsAsync(string? teamId);

    Task DeleteTeamLibraryDataAsync();

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
