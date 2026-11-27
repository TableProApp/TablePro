using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// Windows has no iCloud, so personal data stays here or goes to TablePro Sync (core ADR 0054, Providers).
public enum SyncProvider
{
    Off,
    TableProSync,
}

// OffKinds names the kinds this device leaves out by their wire names (tablepro-records), such as "saved_query".
public sealed record SyncCategories(IReadOnlyList<string> OffKinds, bool Passwords);

public sealed record SyncConfiguration(SyncProvider Provider, SyncCategories Categories)
{
    // The sign-in whose state file this device used last, as TableProSync.ServiceAccount gave it; null on first use.
    // Another account or server then waits for Move my data or Start empty.
    public string? ServiceAccount { get; init; }
}

public enum SyncPhase
{
    Off,
    Unavailable,
    Idle,
    Syncing,
    Waiting,
    PullOnly,
    NewIdentity,
}

// Problem is the last pass's error code, which the app words.
public sealed record SyncStatus(
    SyncPhase Phase,
    TimeSpan? RetryIn,
    DateTimeOffset? LastPass,
    string? Problem,
    int WaitingApprovals,
    int Conflicts,
    int Held,
    int QueuedChanges)
{
    public static SyncStatus Off { get; } = new(SyncPhase.Off, null, null, null, 0, 0, 0, 0);
}

// A scope as the server's last scopes answer named it; a switch is null where the scope carries none (core ADR 0051,
// Policies). Writable is false past the license's grace, when the server takes only key changes.
public sealed record SyncScopeStatus(
    string Scope,
    bool Writable,
    bool? PersonalSync,
    bool? PasswordSync,
    bool? HistorySync);

// What the first upload sends, what stays on this device, and the passwords sealed for it.
public sealed record SyncUploadPlan(long Records, long StayingBehind, long SecretsToSeal);

// The answer names Account back, so one given for an account signed out meanwhile is refused with sync.changed.
public sealed record NewIdentityPlan(long Unsent, string Account);

public enum NewIdentityChoice
{
    MoveMyData,
    StartEmpty,
}

public enum SyncPassReason
{
    Foreground,
    NetworkBack,
    Person,
}

[Flags]
public enum SyncChanges
{
    None = 0,

    // The status, the scopes, the approvals, the conflicts or the held records.
    Status = 1,

    // The key state, a session, a reset, a team's keys or the key notices.
    Keys = 2,
}

public enum SyncLockCause
{
    DeviceRemoved,
    LeftOutOfRotation,
    OwnAccountReset,
    AccountEnded,
    Unanchored,
    PersonalStopped,
}

// This device's place in the account's end-to-end keys (core ADR 0056).
public abstract record KeyState
{
    private KeyState()
    {
    }

    public sealed record NoDeviceStore : KeyState
    {
        public static NoDeviceStore Instance { get; } = new();
    }

    // Not read from the server yet.
    public sealed record Unknown : KeyState
    {
        public static Unknown Instance { get; } = new();
    }

    // The account has no keys yet: its first device sets up the recovery key.
    public sealed record NoKeys : KeyState
    {
        public static NoKeys Instance { get; } = new();
    }

    // Request is the approval this device asked for, null before it asked.
    public sealed record NeedsApproval(string? Request) : KeyState;

    public sealed record Approved(long AccountVersion, string KeyDevice) : KeyState;

    public sealed record Locked(SyncLockCause Cause) : KeyState;
}

// What a refused sync call carries beyond its code (core ADR 0051, Push; 0056, A locked device).
public abstract record SyncFailure
{
    private SyncFailure()
    {
    }

    public sealed record StepUp(IReadOnlyList<string> AcrValues, TimeSpan MaxAge) : SyncFailure;

    public sealed record RetryAfter(TimeSpan Delay) : SyncFailure;

    // The code the server gave the change it refused.
    public sealed record Rejected(string Code) : SyncFailure;

    public sealed record Locked(SyncLockCause Cause) : SyncFailure;
}

// One per app over the core's stores, bound to the sign-in it opened with: after a sign-in, a sign-out or another
// account the app opens it again. Disposing it stops the engines. Every call throws TableProException with a sync.*
// or keys.* code.
public sealed partial class TableProSync : IDisposable
{
    private readonly Native.SyncService _service;
    private readonly SyncWake _wake;
    private int _reading;
    private volatile bool _disposed;

    internal TableProSync(Native.SyncService service, SyncWake wake)
    {
        _service = service;
        _wake = wake;
    }

    // Snapshots; cheap enough to read on the UI thread.
    public SyncStatus Status => Mapping.Status(_service.Status());

    // Empty before TablePro Sync's first poll, and while it does not run.
    public IReadOnlyList<SyncScopeStatus> Scopes => [.. _service.ScopeStatuses().Select(Mapping.Scope)];

    // For SyncConfiguration.ServiceAccount at the next open; it changes once the person chose for another account.
    public string? ServiceAccount => _service.ServiceAccount();

    // Resumes on the caller's context; changes that come while it is busy are read as one. Read once.
    public async IAsyncEnumerable<SyncChanges> ReadChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The sync service's changes are already being read.");
        }

        while (await _wake.WaitAsync(cancellationToken) && !_disposed)
        {
            // A signal can outlive the flags a read already took.
            if (_wake.Take() is not SyncChanges.None and var changes)
            {
                yield return changes;
            }
        }
    }

    // A pass of each engine that holds records here; the first failure is the answer, after every pass ran.
    public Task SyncNowAsync(SyncPassReason why = SyncPassReason.Person)
    {
        var reason = Mapping.Reason(why);
        return CoreCall.RunAsync(() => _service.SyncNow(reason));
    }

    public Task SetCategoriesAsync(SyncCategories categories)
    {
        ArgumentNullException.ThrowIfNull(categories);
        var native = Mapping.Categories(categories);
        return CoreCall.RunAsync(() => _service.SetCategories(native));
    }

    // The history entries this device keeps, null for every entry: a snapshot of the history scope takes that many,
    // newest first.
    public void SetHistoryWindow(int? entries)
    {
        if (entries is < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(entries), entries, null);
        }

        _service.SetHistoryWindow(entries is { } count ? (uint)count : null);
    }

    // The core side of a provider change: from Off, the first upload, the server's copy winning a conflict; to Off,
    // personal sync stops and the team scopes go on. The app then keeps the provider and opens sync again with it.
    public Task ChooseProviderAsync(SyncProvider provider)
    {
        var native = Mapping.Provider(provider);
        return CoreCall.RunAsync(() => _service.ChooseProvider(native));
    }

    public async Task<SyncUploadPlan> PlanUploadAsync()
    {
        var plan = await CoreCall.RunAsync(() => _service.PlanMoveToService()).ConfigureAwait(false);
        return Mapping.Plan(plan);
    }

    // An upload this device started that the app has not finished, as a restart can leave it: true once everything
    // arrived, when the app keeps TablePro Sync and opens sync again with it; false while the core still runs it.
    public async Task<bool?> GetOpenUploadAsync()
    {
        var move = await CoreCall.RunAsync(() => _service.OpenMove()).ConfigureAwait(false);
        return move is { Target: Native.SyncProviderTag.TableproSync } ? move.Done : null;
    }

    public async Task<KeyState> GetKeyStateAsync() =>
        Mapping.Keys(await CoreCall.RunAsync(() => _service.KeyState()).ConfigureAwait(false));

    // While Status says NewIdentity: the changes the earlier account's file held unsent, and the account to answer.
    public async Task<NewIdentityPlan> PlanNewIdentityAsync()
    {
        var plan = await CoreCall.RunAsync(() => _service.PlanNewIdentity()).ConfigureAwait(false);
        return new NewIdentityPlan(Mapping.Count(plan.Unsent), plan.Account);
    }

    public Task ChooseForNewIdentityAsync(NewIdentityChoice choice, string account)
    {
        ArgumentException.ThrowIfNullOrEmpty(account);
        var native = choice == NewIdentityChoice.MoveMyData
            ? Native.NewIdentityChoiceTag.MoveMyData
            : Native.NewIdentityChoiceTag.StartEmpty;
        return CoreCall.RunAsync(() => _service.ChooseForNewIdentity(native, account));
    }

    public void Dispose()
    {
        _disposed = true;
        _wake.Close();
        _service.Dispose();
    }
}

// The core calls it on a runtime thread; one slot wakes the reader, and the flags keep what changed until it reads.
internal sealed class SyncWake : Native.SyncListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    private int _changes;

    public void StatusChanged() => Raise(SyncChanges.Status);

    public void KeysChanged() => Raise(SyncChanges.Keys);

    // False once the service is disposed and no change is left.
    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.WaitToReadAsync(cancellationToken);

    public SyncChanges Take()
    {
        _signal.Reader.TryRead(out _);
        return (SyncChanges)Interlocked.Exchange(ref _changes, 0);
    }

    public void Close() => _signal.Writer.TryComplete();

    private void Raise(SyncChanges change)
    {
        Interlocked.Or(ref _changes, (int)change);
        _signal.Writer.TryWrite(true);
    }
}
