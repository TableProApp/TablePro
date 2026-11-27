using System.Runtime.CompilerServices;
using System.Threading.Channels;
using TablePro.Interop;

namespace TablePro.App.Model.Tests;

internal static class SyncErrors
{
    public static CoreError Of(string code) => new(code, [code], code, null, null);
}

// The core's sync service as a script: each call is noted, and each answer is set beforehand.
internal sealed class FakeSyncEngine : ISyncEngine
{
    private readonly Channel<SyncChanges> _changes = Channel.CreateUnbounded<SyncChanges>();
    private readonly Lock _gate = new();
    private readonly List<string> _calls = [];

    public SyncStatus Status { get; set; } = SyncStatus.Off;

    public IReadOnlyList<SyncScopeStatus> Scopes { get; set; } = [];

    public string? ServiceAccount { get; set; }

    public KeyState Keys { get; set; } = new KeyState.Approved(1, "D");

    public SyncUploadPlan Plan { get; set; } = new(12, 2, 3);

    public bool? OpenUpload { get; set; }

    // Another account waits for a choice while this is set; the core answers sync.not_allowed otherwise.
    public NewIdentityPlan? Choice { get; set; }

    public CoreError? ChooseFails { get; set; }

    public CoreError? PassFails { get; set; }

    public bool IsDisposed { get; private set; }

    public int? HistoryWindow { get; private set; }

    public FakeKeyFlows KeyFlows { get; } = new();

    public IKeyFlows Keys => KeyFlows;

    public FakeTeamCalls TeamCalls { get; } = new();

    public ITeamCalls Team => TeamCalls;

    public IReadOnlyList<string> Calls
    {
        get
        {
            lock (_gate)
            {
                return [.. _calls];
            }
        }
    }

    public void Raise(SyncChanges changes) => _changes.Writer.TryWrite(changes);

    public async IAsyncEnumerable<SyncChanges> ReadChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await foreach (var changes in _changes.Reader.ReadAllAsync(cancellationToken))
        {
            yield return changes;
        }
    }

    public Task SyncNowAsync(SyncPassReason why)
    {
        Note($"pass {why}");
        return PassFails is { } error ? Task.FromException(new TableProException(error)) : Task.CompletedTask;
    }

    public Task SetCategoriesAsync(SyncCategories categories)
    {
        Note($"categories {string.Join(',', categories.OffKinds)} passwords {categories.Passwords}");
        return Task.CompletedTask;
    }

    public void SetHistoryWindow(int? entries) => HistoryWindow = entries;

    public Task ChooseProviderAsync(SyncProvider provider)
    {
        Note($"choose {provider}");
        return ChooseFails is { } error ? Task.FromException(new TableProException(error)) : Task.CompletedTask;
    }

    public Task<SyncUploadPlan> PlanUploadAsync() => Task.FromResult(Plan);

    public Task<bool?> GetOpenUploadAsync() => Task.FromResult(OpenUpload);

    public Task<KeyState> GetKeyStateAsync()
    {
        ObjectDisposedException.ThrowIf(IsDisposed, this);
        return Task.FromResult(Keys);
    }

    public Task<NewIdentityPlan> PlanNewIdentityAsync() => Choice is { } plan
        ? Task.FromResult(plan)
        : Task.FromException<NewIdentityPlan>(new TableProException(SyncErrors.Of("sync.not_allowed")));

    public Task ChooseForNewIdentityAsync(NewIdentityChoice choice, string account)
    {
        Note($"new identity {choice} {account}");
        if (Choice?.Account != account)
        {
            return Task.FromException(new TableProException(SyncErrors.Of("sync.changed")));
        }

        Choice = null;
        ServiceAccount = account;
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        IsDisposed = true;
        _changes.Writer.TryComplete();
    }

    private void Note(string call)
    {
        ObjectDisposedException.ThrowIf(IsDisposed, this);
        lock (_gate)
        {
            _calls.Add(call);
        }
    }
}

internal sealed class FakeSyncApp : ISyncHostApp
{
    private readonly Lock _gate = new();
    private readonly List<FakeSyncEngine> _opened = [];
    private readonly List<SyncConfiguration> _configurations = [];
    private readonly List<string> _notes = [];

    public SyncSettings Sync { get; set; } = new();

    public int? HistoryWindow { get; set; } = 5_000;

    public string? SignIn { get; set; } = "account-1";

    public CoreError? OpenFails { get; set; }

    // Each open's engine, set up before it is handed over.
    public Action<FakeSyncEngine> Prepare { get; set; } = _ => { };

    public IReadOnlyList<FakeSyncEngine> Opened
    {
        get
        {
            lock (_gate)
            {
                return [.. _opened];
            }
        }
    }

    public IReadOnlyList<SyncConfiguration> Configurations
    {
        get
        {
            lock (_gate)
            {
                return [.. _configurations];
            }
        }
    }

    public IReadOnlyList<string> Notes
    {
        get
        {
            lock (_gate)
            {
                return [.. _notes];
            }
        }
    }

    public void UpdateSync(Func<SyncSettings, SyncSettings> change) => Sync = change(Sync);

    public Task<ISyncEngine> OpenAsync(SyncConfiguration configuration)
    {
        lock (_gate)
        {
            _configurations.Add(configuration);
        }

        if (OpenFails is { } error)
        {
            return Task.FromException<ISyncEngine>(new TableProException(error));
        }

        var engine = new FakeSyncEngine();
        Prepare(engine);
        lock (_gate)
        {
            _opened.Add(engine);
        }

        return Task.FromResult<ISyncEngine>(engine);
    }

    public void Note(string what, CoreError failure)
    {
        lock (_gate)
        {
            _notes.Add($"{what}: {failure.Code}");
        }
    }
}

// The key calls as a script: each call is noted, its answer set beforehand, and Fails makes the named call throw.
internal sealed class FakeKeyFlows : IKeyFlows
{
    private readonly Lock _gate = new();
    private readonly List<string> _calls = [];

    public KeyState State { get; set; } = new KeyState.Approved(1, "D-THIS");

    public RecoveryKeyDraft Draft { get; set; } = new("DRAFT", Key, [2, 9]);

    public GenesisOutcome Genesis { get; set; } = GenesisOutcome.Created;

    public IReadOnlyList<ReviewedDevice> Reviewed { get; set; } = [];

    public IReadOnlyList<ReviewedMember> Members { get; set; } = [];

    public IReadOnlyList<KeyDevice> Devices { get; set; } = [];

    public IReadOnlyList<ApprovalRequest> Requests { get; set; } = [];

    public IReadOnlyList<KeyNotice> Notices { get; set; } = [];

    public PendingReset? Reset { get; set; }

    // Each session read answers the next of these, then the last again.
    public Queue<ApprovalSession> Sessions { get; } = new();

    // The call that throws, by name, with the error it throws, as often as Times says.
    public Dictionary<string, CoreError> Fails { get; } = new(StringComparer.Ordinal);

    public int StepUpsAsked { get; set; }

    public const string Key = "AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH-JJJJ-KKKK-MMMM-NNNN-PPPP-QQQQ";

    public IReadOnlyList<string> Calls
    {
        get
        {
            lock (_gate)
            {
                return [.. _calls];
            }
        }
    }

    public Task<KeyState> GetKeyStateAsync() => Answer("key state", State);

    public Task<RecoveryKeyDraft> BeginGenesisAsync() => Answer("begin genesis", Draft);

    public Task<GenesisOutcome> FinishGenesisAsync(string draft, IReadOnlyList<string> typed) =>
        Answer($"finish genesis {draft} {string.Join(',', typed)}", Genesis);

    public void DiscardKeyDraft(string draft) => Note($"discard {draft}");

    public Task<KeysSignOutOutcome> SignOutKeysAsync() => Answer("sign out keys", KeysSignOutOutcome.Revoked);

    public Task<RotationDraft> BeginReplaceRecoveryKeyAsync(string recoveryKey) =>
        Answer($"begin replace {recoveryKey}", new RotationDraft(Draft, Reviewed));

    public Task FinishReplaceRecoveryKeyAsync(string draft, IReadOnlyList<string> typed, IReadOnlyList<string> keep) =>
        Answer($"finish replace {draft} {string.Join(',', typed)} keep {string.Join(',', keep)}", true);

    public Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync() => Answer("notices", Notices);

    public Task DismissKeyNoticeAsync(string notice) => Answer($"dismiss {notice}", true);

    public Task<string> RequestApprovalAsync() => Answer("request approval", "REQ-NEW");

    public Task<IReadOnlyList<ApprovalRequest>> GetApprovalRequestsAsync() => Answer("requests", Requests);

    public Task<ApprovalSession> ChooseApprovalRequestAsync(string request) =>
        Answer($"choose {request}", NextSession());

    public Task<ApprovalSession> GetApprovalSessionAsync(string request) =>
        Answer($"session {request}", NextSession());

    public Task<ApprovalSession> ConfirmApprovalSessionAsync(string request) =>
        Answer($"confirm {request}", NextSession());

    public Task ApprovalWordsDifferAsync(string request) => Answer($"differ {request}", true);

    public Task CancelApprovalSessionAsync(string request) => Answer($"cancel {request}", true);

    public Task<IReadOnlyList<KeyDevice>> GetAccountDevicesAsync() => Answer("devices", Devices);

    public Task RemoveDeviceRowAsync(string device) => Answer($"remove row {device}", true);

    public Task<RemovalReview> BeginDeviceRemovalAsync(string recoveryKey, IReadOnlyList<string> lost) =>
        Answer($"begin removal {recoveryKey} {string.Join(',', lost)}", new RemovalReview("REVIEW", Reviewed, Members));

    public Task FinishDeviceRemovalAsync(string review, IReadOnlyList<string> keep, IReadOnlyList<ReviewedMember> remove) =>
        Answer(
            $"finish removal {review} keep {string.Join(',', keep)} remove {string.Join(',', remove.Select(member => member.Account))}",
            true);

    public Task RecoverWithRecoveryKeyAsync(string recoveryKey) => Answer($"recover {recoveryKey}", true);

    public Task<PendingReset?> GetPendingResetAsync() => Answer("pending reset", Reset);

    public Task<RecoveryKeyDraft> BeginResetAsync(ResetKind kind) => Answer($"begin reset {kind}", Draft);

    public Task<PendingReset> FinishResetProposalAsync(string draft, IReadOnlyList<string> typed) =>
        Answer($"finish reset {draft} {string.Join(',', typed)}", Reset ?? Pending("RESET", mine: true));

    public Task CancelResetAsync(string reset, string? recoveryKey) =>
        Answer($"cancel reset {reset} {recoveryKey ?? "this device"}", true);

    public Task ActivateResetAsync(string reset) => Answer($"activate {reset}", true);

    public Task ResumeResetAsync(string reset) => Answer($"resume {reset}", true);

    public static PendingReset Pending(string reset, bool mine, DateTimeOffset? heldUntil = null) => new(
        reset,
        ResetKind.KeepScopeKeys,
        ResetState.Pending,
        mine,
        mine ? null : "Mac mini",
        DateTimeOffset.UnixEpoch,
        heldUntil ?? DateTimeOffset.UnixEpoch.AddDays(7));

    private ApprovalSession NextSession()
    {
        lock (_gate)
        {
            return Sessions.Count > 1 ? Sessions.Dequeue() : Sessions.Peek();
        }
    }

    private Task<T> Answer<T>(string call, T value)
    {
        Note(call);
        var name = call.Split(' ')[0] + (call.Contains(' ', StringComparison.Ordinal) ? " " + call.Split(' ')[1] : string.Empty);
        lock (_gate)
        {
            if (Fails.Remove(name, out var error) || Fails.Remove(call.Split(' ')[0], out error))
            {
                return Task.FromException<T>(new TableProException(error));
            }
        }

        return Task.FromResult(value);
    }

    private void Note(string call)
    {
        lock (_gate)
        {
            _calls.Add(call);
        }
    }
}

// The team calls as a script, as FakeKeyFlows is: each call noted, its answer set beforehand, Fails throwing once.
internal sealed class FakeTeamCalls : ITeamCalls
{
    private readonly Lock _gate = new();
    private readonly List<string> _calls = [];

    public IReadOnlyList<TeamLibraryTeam> Teams { get; set; } = [];

    public IReadOnlyList<TeamScopeStatus> Statuses { get; set; } = [];

    public List<UnsentTeamEdit> Unsent { get; } = [];

    public List<TeamConflict> Conflicts { get; } = [];

    public TeamPublish Publish { get; set; } = new(2, 0, 0, null);

    public TeamKeys? Keys { get; set; }

    public IReadOnlyList<KeyNotice> Notices { get; set; } = [];

    // An upload clears the unsent edits only while this holds.
    public bool UploadSends { get; set; } = true;

    public Dictionary<string, CoreError> Fails { get; } = new(StringComparer.Ordinal);

    public IReadOnlyList<string> Calls
    {
        get
        {
            lock (_gate)
            {
                return [.. _calls];
            }
        }
    }

    public Task<IReadOnlyList<TeamLibraryTeam>> GetTeamLibraryAsync() => Answer("teams", Teams);

    public Task<IReadOnlyList<TeamScopeStatus>> GetTeamScopeStatusAsync() => Answer("statuses", Statuses);

    public Task<TeamPublish> PublishTeamSavedQueriesAsync(
        string teamId,
        IReadOnlyList<TeamFolderEdit> folders,
        IReadOnlyList<TeamQueryEdit> queries) =>
        Answer($"publish {teamId} {folders.Count} folders {queries.Count} queries", Publish);

    public Task<TeamPublish> RemoveTeamItemsAsync(string teamId, IReadOnlyList<TeamItemRef> items) =>
        Answer($"remove {teamId} {string.Join(',', items.Select(item => item.Id))}", Publish);

    public Task<IReadOnlyList<UnsentTeamEdit>> GetUnsentTeamEditsAsync() =>
        Answer<IReadOnlyList<UnsentTeamEdit>>("unsent", [.. Unsent]);

    public Task DiscardTeamEditsAsync(string? teamId)
    {
        Unsent.Clear();
        return Answer($"discard {teamId ?? "all"}", true);
    }

    public Task DeleteTeamLibraryDataAsync() => Answer("delete data", true);

    public Task<IReadOnlyList<TeamConflict>> GetConflictsAsync() =>
        Answer<IReadOnlyList<TeamConflict>>("conflicts", [.. Conflicts]);

    public Task ResolveConflictAsync(TeamConflict conflict, ConflictChoice keep)
    {
        var answer = Answer($"resolve {conflict.Record.RecordId} {keep}", true);
        if (answer.IsCompletedSuccessfully)
        {
            Conflicts.RemoveAll(each => each.Record == conflict.Record);
        }

        return answer;
    }

    public Task SyncNowAsync()
    {
        var answer = Answer("sync now", true);
        if (answer.IsCompletedSuccessfully && UploadSends)
        {
            Unsent.Clear();
        }

        return answer;
    }

    public Task<TeamKeys> GetTeamKeysAsync(string team) =>
        Answer($"team keys {team}", Keys ?? throw new InvalidOperationException("no keys scripted"));

    public Task CreateTeamKeysAsync(string team) => Answer($"create {team}", true);

    public Task ConfirmMemberAsync(string team, string account) => Answer($"confirm {team} {account}", true);

    public Task RotateTeamKeyAsync(string team, IReadOnlyList<string> remove) =>
        Answer($"rotate {team} {string.Join(',', remove)}", true);

    public Task RestartTeamKeyAsync(string team, IReadOnlyList<string> confirm) =>
        Answer($"restart {team} {string.Join(',', confirm)}", true);

    public Task<HeldRestart?> GetHeldTeamRestartAsync(string team) => Answer<HeldRestart?>($"held {team}", null);

    public Task AcceptTeamRestartAsync(string team, string signerIdentityKey) =>
        Answer($"accept restart {team} {signerIdentityKey}", true);

    public Task<KeyFingerprint> GetOwnFingerprintAsync() =>
        Answer("own words", new KeyFingerprint(["a", "b", "c", "d", "e"], "qr"));

    public Task<KeyFingerprint> GetAccountFingerprintAsync(string account) =>
        Answer($"words {account}", new KeyFingerprint(["f", "g", "h", "i", "j"], "qr"));

    public Task<KeyChange?> GetKeyChangeAsync(string account) => Answer<KeyChange?>($"key change {account}", null);

    public Task AcceptKeyChangeAsync(string account, string offeredIdentityKey, bool compared) =>
        Answer($"accept change {account} {offeredIdentityKey} {compared}", true);

    public Task<IReadOnlyList<KeyNotice>> GetKeyNoticesAsync() => Answer("notices", Notices);

    public Task DismissKeyNoticeAsync(string notice) => Answer($"dismiss {notice}", true);

    private Task<T> Answer<T>(string call, T value)
    {
        lock (_gate)
        {
            _calls.Add(call);
            var name = call.Split(' ')[0];
            if (Fails.Remove(name, out var error))
            {
                return Task.FromException<T>(new TableProException(error));
            }
        }

        return Task.FromResult(value);
    }
}
