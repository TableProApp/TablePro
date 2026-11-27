using TablePro.Interop;

namespace TablePro.App.Model;

// The core's sync service as SyncHost drives it, so the rules are tested without the core.
public interface ISyncEngine : IDisposable
{
    SyncStatus Status { get; }

    IReadOnlyList<SyncScopeStatus> Scopes { get; }

    string? ServiceAccount { get; }

    IAsyncEnumerable<SyncChanges> ReadChangesAsync(CancellationToken cancellationToken);

    Task SyncNowAsync(SyncPassReason why);

    Task SetCategoriesAsync(SyncCategories categories);

    void SetHistoryWindow(int? entries);

    Task ChooseProviderAsync(SyncProvider provider);

    Task<SyncUploadPlan> PlanUploadAsync();

    Task<bool?> GetOpenUploadAsync();

    Task<KeyState> GetKeyStateAsync();

    Task<NewIdentityPlan> PlanNewIdentityAsync();

    Task ChooseForNewIdentityAsync(NewIdentityChoice choice, string account);
}

// The parts of the app the host reads and writes: the sync settings in settings.json, the history the PC keeps, and
// the sign-in the account holds now.
public interface ISyncHostApp
{
    SyncSettings Sync { get; }

    void UpdateSync(Func<SyncSettings, SyncSettings> change);

    // Null keeps every entry.
    int? HistoryWindow { get; }

    // The signed-in account's id, null while signed out.
    string? SignIn { get; }

    // Opens the service over the sign-in the account holds now; throws TableProException.
    Task<ISyncEngine> OpenAsync(SyncConfiguration configuration);

    // A failure the person did not ask about, for the log: its code only, since the detail can name what they hold.
    void Note(string what, CoreError failure);
}

public enum SyncRefusal
{
    // Another change to how this PC syncs is still running.
    Busy,

    // The account signed in or out after the person confirmed, so the open service may be another account's.
    SignInChanged,

    // The server keeps no personal data (core ADR 0051, Policies).
    ServerRefusesPersonalSync,

    // Another account's data waits for Move my data or Start empty, which comes first.
    AccountChoicePending,
}

public abstract record UploadOutcome
{
    private UploadOutcome()
    {
    }

    public sealed record Uploaded : UploadOutcome
    {
        public static Uploaded Instance { get; } = new();
    }

    // Nothing personal goes up before this PC holds the account's keys (core ADR 0056).
    public sealed record NeedsKeys(KeyState State) : UploadOutcome;

    public sealed record Refused(SyncRefusal Reason) : UploadOutcome;

    public sealed record Failed(CoreError Error) : UploadOutcome;
}

// The app's one sync service (docs/decisions/0029-tablepro-sync.md): opened at launch on a PC that
// syncs and on first use otherwise, opened again after each sign-in change and provider change, since the core binds
// it to both. Everything runs on the UI thread, and Changed is raised there.
public sealed class SyncHost : IDisposable
{
    private readonly ISyncHostApp _app;
    private ISyncEngine? _engine;
    private Task<ISyncEngine?>? _opening;
    private CancellationTokenSource? _watch;
    private int _generation;
    private bool _started;
    private bool _moving;
    private bool _uploadResuming;
    private bool _disposed;
    private Task _categories = Task.CompletedTask;

    public SyncHost(ISyncHostApp app)
    {
        ArgumentNullException.ThrowIfNull(app);
        _app = app;
    }

    // The status, the scopes, the key state, an open that failed or a move that started or ended.
    public event EventHandler? Changed;

    // Null until the service opens, and after it closed for a sign-in change.
    public SyncStatus? Status => _engine?.Status;

    public IReadOnlyList<SyncScopeStatus> Scopes => _engine?.Scopes ?? [];

    // Null until read from the open service.
    public KeyState? Keys { get; private set; }

    // Why the last open failed, until one succeeds.
    public CoreError? OpenFailure { get; private set; }

    // Another account or server waits for Move my data or Start empty, with the account the answer names; read on each
    // status change, since the team scopes wait for it whatever the personal provider is.
    public NewIdentityPlan? AccountChoice { get; private set; }

    public bool IsMoving => _moving;

    // Once the account has read what this PC holds, since TablePro Sync stays bound to the sign-in it opens under. A PC
    // on TablePro Sync opens it now, and its scheduler polls from then on.
    public void Start()
    {
        if (_started || _disposed)
        {
            return;
        }

        _started = true;
        if (_app.Sync.Provider == SyncProvider.TableProSync)
        {
            _ = GetEngineAsync();
        }
    }

    // Null when it could not open, which OpenFailure says.
    public Task<ISyncEngine?> GetEngineAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_engine is not null)
        {
            return Task.FromResult<ISyncEngine?>(_engine);
        }

        if (_opening is { } opening)
        {
            return opening;
        }

        // An open that finished at once has already set the engine, or a later open, in place.
        var started = OpenAsync(_generation);
        if (!started.IsCompleted)
        {
            _opening = started;
        }

        return started;
    }

    // A sign-in, a sign-out or another account: the service closes, and one that was open or wanted opens again.
    public void SignInChanged()
    {
        if (!_started || _disposed)
        {
            return;
        }

        var reopen = _engine is not null || _opening is not null || _app.Sync.Provider == SyncProvider.TableProSync;
        Close();
        if (reopen)
        {
            _ = GetEngineAsync();
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    // The first upload from Off, confirmed in the upload dialog under confirmedSignIn: nothing goes up once another
    // sign-in holds the account, or before this PC holds the account's keys. The stored provider changes once the core
    // returns, and the service opens again with it.
    public async Task<UploadOutcome> UploadAsync(string? confirmedSignIn)
    {
        if (_moving)
        {
            return new UploadOutcome.Refused(SyncRefusal.Busy);
        }

        if (_app.SignIn != confirmedSignIn)
        {
            return new UploadOutcome.Refused(SyncRefusal.SignInChanged);
        }

        StartMove();
        try
        {
            if (await GetEngineAsync().ConfigureAwait(true) is not { } engine)
            {
                return OpenFailure is { } failure
                    ? new UploadOutcome.Failed(failure)
                    : new UploadOutcome.Refused(SyncRefusal.SignInChanged);
            }

            if (RefusesPersonalSync(engine.Scopes))
            {
                return new UploadOutcome.Refused(SyncRefusal.ServerRefusesPersonalSync);
            }

            await ReadAccountChoiceAsync(engine, _generation).ConfigureAwait(true);
            if (AccountChoice is not null)
            {
                return new UploadOutcome.Refused(SyncRefusal.AccountChoicePending);
            }

            var keys = await engine.GetKeyStateAsync().ConfigureAwait(true);
            if (_app.SignIn != confirmedSignIn || !ReferenceEquals(engine, _engine))
            {
                return new UploadOutcome.Refused(SyncRefusal.SignInChanged);
            }

            Keys = keys;
            if (keys is not KeyState.Approved)
            {
                return new UploadOutcome.NeedsKeys(keys);
            }

            await engine.ChooseProviderAsync(SyncProvider.TableProSync).ConfigureAwait(true);
            _app.UpdateSync(sync => sync with { Provider = SyncProvider.TableProSync });
            await FirstPassAsync(await ReopenAsync().ConfigureAwait(true)).ConfigureAwait(true);
            return UploadOutcome.Uploaded.Instance;
        }
        catch (TableProException exception)
        {
            return new UploadOutcome.Failed(exception.Error);
        }
        catch (ObjectDisposedException)
        {
            return new UploadOutcome.Refused(SyncRefusal.SignInChanged);
        }
        finally
        {
            EndMove();
        }
    }

    // Off is the person's word, kept at once: the core stops personal sync and the team scopes go on.
    public async Task TurnOffAsync()
    {
        if (_moving || _app.Sync.Provider == SyncProvider.Off)
        {
            return;
        }

        _app.UpdateSync(sync => sync with { Provider = SyncProvider.Off });
        // An open still in flight read TablePro Sync, so it is dropped as it lands and the service opens again Off.
        var reopen = _engine is not null || _opening is not null;
        StartMove();
        try
        {
            if (_engine is { } engine)
            {
                try
                {
                    await engine.ChooseProviderAsync(SyncProvider.Off).ConfigureAwait(true);
                }
                catch (TableProException exception)
                {
                    _app.Note("turn off", exception.Error);
                }
                catch (ObjectDisposedException)
                {
                    // A sign-in change closed it; the next open is Off already.
                }
            }

            if (reopen)
            {
                await ReopenAsync().ConfigureAwait(true);
            }
        }
        finally
        {
            EndMove();
        }
    }

    // Null when the pass ran; else what kept it, for the page to say under the status.
    public async Task<CoreError?> SyncNowAsync()
    {
        if (await GetEngineAsync().ConfigureAwait(true) is not { } engine)
        {
            return OpenFailure ?? Overtaken;
        }

        try
        {
            await engine.SyncNowAsync(SyncPassReason.Person).ConfigureAwait(true);
            return null;
        }
        catch (TableProException exception)
        {
            _app.Note("sync now", exception.Error);
            return exception.Error;
        }
        catch (ObjectDisposedException)
        {
            return Overtaken;
        }
        finally
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    // The app came to the front or the network came back; a failure shows in the status, so it is only logged.
    public async Task NudgeAsync(SyncPassReason why)
    {
        if (_engine is not { } engine)
        {
            return;
        }

        try
        {
            await engine.SyncNowAsync(why).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _app.Note("pass", exception.Error);
        }
        catch (ObjectDisposedException)
        {
            // Closed meanwhile; the service that replaced it runs its own passes.
        }
    }

    // The answer names the plan's account, so one given for an account signed out meanwhile is refused with
    // sync.changed, and the choice is read again. Throws TableProException.
    public async Task ChooseForNewIdentityAsync(NewIdentityChoice choice, NewIdentityPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        try
        {
            var engine = await OnEngineAsync(async engine =>
            {
                await engine.ChooseForNewIdentityAsync(choice, plan.Account).ConfigureAwait(true);
                return engine;
            }).ConfigureAwait(true);
            KeepServiceAccount(engine);
            await ReadAccountChoiceAsync(engine, _generation).ConfigureAwait(true);
            Changed?.Invoke(this, EventArgs.Empty);
            await FirstPassAsync(engine).ConfigureAwait(true);
        }
        catch (TableProException)
        {
            if (_engine is { } current)
            {
                await ReadAccountChoiceAsync(current, _generation).ConfigureAwait(true);
                Changed?.Invoke(this, EventArgs.Empty);
            }

            throw;
        }
    }

    // What the first upload sends. Throws TableProException.
    public Task<SyncUploadPlan> PlanUploadAsync() => OnEngineAsync(engine => engine.PlanUploadAsync());

    // After the settings changed; the switches apply before the first upload too. In order, each with the settings as
    // they are when it runs, so the last change is the one the core keeps.
    public Task ApplyCategoriesAsync()
    {
        _categories = ApplyCategoriesAfterAsync(_categories);
        return _categories;
    }

    private async Task ApplyCategoriesAfterAsync(Task before)
    {
        await before.ConfigureAwait(true);
        if (_engine is not { } engine)
        {
            return;
        }

        try
        {
            await engine.SetCategoriesAsync(_app.Sync.Categories()).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _app.Note("categories", exception.Error);
        }
        catch (ObjectDisposedException)
        {
            // The service that replaced it opened with the settings as they are now.
        }
    }

    public void ApplyHistoryWindow() => _engine?.SetHistoryWindow(_app.HistoryWindow);

    // A server whose personal_sync switch is off takes no personal data while this PC is signed in to it; the stored
    // provider stays, so the PC picks up again once the switch is back on (core ADR 0051, Policies; 0055).
    public static bool RefusesPersonalSync(IReadOnlyList<SyncScopeStatus> scopes)
    {
        ArgumentNullException.ThrowIfNull(scopes);
        return scopes.FirstOrDefault(scope => scope.Scope == "personal")?.PersonalSync == false;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _generation++;
        _opening = null;
        _watch?.Cancel();
        _watch?.Dispose();
        _watch = null;
        _engine?.Dispose();
        _engine = null;
    }

    // An open that a sign-in change overtook has no failure of its own.
    private static CoreError Overtaken { get; } =
        new("sync.changed", ["sync.changed"], "the sign-in changed while sync opened", null, null);

    // A call on a service a sign-in change closed meanwhile reads as the change it was.
    private async Task<T> OnEngineAsync<T>(Func<ISyncEngine, Task<T>> call)
    {
        var engine = await GetEngineAsync().ConfigureAwait(true)
            ?? throw new TableProException(OpenFailure ?? Overtaken);
        try
        {
            return await call(engine).ConfigureAwait(true);
        }
        catch (ObjectDisposedException)
        {
            throw new TableProException(Overtaken);
        }
    }

    private async Task<ISyncEngine?> OpenAsync(int generation)
    {
        var sync = _app.Sync;
        var configuration = new SyncConfiguration(sync.Provider, sync.Categories())
        {
            ServiceAccount = sync.ServiceAccount,
        };
        ISyncEngine engine;
        try
        {
            engine = await _app.OpenAsync(configuration).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _app.Note("open", exception.Error);
            if (generation == _generation && !_disposed)
            {
                _opening = null;
                OpenFailure = exception.Error;
                Changed?.Invoke(this, EventArgs.Empty);
            }

            return null;
        }

        if (generation != _generation || _disposed)
        {
            engine.Dispose();
            return null;
        }

        _opening = null;
        _engine = engine;
        OpenFailure = null;
        engine.SetHistoryWindow(_app.HistoryWindow);
        // A switch changed while the open ran, which it did not read.
        if (Switches(sync) != Switches(_app.Sync))
        {
            _ = ApplyCategoriesAsync();
        }

        KeepServiceAccount(engine);
        _watch = new CancellationTokenSource();
        _ = WatchAsync(engine, generation, _watch.Token);
        Changed?.Invoke(this, EventArgs.Empty);
        _ = SettleAsync(engine, generation, sync.Provider);
        return engine;
    }

    private static SyncSettings Switches(SyncSettings sync) =>
        sync with { Provider = SyncProvider.Off, ServiceAccount = null };

    // Apart from the open, since an upload found finished opens the service again.
    private async Task SettleAsync(ISyncEngine engine, int generation, SyncProvider provider)
    {
        await ReadKeysAsync(engine, generation).ConfigureAwait(true);
        await ReadAccountChoiceAsync(engine, generation).ConfigureAwait(true);
        if (provider == SyncProvider.Off)
        {
            await AdoptFinishedUploadAsync(engine, generation).ConfigureAwait(true);
        }

        if (generation == _generation)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task<ISyncEngine?> ReopenAsync()
    {
        Close();
        Changed?.Invoke(this, EventArgs.Empty);
        return await GetEngineAsync().ConfigureAwait(true);
    }

    private void Close()
    {
        _generation++;
        _opening = null;
        _uploadResuming = false;
        _watch?.Cancel();
        _watch?.Dispose();
        _watch = null;
        _engine?.Dispose();
        _engine = null;
        Keys = null;
        AccountChoice = null;
        OpenFailure = null;
    }

    private async Task WatchAsync(ISyncEngine engine, int generation, CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var changes in engine.ReadChangesAsync(cancellationToken).ConfigureAwait(true))
            {
                if (generation != _generation)
                {
                    return;
                }

                if (changes.HasFlag(SyncChanges.Status))
                {
                    KeepServiceAccount(engine);
                    await ReadAccountChoiceAsync(engine, generation).ConfigureAwait(true);
                }

                if (changes.HasFlag(SyncChanges.Keys))
                {
                    await ReadKeysAsync(engine, generation).ConfigureAwait(true);
                }

                if (_uploadResuming && changes.HasFlag(SyncChanges.Status))
                {
                    await AdoptFinishedUploadAsync(engine, generation).ConfigureAwait(true);
                }

                if (generation == _generation)
                {
                    Changed?.Invoke(this, EventArgs.Empty);
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Closed for a sign-in or provider change, or the app is closing.
        }
        catch (ObjectDisposedException)
        {
            // Closed while a read was in flight.
        }
    }

    private async Task ReadKeysAsync(ISyncEngine engine, int generation)
    {
        try
        {
            var keys = await engine.GetKeyStateAsync().ConfigureAwait(true);
            if (generation == _generation)
            {
                Keys = keys;
            }
        }
        catch (TableProException exception)
        {
            _app.Note("key state", exception.Error);
        }
        catch (ObjectDisposedException)
        {
            // Closed meanwhile; the next open reads its own.
        }
    }

    // The core answers sync.not_allowed while no choice waits, which is the common case.
    private async Task ReadAccountChoiceAsync(ISyncEngine engine, int generation)
    {
        NewIdentityPlan? plan;
        try
        {
            plan = await engine.PlanNewIdentityAsync().ConfigureAwait(true);
        }
        catch (TableProException)
        {
            plan = null;
        }
        catch (ObjectDisposedException)
        {
            return;
        }

        if (generation == _generation)
        {
            AccountChoice = plan;
        }
    }

    // An upload a restart cut short: the core goes on with it as the service opens, and once everything arrived the
    // app keeps TablePro Sync, as it would have when the upload returned (core ADR 0054, Moving between providers).
    private async Task AdoptFinishedUploadAsync(ISyncEngine engine, int generation)
    {
        bool? done;
        try
        {
            done = await engine.GetOpenUploadAsync().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _app.Note("open upload", exception.Error);
            return;
        }
        catch (ObjectDisposedException)
        {
            return;
        }

        if (generation != _generation || _moving || _app.Sync.Provider != SyncProvider.Off)
        {
            return;
        }

        _uploadResuming = done == false;
        if (done == true)
        {
            _app.UpdateSync(sync => sync with { Provider = SyncProvider.TableProSync });
            _ = ReopenAsync();
        }
    }

    private async Task FirstPassAsync(ISyncEngine? engine)
    {
        if (engine is null)
        {
            return;
        }

        try
        {
            await engine.SyncNowAsync(SyncPassReason.Person).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            _app.Note("first pass", exception.Error);
        }
        catch (ObjectDisposedException)
        {
            // Closed meanwhile; the service that replaced it runs its own passes.
        }

        Changed?.Invoke(this, EventArgs.Empty);
    }

    // The sign-in the state file follows changes once the person chose for another account.
    private void KeepServiceAccount(ISyncEngine engine)
    {
        if (!ReferenceEquals(engine, _engine))
        {
            return;
        }

        var account = engine.ServiceAccount;
        if (account != _app.Sync.ServiceAccount)
        {
            _app.UpdateSync(sync => sync with { ServiceAccount = account });
        }
    }

    private void StartMove()
    {
        _moving = true;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void EndMove()
    {
        _moving = false;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
