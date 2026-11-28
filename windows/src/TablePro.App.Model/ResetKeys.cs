using TablePro.Interop;

namespace TablePro.App.Model;

// A reset that ended, or one a server restore lost, which goes up again only after a fresh step-up (core ADR 0065).
public sealed record ResetNotice(string Id, ResetState? Ended, string? WaitsForStepUp);

public enum ResetWork
{
    Cancelling,
    Activating,
    ProposingAgain,
    Dismissing,
}

// A reset when the recovery key is lost (core ADR 0056, Account flows, Reset): a proposal held 7 days that any device
// certified at the current keys, or the recovery key, can cancel, then the proposing device's activation. Everything
// runs on the UI thread.
public sealed class ResetKeys
{
    private readonly Func<Task<IKeyFlows>> _flows;
    private readonly StepUpRetry _stepUp;
    private readonly Func<DateTimeOffset> _now;
    // Each load takes the next, so a slow answer never overwrites a newer one.
    private int _generation;
    // Each account change takes the next, so what an action for the old one answers lands nowhere.
    private int _account;

    public ResetKeys(Func<Task<IKeyFlows>> flows, StepUpRetry stepUp, Func<DateTimeOffset> now)
    {
        ArgumentNullException.ThrowIfNull(flows);
        ArgumentNullException.ThrowIfNull(stepUp);
        ArgumentNullException.ThrowIfNull(now);
        _flows = flows;
        _stepUp = stepUp;
        _now = now;
    }

    public event EventHandler? Changed;

    public KeyState? KeyState { get; private set; }

    // Only one still waiting; one that ended shows as a notice.
    public PendingReset? Pending { get; private set; }

    public IReadOnlyList<ResetNotice> Notices { get; private set; } = [];

    public CoreError? LoadFailure { get; private set; }

    public ResetWork? Work { get; private set; }

    // What the last action met, for the page to say.
    public CoreError? Failure { get; private set; }

    // A reset needs keys on the account: kind 2 from an approved PC, kind 3 from one waiting for approval or locked.
    public ResetKind? OfferedKind => KeyState switch
    {
        Interop.KeyState.Approved => ResetKind.KeepScopeKeys,
        Interop.KeyState.NeedsApproval or Interop.KeyState.Locked => ResetKind.StartEmpty,
        _ => null,
    };

    // Only a device certified at the current keys cancels without the recovery key.
    public bool CancelsWithoutRecoveryKey => KeyState is Interop.KeyState.Approved;

    public bool CanActivate(PendingReset reset)
    {
        ArgumentNullException.ThrowIfNull(reset);
        return reset.Mine && reset.State == ResetState.Pending && _now() >= reset.HeldUntil;
    }

    // Another account's reset and notices never show under the next one.
    public void ForgetAccount()
    {
        _account++;
        _generation++;
        KeyState = null;
        Pending = null;
        Notices = [];
        LoadFailure = null;
        Work = null;
        Failure = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public async Task LoadAsync()
    {
        var generation = ++_generation;
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            var state = await flows.GetKeyStateAsync().ConfigureAwait(true);
            var reset = await flows.GetPendingResetAsync().ConfigureAwait(true);
            var notices = await flows.GetKeyNoticesAsync().ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }

            KeyState = state;
            Pending = reset is { State: ResetState.Pending } ? reset : null;
            Notices = [.. notices.Select(Notice).OfType<ResetNotice>()];
            LoadFailure = null;
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

    // RecoveryKey is null where this PC cancels as one certified at the current keys.
    public Task<bool> CancelAsync(PendingReset reset, string? recoveryKey)
    {
        ArgumentNullException.ThrowIfNull(reset);
        var key = string.IsNullOrWhiteSpace(recoveryKey) ? null : recoveryKey.Trim();
        return PerformAsync(ResetWork.Cancelling, flows => flows.CancelResetAsync(reset.Reset, key));
    }

    public Task<bool> ActivateAsync(PendingReset reset)
    {
        ArgumentNullException.ThrowIfNull(reset);
        return PerformAsync(ResetWork.Activating, flows => flows.ActivateResetAsync(reset.Reset));
    }

    public Task<bool> ProposeAgainAsync(string reset) =>
        PerformAsync(ResetWork.ProposingAgain, flows => _stepUp.RunAsync(() => flows.ResumeResetAsync(reset)));

    public Task<bool> DismissAsync(ResetNotice notice)
    {
        ArgumentNullException.ThrowIfNull(notice);
        return PerformAsync(ResetWork.Dismissing, flows => flows.DismissKeyNoticeAsync(notice.Id));
    }

    private static ResetNotice? Notice(KeyNotice notice) => notice.Kind switch
    {
        KeyNoticeKind.ResetEnded ended => new ResetNotice(notice.Id, ended.State, null),
        KeyNoticeKind.ResetWaitsForStepUp waits => new ResetNotice(notice.Id, null, waits.Reset),
        _ => null,
    };

    private async Task<bool> PerformAsync(ResetWork work, Func<IKeyFlows, Task> call)
    {
        if (Work is not null)
        {
            return false;
        }

        var account = _account;
        Work = work;
        Failure = null;
        Changed?.Invoke(this, EventArgs.Empty);
        var done = false;
        try
        {
            await call(await _flows().ConfigureAwait(true)).ConfigureAwait(true);
            done = true;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (account == _account)
            {
                Failure = error;
            }
        }
        finally
        {
            Work = null;
        }

        if (account != _account)
        {
            return false;
        }

        await LoadAsync().ConfigureAwait(true);
        return done;
    }
}

public enum ResetProposalStep
{
    Explain,
    Preparing,
    ShowKey,
    TypeBack,
    Submitting,
    Done,
}

// One proposal: the new recovery key shown once, two of its groups typed back, then the reset goes up (core ADR 0056,
// The recovery key). A kind 3 proposal needs a fresh step-up, which the account runs once when the server asks for it.
public sealed class ResetProposal(ResetKind kind, Func<Task<IKeyFlows>> flows, StepUpRetry stepUp)
{
    private readonly string[] _typed = [string.Empty, string.Empty];
    private RecoveryKeyDraft? _draft;
    private bool _closed;

    public event EventHandler? Changed;

    public ResetKind Kind { get; } = kind;

    public ResetProposalStep Step { get; private set; }

    public CoreError? Failure { get; private set; }

    public PendingReset? Proposed { get; private set; }

    public IReadOnlyList<string> Groups => _draft is { } draft ? RecoveryKeyText.Groups(draft.Text) : [];

    // The groups to type back, counted from 0.
    public IReadOnlyList<int> Check => _draft?.Check ?? [];

    public IReadOnlyList<string> Typed => _typed;

    public bool CanSubmit =>
        Step == ResetProposalStep.TypeBack && _typed.All(group => !string.IsNullOrWhiteSpace(group));

    public void SetTyped(int index, string text) => _typed[index] = text ?? string.Empty;

    public async Task BeginAsync()
    {
        if (Step != ResetProposalStep.Explain)
        {
            return;
        }

        Step = ResetProposalStep.Preparing;
        Failure = null;
        Raise();
        try
        {
            var keys = await flows().ConfigureAwait(true);
            var made = await stepUp.RunAsync(() => keys.BeginResetAsync(Kind)).ConfigureAwait(true);
            if (_closed)
            {
                keys.DiscardKeyDraft(made.Draft);
                return;
            }

            _draft = made;
            Step = ResetProposalStep.ShowKey;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Failure = error;
            Step = ResetProposalStep.Explain;
        }

        Raise();
    }

    public void ContinueToTypeBack()
    {
        if (Step != ResetProposalStep.ShowKey)
        {
            return;
        }

        _typed[0] = string.Empty;
        _typed[1] = string.Empty;
        Failure = null;
        Step = ResetProposalStep.TypeBack;
        Raise();
    }

    public void ShowKeyAgain()
    {
        if (Step != ResetProposalStep.TypeBack)
        {
            return;
        }

        Step = ResetProposalStep.ShowKey;
        Raise();
    }

    public async Task SubmitAsync()
    {
        if (!CanSubmit || _draft is not { } draft)
        {
            return;
        }

        Step = ResetProposalStep.Submitting;
        Failure = null;
        Raise();
        string[] typed = [_typed[0].Trim(), _typed[1].Trim()];
        try
        {
            var keys = await flows().ConfigureAwait(true);
            Proposed = await stepUp.RunAsync(() => keys.FinishResetProposalAsync(draft.Draft, typed)).ConfigureAwait(true);
            _draft = null;
            Step = ResetProposalStep.Done;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Failure = error;
            Step = ResetProposalStep.TypeBack;
        }

        Raise();
    }

    // The dialog closed before the proposal went up, so the core drops the draft and the recovery key it holds.
    public async Task CloseAsync()
    {
        _closed = true;
        if (_draft is not { } draft || Step == ResetProposalStep.Submitting)
        {
            return;
        }

        _draft = null;
        _typed[0] = string.Empty;
        _typed[1] = string.Empty;
        try
        {
            (await flows().ConfigureAwait(true)).DiscardKeyDraft(draft.Draft);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is not null)
        {
            // A service closed meanwhile dropped its drafts with it.
        }
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
