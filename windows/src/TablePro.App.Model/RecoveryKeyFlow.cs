using TablePro.Interop;

namespace TablePro.App.Model;

public enum RecoveryKeyPurpose
{
    SetUp,
    Replace,
}

public enum RecoveryKeyStep
{
    EnterCurrentKey,
    ChooseDevices,
    ShowKey,
    TypeBack,

    // Another device's set-up landed first, so this one asks it for approval instead.
    AnotherDeviceWon,
    Done,
}

// A new recovery key, shown once and checked by two groups typed back before anything goes up (core ADR 0056, The
// recovery key): the first one at set-up, or a replacement, which first takes the current key and asks which compared
// devices keep their keys. The key lives here only while the dialog is open. Everything runs on the UI thread.
public sealed class RecoveryKeyFlow
{
    private readonly Func<Task<IKeyFlows>> _flows;
    private readonly HashSet<string> _keep = new(StringComparer.Ordinal);
    private readonly string[] _typed = [string.Empty, string.Empty];
    private string? _draft;
    private bool _closed;

    public RecoveryKeyFlow(RecoveryKeyPurpose purpose, Func<Task<IKeyFlows>> flows)
    {
        ArgumentNullException.ThrowIfNull(flows);
        Purpose = purpose;
        _flows = flows;
        Step = purpose == RecoveryKeyPurpose.Replace ? RecoveryKeyStep.EnterCurrentKey : RecoveryKeyStep.ShowKey;
    }

    public event EventHandler? Changed;

    public RecoveryKeyPurpose Purpose { get; }

    public RecoveryKeyStep Step { get; private set; }

    public bool IsWorking { get; private set; }

    public CoreError? Failure { get; private set; }

    public string CurrentKey { get; set; } = string.Empty;

    // The two groups as typed, in the order Check names them.
    public IReadOnlyList<string> Typed => _typed;

    public IReadOnlyList<string> Groups { get; private set; } = [];

    // The groups to type back, counted from 0.
    public IReadOnlyList<int> Check { get; private set; } = [];

    public IReadOnlyList<ReviewedDevice> Devices { get; private set; } = [];

    public bool HasKey => _draft is not null;

    public bool CanContinue => !IsWorking && Step switch
    {
        RecoveryKeyStep.EnterCurrentKey => !string.IsNullOrWhiteSpace(CurrentKey),
        RecoveryKeyStep.ChooseDevices or RecoveryKeyStep.ShowKey => _draft is not null,
        RecoveryKeyStep.TypeBack => _typed.All(group => !string.IsNullOrWhiteSpace(group)),
        _ => true,
    };

    // As the person types; the dialog reads CanContinue after.
    public void SetTyped(int index, string text) => _typed[index] = text ?? string.Empty;

    // A device the rotation may keep: one this PC compared words with. This PC always stays.
    public static bool CanKeep(ReviewedDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        return device.Device.Compared && !device.Device.IsThisDevice;
    }

    public bool Keeps(ReviewedDevice device)
    {
        ArgumentNullException.ThrowIfNull(device);
        return _keep.Contains(device.Device.KeyDeviceId);
    }

    public void SetKeep(ReviewedDevice device, bool kept)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (!CanKeep(device))
        {
            return;
        }

        if (kept)
        {
            _keep.Add(device.Device.KeyDeviceId);
        }
        else
        {
            _keep.Remove(device.Device.KeyDeviceId);
        }

        Raise();
    }

    // Set-up draws its key as the dialog opens.
    public async Task StartAsync()
    {
        if (Purpose != RecoveryKeyPurpose.SetUp || _draft is not null || IsWorking || _closed)
        {
            return;
        }

        await WorkingAsync(async () =>
        {
            var flows = await _flows().ConfigureAwait(true);
            var made = await flows.BeginGenesisAsync().ConfigureAwait(true);
            if (_closed)
            {
                flows.DiscardKeyDraft(made.Draft);
                return;
            }

            Adopt(made);
        }).ConfigureAwait(true);
    }

    public async Task AdvanceAsync()
    {
        if (!CanContinue)
        {
            return;
        }

        Failure = null;
        switch (Step)
        {
            case RecoveryKeyStep.EnterCurrentKey:
                await BeginReplaceAsync().ConfigureAwait(true);
                break;
            case RecoveryKeyStep.ChooseDevices:
                Step = RecoveryKeyStep.ShowKey;
                Raise();
                break;
            case RecoveryKeyStep.ShowKey:
                _typed[0] = string.Empty;
                _typed[1] = string.Empty;
                Step = RecoveryKeyStep.TypeBack;
                Raise();
                break;
            case RecoveryKeyStep.TypeBack:
                await FinishAsync().ConfigureAwait(true);
                break;
        }
    }

    // Back to the key from the check, before anything goes up.
    public void ShowKeyAgain()
    {
        if (Step != RecoveryKeyStep.TypeBack || IsWorking)
        {
            return;
        }

        Failure = null;
        Step = RecoveryKeyStep.ShowKey;
        Raise();
    }

    // The dialog closed: what it held goes with it, in the core too, and a call still out lands nowhere.
    public async Task DiscardAsync()
    {
        _closed = true;
        if (_draft is { } draft)
        {
            _draft = null;
            try
            {
                (await _flows().ConfigureAwait(true)).DiscardKeyDraft(draft);
            }
            catch (Exception exception) when (KeyErrors.Of(exception) is not null)
            {
                // A service closed meanwhile dropped its drafts with it.
            }
        }

        ClearSecrets();
    }

    private async Task BeginReplaceAsync()
    {
        var current = CurrentKey.Trim();
        await WorkingAsync(async () =>
        {
            var flows = await _flows().ConfigureAwait(true);
            var rotation = await flows.BeginReplaceRecoveryKeyAsync(current).ConfigureAwait(true);
            if (_closed)
            {
                flows.DiscardKeyDraft(rotation.Recovery.Draft);
                return;
            }

            CurrentKey = string.Empty;
            Devices = rotation.Devices;
            _keep.Clear();
            foreach (var device in rotation.Devices.Where(device => device.KeepByDefault && CanKeep(device)))
            {
                _keep.Add(device.Device.KeyDeviceId);
            }

            Adopt(rotation.Recovery);
            Step = rotation.Devices.Any(device => !device.Device.IsThisDevice)
                ? RecoveryKeyStep.ChooseDevices
                : RecoveryKeyStep.ShowKey;
        }).ConfigureAwait(true);
    }

    private async Task FinishAsync()
    {
        if (_draft is not { } draft)
        {
            return;
        }

        string[] typed = [_typed[0].Trim(), _typed[1].Trim()];
        string[] keep = [.. Devices.Select(device => device.Device.KeyDeviceId).Where(_keep.Contains)];
        await WorkingAsync(async () =>
        {
            var flows = await _flows().ConfigureAwait(true);
            if (Purpose == RecoveryKeyPurpose.SetUp)
            {
                var outcome = await flows.FinishGenesisAsync(draft, typed).ConfigureAwait(true);
                Step = outcome == GenesisOutcome.AnotherDeviceWon
                    ? RecoveryKeyStep.AnotherDeviceWon
                    : RecoveryKeyStep.Done;
            }
            else
            {
                await flows.FinishReplaceRecoveryKeyAsync(draft, typed, keep).ConfigureAwait(true);
                Step = RecoveryKeyStep.Done;
            }

            _draft = null;
            ClearSecrets();
        }).ConfigureAwait(true);
    }

    private void Adopt(RecoveryKeyDraft made)
    {
        _draft = made.Draft;
        Groups = RecoveryKeyText.Groups(made.Text);
        Check = made.Check;
        if (Purpose == RecoveryKeyPurpose.SetUp)
        {
            Step = RecoveryKeyStep.ShowKey;
        }
    }

    private void ClearSecrets()
    {
        Groups = [];
        Check = [];
        _typed[0] = string.Empty;
        _typed[1] = string.Empty;
        CurrentKey = string.Empty;
        Raise();
    }

    private async Task WorkingAsync(Func<Task> body)
    {
        IsWorking = true;
        Raise();
        try
        {
            await body().ConfigureAwait(true);
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (!_closed)
            {
                Failure = error;
            }
        }
        finally
        {
            IsWorking = false;
            Raise();
        }
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}

// Recovery with the recovery key on a PC with no approved device at hand (core ADR 0056, Recovery with R): its
// rotation keeps only this PC, and every other device asks this one for approval afterwards.
public sealed class RecoverFlow(Func<Task<IKeyFlows>> flows)
{
    private bool _closed;

    public event EventHandler? Changed;

    public string RecoveryKey { get; set; } = string.Empty;

    public bool IsWorking { get; private set; }

    public CoreError? Failure { get; private set; }

    public bool IsDone { get; private set; }

    public bool CanRecover => !IsWorking && !string.IsNullOrWhiteSpace(RecoveryKey);

    public async Task RecoverAsync()
    {
        if (!CanRecover || _closed)
        {
            return;
        }

        var recoveryKey = RecoveryKey.Trim();
        Failure = null;
        IsWorking = true;
        Changed?.Invoke(this, EventArgs.Empty);
        try
        {
            await (await flows().ConfigureAwait(true)).RecoverWithRecoveryKeyAsync(recoveryKey).ConfigureAwait(true);
            RecoveryKey = string.Empty;
            IsDone = true;
        }
        catch (Exception exception) when (KeyErrors.Of(exception) is { } error)
        {
            if (!_closed)
            {
                Failure = error;
            }
        }
        finally
        {
            IsWorking = false;
            Changed?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Discard()
    {
        _closed = true;
        RecoveryKey = string.Empty;
    }
}
