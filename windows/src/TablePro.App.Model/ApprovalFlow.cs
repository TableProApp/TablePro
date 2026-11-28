using TablePro.Interop;

namespace TablePro.App.Model;

public enum ApprovalStep
{
    // The approver looks at the request before it commits to it.
    Reviewing,
    Starting,
    Waiting,
    Chosen,
    Compare,
    Confirmed,
    Approved,
    TakenElsewhere,
    Cancelled,
    Expired,
    Failed,
}

// One approval session as either side sees it (core ADR 0056, Approving a device): this PC asking, or an approved PC
// answering a request it picked. The dialog polls the session every 1.5 s while it is open, as the ADR asks of both
// devices, and the five words live only here. Everything runs on the UI thread.
public sealed class ApprovalFlow : IDisposable
{
    public static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(1_500);

    private readonly Func<Task<IKeyFlows>> _flows;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;
    private CancellationTokenSource? _polling;
    private bool _started;
    private bool _closed;
    // The session ended as the core reported it, so a close cancels nothing more.
    private bool _settled;

    // A new device's flow; request is the one it already has open, if any.
    public ApprovalFlow(Func<Task<IKeyFlows>> flows, Func<TimeSpan, CancellationToken, Task> delay, string? request = null)
        : this(flows, delay, ApprovalRole.NewDevice, null, request)
    {
    }

    // An approver's flow for a request the person picked.
    public ApprovalFlow(Func<Task<IKeyFlows>> flows, Func<TimeSpan, CancellationToken, Task> delay, ApprovalRequest picked)
        : this(flows, delay, ApprovalRole.Approver, picked ?? throw new ArgumentNullException(nameof(picked)), null)
    {
    }

    private ApprovalFlow(
        Func<Task<IKeyFlows>> flows,
        Func<TimeSpan, CancellationToken, Task> delay,
        ApprovalRole role,
        ApprovalRequest? picked,
        string? request)
    {
        ArgumentNullException.ThrowIfNull(flows);
        ArgumentNullException.ThrowIfNull(delay);
        _flows = flows;
        _delay = delay;
        Role = role;
        Picked = picked;
        Request = request;
        Step = role == ApprovalRole.Approver ? ApprovalStep.Reviewing : ApprovalStep.Starting;
    }

    public event EventHandler? Changed;

    public ApprovalRole Role { get; }

    // The request the approver picked, null for the new device.
    public ApprovalRequest? Picked { get; }

    public string? Request { get; private set; }

    public ApprovalStep Step { get; private set; }

    // While Step is Compare; never kept once the session moves on.
    public IReadOnlyList<string> Words { get; private set; } = [];

    public ApprovalEnd? EndReason { get; private set; }

    public DateTimeOffset? ExpiresAt { get; private set; }

    public bool IsWorking { get; private set; }

    // Why the session ended, for Failed, or why the last action did not run.
    public CoreError? Failure { get; private set; }

    public bool HasEnded => Step is ApprovalStep.Approved or ApprovalStep.TakenElsewhere or ApprovalStep.Cancelled
        or ApprovalStep.Expired or ApprovalStep.Failed;

    // This PC writes its request, or picks up the one it already has open.
    public async Task StartAsync()
    {
        if (Role != ApprovalRole.NewDevice || _started || _closed)
        {
            return;
        }

        _started = true;
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            var request = Request ?? await flows.RequestApprovalAsync().ConfigureAwait(true);
            if (_closed)
            {
                await CancelQuietlyAsync(flows, request).ConfigureAwait(true);
                return;
            }

            Request = request;
            Apply(await flows.GetApprovalSessionAsync(request).ConfigureAwait(true));
            StartPolling();
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Fail(error);
        }
    }

    // The approver commits to the request: the session is held by this PC from then on.
    public async Task ApproveAsync()
    {
        if (Picked is not { } picked || Step != ApprovalStep.Reviewing)
        {
            return;
        }

        Step = ApprovalStep.Starting;
        Request = picked.Request;
        Raise();
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            Apply(await flows.ChooseApprovalRequestAsync(picked.Request).ConfigureAwait(true));
            StartPolling();
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Fail(error);
        }
    }

    public Task WordsMatchAsync() => ActAsync(async (flows, request) =>
        Apply(await flows.ConfirmApprovalSessionAsync(request).ConfigureAwait(true)));

    public Task WordsDifferAsync() => ActAsync(async (flows, request) =>
    {
        await flows.ApprovalWordsDifferAsync(request).ConfigureAwait(true);
        _settled = true;
        End(ApprovalStep.Cancelled, ApprovalEnd.Mismatch);
    });

    public async Task RefreshAsync()
    {
        if (Request is not { } request || HasEnded || _closed)
        {
            return;
        }

        try
        {
            var flows = await _flows().ConfigureAwait(true);
            Apply(await flows.GetApprovalSessionAsync(request).ConfigureAwait(true));
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Failure = error;
            Raise();
        }
    }

    // The dialog closed. A session still running is cancelled as the person's, so the other side stops too.
    public async Task CloseAsync()
    {
        _closed = true;
        StopPolling();
        if (Request is not { } request || _settled)
        {
            return;
        }

        _settled = true;
        if (!HasEnded)
        {
            End(ApprovalStep.Cancelled, ApprovalEnd.User);
        }

        try
        {
            await CancelQuietlyAsync(await _flows().ConfigureAwait(true), request).ConfigureAwait(true);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is not null)
        {
            // No service is left to tell; the session expires on the server.
        }
    }

    private static async Task CancelQuietlyAsync(IKeyFlows flows, string request)
    {
        try
        {
            await flows.CancelApprovalSessionAsync(request).ConfigureAwait(true);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is not null)
        {
            // The session expires on the server.
        }
    }

    private async Task ActAsync(Func<IKeyFlows, string, Task> action)
    {
        if (Step != ApprovalStep.Compare || Request is not { } request || IsWorking)
        {
            return;
        }

        IsWorking = true;
        Raise();
        try
        {
            await action(await _flows().ConfigureAwait(true), request).ConfigureAwait(true);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            Failure = error;
        }
        finally
        {
            IsWorking = false;
            Raise();
        }
    }

    private void StartPolling()
    {
        if (_polling is not null || HasEnded || _closed)
        {
            return;
        }

        _polling = new CancellationTokenSource();
        _ = PollAsync(_polling.Token);
    }

    private async Task PollAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested && !HasEnded)
            {
                await _delay(PollInterval, cancellationToken).ConfigureAwait(true);
                await RefreshAsync().ConfigureAwait(true);
            }
        }
        catch (OperationCanceledException)
        {
            // The dialog closed or the session ended.
        }
    }

    private void StopPolling()
    {
        _polling?.Cancel();
        _polling?.Dispose();
        _polling = null;
    }

    // An answer after the dialog closed or the session ended changes nothing: an ended session never shows words again.
    private void Apply(ApprovalSession session)
    {
        if (_closed || HasEnded)
        {
            return;
        }

        ExpiresAt = session.ExpiresAt;
        Failure = null;
        Words = [];
        switch (session.Phase)
        {
            case ApprovalPhase.Open:
                Step = ApprovalStep.Waiting;
                break;
            case ApprovalPhase.Chosen:
                Step = ApprovalStep.Chosen;
                break;
            case ApprovalPhase.Compare compare:
                Step = ApprovalStep.Compare;
                Words = compare.Words;
                break;
            case ApprovalPhase.Confirmed:
                Step = ApprovalStep.Confirmed;
                break;
            case ApprovalPhase.Approved:
                _settled = true;
                End(ApprovalStep.Approved, null);
                return;
            case ApprovalPhase.TakenElsewhere:
                _settled = true;
                End(ApprovalStep.TakenElsewhere, null);
                return;
            case ApprovalPhase.Cancelled cancelled:
                _settled = true;
                End(ApprovalStep.Cancelled, cancelled.Reason);
                return;
            default:
                _settled = true;
                End(ApprovalStep.Expired, null);
                return;
        }

        Raise();
    }

    private void Fail(CoreError error)
    {
        if (_closed)
        {
            return;
        }

        Failure = error;
        End(ApprovalStep.Failed, null);
    }

    private void End(ApprovalStep step, ApprovalEnd? reason)
    {
        Step = step;
        EndReason = reason;
        Words = [];
        StopPolling();
        Raise();
    }

    public void Dispose()
    {
        _polling?.Cancel();
        _polling?.Dispose();
        _polling = null;
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
