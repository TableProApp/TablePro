using TablePro.App.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed class SyncEngineAdapter(TableProSync sync) : ISyncEngine
{
    public IKeyFlows Keys => new KeyFlowsAdapter(sync);

    public ITeamCalls Team => new TeamCallsAdapter(sync);

    public SyncStatus Status => sync.Status;

    public IReadOnlyList<SyncScopeStatus> Scopes => sync.Scopes;

    public string? ServiceAccount => sync.ServiceAccount;

    public IAsyncEnumerable<SyncChanges> ReadChangesAsync(CancellationToken cancellationToken) =>
        sync.ReadChangesAsync(cancellationToken);

    public Task SyncNowAsync(SyncPassReason why) => sync.SyncNowAsync(why);

    public Task SetCategoriesAsync(SyncCategories categories) => sync.SetCategoriesAsync(categories);

    public void SetHistoryWindow(int? entries) => sync.SetHistoryWindow(entries);

    public Task ChooseProviderAsync(SyncProvider provider) => sync.ChooseProviderAsync(provider);

    public Task<SyncUploadPlan> PlanUploadAsync() => sync.PlanUploadAsync();

    public Task<bool?> GetOpenUploadAsync() => sync.GetOpenUploadAsync();

    public Task<KeyState> GetKeyStateAsync() => sync.GetKeyStateAsync();

    public Task<NewIdentityPlan> PlanNewIdentityAsync() => sync.PlanNewIdentityAsync();

    public Task ChooseForNewIdentityAsync(NewIdentityChoice choice, string account) =>
        sync.ChooseForNewIdentityAsync(choice, account);

    public void Dispose() => sync.Dispose();
}

internal sealed class KeyFlowsAdapter(TableProSync sync) : IKeyFlows
{
    public Task<KeyState> GetKeyStateAsync() => sync.GetKeyStateAsync();

    public Task<RecoveryKeyDraft> BeginGenesisAsync() => sync.BeginGenesisAsync();

    public Task<GenesisOutcome> FinishGenesisAsync(string draft, IReadOnlyList<string> typed) =>
        sync.FinishGenesisAsync(draft, typed);

    public void DiscardKeyDraft(string draft) => sync.DiscardKeyDraft(draft);

    public Task<KeysSignOutOutcome> SignOutKeysAsync() => sync.SignOutKeysAsync();

    public Task<RotationDraft> BeginReplaceRecoveryKeyAsync(string recoveryKey) =>
        sync.BeginReplaceRecoveryKeyAsync(recoveryKey);

    public Task FinishReplaceRecoveryKeyAsync(string draft, IReadOnlyList<string> typed, IReadOnlyList<string> keep) =>
        sync.FinishReplaceRecoveryKeyAsync(draft, typed, keep);

    public Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync() => sync.GetKeyNoticesAsync();

    public Task DismissKeyNoticeAsync(string notice) => sync.DismissKeyNoticeAsync(notice);

    public Task<string> RequestApprovalAsync() => sync.RequestApprovalAsync();

    public Task<IReadOnlyList<ApprovalRequest>> GetApprovalRequestsAsync() => sync.GetApprovalRequestsAsync();

    public Task<ApprovalSession> ChooseApprovalRequestAsync(string request) => sync.ChooseApprovalRequestAsync(request);

    public Task<ApprovalSession> GetApprovalSessionAsync(string request) => sync.GetApprovalSessionAsync(request);

    public Task<ApprovalSession> ConfirmApprovalSessionAsync(string request) => sync.ConfirmApprovalSessionAsync(request);

    public Task ApprovalWordsDifferAsync(string request) => sync.ApprovalWordsDifferAsync(request);

    public Task CancelApprovalSessionAsync(string request) => sync.CancelApprovalSessionAsync(request);

    public Task<IReadOnlyList<KeyDevice>> GetAccountDevicesAsync() => sync.GetAccountDevicesAsync();

    public Task RemoveDeviceRowAsync(string device) => sync.RemoveDeviceRowAsync(device);

    public Task<RemovalReview> BeginDeviceRemovalAsync(string recoveryKey, IReadOnlyList<string> lost) =>
        sync.BeginDeviceRemovalAsync(recoveryKey, lost);

    public Task FinishDeviceRemovalAsync(string review, IReadOnlyList<string> keep, IReadOnlyList<ReviewedMember> remove) =>
        sync.FinishDeviceRemovalAsync(review, keep, remove);

    public Task RecoverWithRecoveryKeyAsync(string recoveryKey) => sync.RecoverWithRecoveryKeyAsync(recoveryKey);

    public Task<PendingReset?> GetPendingResetAsync() => sync.GetPendingResetAsync();

    public Task<RecoveryKeyDraft> BeginResetAsync(ResetKind kind) => sync.BeginResetAsync(kind);

    public Task<PendingReset> FinishResetProposalAsync(string draft, IReadOnlyList<string> typed) =>
        sync.FinishResetProposalAsync(draft, typed);

    public Task CancelResetAsync(string reset, string? recoveryKey) => sync.CancelResetAsync(reset, recoveryKey);

    public Task ActivateResetAsync(string reset) => sync.ActivateResetAsync(reset);

    public Task ResumeResetAsync(string reset) => sync.ResumeResetAsync(reset);
}

internal sealed class TeamCallsAdapter(TableProSync sync) : ITeamCalls
{
    public TeamLibraryOwner? Owner => sync.GetTeamLibraryOwner();

    public Task<IReadOnlyList<TeamLibraryTeam>> GetTeamLibraryAsync(TeamLibraryOwner owner) => sync.GetTeamLibraryAsync(owner);

    public Task<IReadOnlyList<TeamScopeStatus>> GetTeamScopeStatusAsync(TeamLibraryOwner owner) =>
        sync.GetTeamScopeStatusAsync(owner);

    public Task<TeamPublish> PublishTeamSavedQueriesAsync(
        TeamLibraryOwner owner,
        string teamId,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries) => sync.PublishTeamSavedQueriesAsync(owner, teamId, folders, queries);

    public Task<TeamPublish> RemoveTeamItemsAsync(TeamLibraryOwner owner, string teamId, IReadOnlyList<TeamItemRef> items) =>
        sync.RemoveTeamItemsAsync(owner, teamId, items);

    public Task<IReadOnlyList<UnsentTeamEdit>> GetUnsentTeamEditsAsync(TeamLibraryOwner owner) =>
        sync.GetUnsentTeamEditsAsync(owner);

    public Task DiscardTeamEditsAsync(TeamLibraryOwner owner, string? teamId) => sync.DiscardTeamEditsAsync(owner, teamId);

    public Task DeleteTeamLibraryDataAsync(TeamLibraryOwner owner) => sync.DeleteTeamLibraryDataAsync(owner);

    public Task<IReadOnlyList<TeamConflict>> GetConflictsAsync() => sync.GetConflictsAsync();

    public Task ResolveConflictAsync(TeamConflict conflict, ConflictChoice keep) => sync.ResolveConflictAsync(conflict, keep);

    public Task SyncNowAsync() => sync.SyncNowAsync(SyncPassReason.Person);

    public Task<TeamKeys> GetTeamKeysAsync(string team) => sync.GetTeamKeysAsync(team);

    public Task CreateTeamKeysAsync(string team) => sync.CreateTeamKeysAsync(team);

    public Task ConfirmMemberAsync(string team, string account) => sync.ConfirmMemberAsync(team, account);

    public Task RotateTeamKeyAsync(string team, IReadOnlyList<string> remove) => sync.RotateTeamKeyAsync(team, remove);

    public Task RestartTeamKeyAsync(string team, IReadOnlyList<string> confirm) => sync.RestartTeamKeyAsync(team, confirm);

    public Task<HeldRestart?> GetHeldTeamRestartAsync(string team) => sync.GetHeldTeamRestartAsync(team);

    public Task AcceptTeamRestartAsync(string team, string signerIdentityKey) =>
        sync.AcceptTeamRestartAsync(team, signerIdentityKey);

    public Task<KeyFingerprint> GetOwnFingerprintAsync() => sync.GetOwnFingerprintAsync();

    public Task<KeyFingerprint> GetAccountFingerprintAsync(string account) => sync.GetAccountFingerprintAsync(account);

    public Task<KeyChange?> GetKeyChangeAsync(string account) => sync.GetKeyChangeAsync(account);

    public Task AcceptKeyChangeAsync(string account, string offeredIdentityKey, bool compared) =>
        sync.AcceptKeyChangeAsync(account, offeredIdentityKey, compared);

    public Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync() => sync.GetKeyNoticesAsync();

    public Task DismissKeyNoticeAsync(string notice) => sync.DismissKeyNoticeAsync(notice);
}
