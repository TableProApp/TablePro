using TablePro.Interop;

namespace TablePro.App.Model;

// Settings > Sync > End-to-end encryption: this PC's key state, the devices holding the account's keys and the
// requests waiting for approval (core ADR 0056, Approving a device; Account flows). Everything runs on the UI thread.
public sealed class AccountKeysPage
{
    private readonly Func<Task<IKeyFlows>> _flows;
    private readonly StepUpRetry _stepUp;
    private Task? _reloading;
    private bool _reloadsAgain;
    // Bumped when the account signs in or out, so a read still out for the old one lands nowhere.
    private int _generation;

    public AccountKeysPage(Func<Task<IKeyFlows>> flows, StepUpRetry stepUp)
    {
        ArgumentNullException.ThrowIfNull(flows);
        ArgumentNullException.ThrowIfNull(stepUp);
        _flows = flows;
        _stepUp = stepUp;
    }

    public event EventHandler? Changed;

    public KeyState? State { get; private set; }

    public CoreError? StateFailure { get; private set; }

    public bool IsLoading { get; private set; }

    public IReadOnlyList<KeyDevice> Devices { get; private set; } = [];

    public CoreError? DevicesFailure { get; private set; }

    public IReadOnlyList<ApprovalRequest> Requests { get; private set; } = [];

    // The key device whose row is going.
    public string? Removing { get; private set; }

    public bool IsApproved => State is KeyState.Approved;

    // A reset needs keys on the account: from an approved PC, one waiting for approval or a locked one.
    public bool ShowsResets => State is KeyState.Approved or KeyState.NeedsApproval or KeyState.Locked;

    // This PC first, then by when each joined, oldest first.
    public static IReadOnlyList<KeyDevice> Ordered(IReadOnlyList<KeyDevice> devices)
    {
        ArgumentNullException.ThrowIfNull(devices);
        return
        [
            .. devices
                .OrderByDescending(device => device.IsThisDevice)
                .ThenBy(device => device.AddedAt ?? DateTimeOffset.MaxValue),
        ];
    }

    // A locked PC asks again only where the lock leaves it a way back on this sign-in.
    public static bool CanAskForApproval(SyncLockCause cause) => cause is SyncLockCause.LeftOutOfRotation
        or SyncLockCause.OwnAccountReset or SyncLockCause.Unanchored or SyncLockCause.PersonalStopped;

    public static bool CanRecover(SyncLockCause cause) =>
        cause is SyncLockCause.LeftOutOfRotation or SyncLockCause.Unanchored or SyncLockCause.PersonalStopped;

    // Another account's keys, devices and requests are never shown under this one.
    public void ForgetAccount()
    {
        _generation++;
        State = null;
        StateFailure = null;
        Devices = [];
        DevicesFailure = null;
        Requests = [];
        Removing = null;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // One read at a time; a change that lands during one reads again once it ends. A failed read keeps what was shown.
    public async Task ReloadAsync()
    {
        _reloadsAgain = true;
        if (_reloading is { } running)
        {
            await running.ConfigureAwait(true);
            return;
        }

        // A run that finished at once has already cleared itself.
        var started = RunReloadsAsync();
        if (!started.IsCompleted)
        {
            _reloading = started;
        }

        await started.ConfigureAwait(true);
    }

    // While the page is on screen, an approved PC reads the requests waiting for it.
    public async Task ReadRequestsAsync()
    {
        if (!IsApproved)
        {
            return;
        }

        var generation = _generation;
        try
        {
            var requests = await (await _flows().ConfigureAwait(true)).GetApprovalRequestsAsync().ConfigureAwait(true);
            if (generation == _generation)
            {
                Requests = requests;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is not null)
        {
            // The list stays as it was until the next read.
        }
    }

    // The row goes first, behind a fresh step-up (core ADR 0051, Step-up); then the recovery key and the review. A
    // device whose row is already gone goes straight to the recovery key. Null when the removal goes on to the review;
    // else why the row did not go.
    public async Task<CoreError?> RemoveRowAsync(KeyDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (device.Device is not { } row)
        {
            return null;
        }

        var generation = _generation;
        Removing = device.KeyDeviceId;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            await _stepUp.RunAsync(() => flows.RemoveDeviceRowAsync(row)).ConfigureAwait(true);
            return generation == _generation ? null : KeyErrors.Changed;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            return generation == _generation ? error : KeyErrors.Changed;
        }
        finally
        {
            Removing = null;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    private async Task RunReloadsAsync()
    {
        try
        {
            while (_reloadsAgain)
            {
                _reloadsAgain = false;
                await ReadAsync().ConfigureAwait(true);
            }
        }
        finally
        {
            _reloading = null;
        }
    }

    private async Task ReadAsync()
    {
        var generation = _generation;
        IsLoading = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            var flows = await _flows().ConfigureAwait(true);
            var state = await flows.GetKeyStateAsync().ConfigureAwait(true);
            if (generation != _generation)
            {
                return;
            }

            State = state;
            StateFailure = null;
            if (state is KeyState.Approved)
            {
                await ReadDevicesAsync(flows, generation).ConfigureAwait(true);
                await ReadRequestsAsync().ConfigureAwait(true);
            }
            else
            {
                Devices = [];
                Requests = [];
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (generation == _generation)
            {
                StateFailure = error;
            }
        }
        finally
        {
            if (generation == _generation)
            {
                IsLoading = false;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    private async Task ReadDevicesAsync(IKeyFlows flows, int generation)
    {
        try
        {
            var devices = await flows.GetAccountDevicesAsync().ConfigureAwait(true);
            if (generation == _generation)
            {
                Devices = Ordered(devices);
                DevicesFailure = null;
            }
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (generation == _generation)
            {
                DevicesFailure = error;
            }
        }
    }
}

public enum KeysSignOutAnswer
{
    TryAgain,
    SignOutAnyway,
    Cancel,
}

// Sign out's part for the keys (core ADR 0056, Sign Out): before the sign-in is revoked, this PC's key device is revoked
// and its keys erased. Offline the core erases anyway; when it could not erase, the person decides.
public static class KeysSignOut
{
    // False when the person keeps the sign-in after the keys could not be erased, or the sign-in it ran for ended,
    // which isCurrent answers before each try. Every try goes to the service the first one reached, which stays bound
    // to the sign-in it opened under, so a retry after another sign-in never erases that one's keys.
    public static async Task<bool> RunAsync(
        Func<Task<IKeyFlows>> flows,
        Func<bool> isCurrent,
        Func<CoreError, Task<KeysSignOutAnswer>> askAfterFailure)
    {
        ArgumentNullException.ThrowIfNull(flows);
        ArgumentNullException.ThrowIfNull(isCurrent);
        ArgumentNullException.ThrowIfNull(askAfterFailure);
        IKeyFlows? bound = null;
        while (isCurrent())
        {
            CoreError failure;
            try
            {
                bound ??= await flows().ConfigureAwait(true);
                if (!isCurrent())
                {
                    return false;
                }

                // The core decides whether anything is there to erase, whatever the key state reads.
                await bound.SignOutKeysAsync().ConfigureAwait(true);
                return true;
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
            {
                // No key engine runs on a service with no sign-in, so it never made a key device here to erase.
                if (error.Code is "sync.unimplemented" or "sync.signed_out")
                {
                    return true;
                }

                failure = error;
            }

            switch (await askAfterFailure(failure).ConfigureAwait(true))
            {
                case KeysSignOutAnswer.TryAgain:
                    continue;
                case KeysSignOutAnswer.SignOutAnyway:
                    return isCurrent();
                default:
                    return false;
            }
        }

        return false;
    }
}
