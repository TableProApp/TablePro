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

    public void Note(string what, CoreError error)
    {
        lock (_gate)
        {
            _notes.Add($"{what}: {error.Code}");
        }
    }
}
