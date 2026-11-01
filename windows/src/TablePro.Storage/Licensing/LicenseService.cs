using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using TablePro.Core.Licensing;
using TablePro.Storage.Localization;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Licensing;

/// <summary>The app and system versions every request reports, as the device list shows them.</summary>
public sealed record LicenseClientInfo(string AppVersion, string OsVersion)
{
    public static LicenseClientInfo ForThisSystem(string appVersion) => new(appVersion, RuntimeInformation.OSDescription);
}

/// <summary>
/// What a list on the license page is doing. Loading means nothing to show yet; a reload of a list that already loaded
/// stays Loaded and raises a refreshing flag instead, so a refresh never blanks what it refreshes.
/// </summary>
public enum LicenseListState
{
    Idle,
    Loading,
    Loaded,
    Failed,
}

/// <summary>
/// The license on this machine: it verifies the cached payload offline at start, activates and deactivates against the
/// license server, checks back every seven days, and keeps paid features running for 30 days without the server.
/// This is the macOS app's license manager. State is read and written under one lock, because a check runs on the
/// thread pool while the settings page acts on the UI thread; events fire on the thread that made the change.
/// </summary>
public sealed class LicenseService : IDisposable
{
    private readonly ILicenseApiClient _api;
    private readonly LicenseStore _store;
    private readonly IMachineIdentity _machine;
    private readonly LicenseSignatureVerifier _verifier;
    private readonly LicenseClientInfo _client;
    private readonly TimeProvider _clock;
    private readonly Lock _lock = new();

    // Activation, deactivation and checks change which license is held, so they run one at a time: a periodic check
    // finishing after an activation must not put the previous license back.
    private readonly SemaphoreSlim _operation = new(1, 1);
    private CancellationTokenSource? _periodic;

    private License? _license;
    private LicenseStatus _status = LicenseStatus.Unlicensed;

    // Not persisted: it can only take entitlement away, and writing it down would put license state outside the signature.
    private LicenseStatus? _serverRejection;

    // When the server last confirmed the license by this machine's clock. Memory only, so nothing on disk can forge it.
    private DateTimeOffset? _lastServerContact;

    // Separates Deactivated from Unlicensed for this session; a relaunch with no license is simply unlicensed.
    private bool _wasDeactivatedLocally;
    private int _busy;
    private LicenseException? _lastError;

    private IReadOnlyList<LicenseActivation> _devices = [];
    private int _maxDevices;
    private LicenseListState _deviceState;
    private LicenseException? _deviceError;
    private bool _isRefreshingDevices;
    private HashSet<string> _releasing = new(StringComparer.Ordinal);
    private LicenseException? _releaseError;
    private LicenseException? _refreshError;

    private LicenseTeam? _team;
    private LicenseListState _teamState;
    private LicenseException? _teamError;

    public LicenseService(ILicenseApiClient api, LicenseStore store, IMachineIdentity machine, LicenseSignatureVerifier verifier, LicenseClientInfo client, TimeProvider? clock = null)
    {
        _api = api;
        _store = store;
        _machine = machine;
        _verifier = verifier;
        _client = client;
        _clock = clock ?? TimeProvider.System;
    }

    /// <summary>Any state the license page shows changed.</summary>
    public event EventHandler? Changed;

    /// <summary>The effective status changed, which is what feature gates follow.</summary>
    public event EventHandler? StatusChanged;

    /// <summary>The server confirmed the license in a check.</summary>
    public event EventHandler? Confirmed;

    /// <summary>The license was removed from this machine, so anything it granted must go with it.</summary>
    public event EventHandler? Removed;

    /// <summary>The service the app uses: the production server, its public key, Credential Manager and this PC's SMBIOS id.</summary>
    [SupportedOSPlatform("windows")]
    public static LicenseService CreateDefault(AppPaths paths, ISecretStore secrets, string appVersion) =>
        new(new HttpLicenseApiClient(DefaultHttp.Value), new LicenseStore(paths, secrets), new WindowsMachineIdentity(paths), new LicenseSignatureVerifier(), LicenseClientInfo.ForThisSystem(appVersion));

    // The macOS client gives a request 15 seconds; the client lives as long as the app.
    private static readonly Lazy<HttpClient> DefaultHttp = new(() => new HttpClient { Timeout = TimeSpan.FromSeconds(15) });

    public string MachineId => _machine.MachineId;

    public string MachineName => _machine.MachineName;

    public License? License => Read(() => _license);

    public LicenseStatus Status => Read(() => _status);

    /// <summary>Whether an activation, deactivation or check is in flight; the page disables its buttons on it.</summary>
    public bool IsValidating => Read(() => _busy > 0);

    public LicenseException? LastError => Read(() => _lastError);

    public LicenseTier CurrentTier => License?.Tier ?? LicenseTier.Starter;

    /// <summary>Who the support links speak to; an offline license still reads as paid for.</summary>
    public SupportAudience SupportAudience => Read(() => LicenseRules.ResolveSupportAudience(_license is not null, _status));

    public IReadOnlyList<LicenseActivation> Devices => Read(() => _devices);

    public int MaxDevices => Read(() => _maxDevices);

    public LicenseListState DeviceListState => Read(() => _deviceState);

    public LicenseException? DeviceListError => Read(() => _deviceError);

    public bool IsRefreshingDevices => Read(() => _isRefreshingDevices);

    /// <summary>Why the last seat release did not go through, kept beside the list rather than replacing it.</summary>
    public LicenseException? ReleaseError => Read(() => _releaseError);

    /// <summary>Why the last reload of an already loaded list did not go through.</summary>
    public LicenseException? RefreshError => Read(() => _refreshError);

    public LicenseTeam? Team => Read(() => _team);

    public LicenseListState TeamListState => Read(() => _teamState);

    public LicenseException? TeamListError => Read(() => _teamError);

    /// <summary>
    /// Whether releasing another machine's seat is offered: only on a license nobody else shares. The server checks a
    /// key and a machine id and nothing else, so on a Team license any member could release any teammate, and a role
    /// check here would only hide a button. Team seats are managed on the web.
    /// </summary>
    public bool CanReleaseOtherDevices => License is { IsTeamLicense: false };

    /// <summary>Whether the license is entitled to a roster, asked through Unlocks so a future tier is not denied one.</summary>
    public bool ShowsTeamRoster => License is { } license && (license.IsTeamLicense || license.Tier.Unlocks(LicenseTier.Team));

    public bool IsReleasing(string machineId) => Read(() => _releasing.Contains(machineId));

    public ProFeatureAccess CheckFeature(ProFeature feature) => Read(() => LicenseRules.ResolveAccess(_status, _license?.Tier ?? LicenseTier.Starter, feature.RequiredTier()));

    public bool IsFeatureAvailable(ProFeature feature) => CheckFeature(feature).IsAvailable;

    /// <summary>Adopts the cached license when its signature and machine still hold, and drops it when they do not.</summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        var cached = await _store.LoadAsync(cancellationToken);
        var rejection = cached is null ? CachedLicenseRejection.None : LicenseRules.ResolveCachedLicense(cached, MachineId, _verifier.Verify);
        if (rejection != CachedLicenseRejection.None)
        {
            _store.Clear();
            cached = null;
        }

        Mutate(() => _license = cached);
    }

    /// <summary>Checks now when the last confirmation is a week old or more, then every week while the app runs.</summary>
    public void StartPeriodicValidation()
    {
        var periodic = new CancellationTokenSource();
        Interlocked.Exchange(ref _periodic, periodic)?.Cancel();
        _ = RunPeriodicValidationAsync(periodic);
    }

    /// <summary>Activates a license key or accepts a team invite code, told apart by shape.</summary>
    public Task ActivateAsync(string codeOrKey, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(codeOrKey);
        var entry = codeOrKey.Trim();
        if (entry.Length == 0)
        {
            throw new LicenseException(LicenseErrorKind.InvalidKey, StorageStrings.Get("License/KeyEmpty"));
        }

        return LicenseRules.IsLicenseKey(entry) ? ActivateKeyAsync(entry.ToUpperInvariant(), cancellationToken) : AcceptInviteAsync(entry, cancellationToken);
    }

    /// <summary>Gives up this machine's seat. The license is removed here even when the server cannot be reached.</summary>
    /// <returns>Whether the server confirmed the release.</returns>
    public async Task<bool> DeactivateAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken);
        try
        {
            return await DeactivateHeldAsync(cancellationToken);
        }
        finally
        {
            _operation.Release();
        }
    }

    /// <summary>
    /// Releases a seat, this machine's or another one's. Releasing this one must clear the license here too, or the page
    /// would show an active license until the next check noticed, a week later.
    /// </summary>
    /// <returns>Whether the server confirmed the release.</returns>
    public async Task<bool> ReleaseSeatAsync(string machineId, CancellationToken cancellationToken = default)
    {
        if (machineId == MachineId)
        {
            return await DeactivateAsync(cancellationToken);
        }

        await RunAsync(async license => await _api.DeactivateAsync(new LicenseDeactivationRequest(license.Key, machineId), cancellationToken), cancellationToken);
        return true;
    }

    /// <summary>
    /// Asks the server about the held license. A new payload restarts the grace period; a rejection the server spoke
    /// takes entitlement away; a request that never reached it falls back to the 30-day grace.
    /// </summary>
    public async Task RevalidateAsync(CancellationToken cancellationToken = default)
    {
        await _operation.WaitAsync(cancellationToken);
        try
        {
            if (License is not { } license)
            {
                return;
            }

            Mutate(() => _busy++);
            try
            {
                var signed = await _api.ValidateAsync(Request(license.Key), cancellationToken);
                var updated = Adopt(signed);
                await _store.SaveAsync(updated, cancellationToken);
                Mutate(() =>
                {
                    _license = updated;
                    _lastError = null;
                    _serverRejection = null;
                    _lastServerContact = _clock.GetUtcNow();
                });
                Confirmed?.Invoke(this, EventArgs.Empty);
            }
            catch (Exception ex) when (ex is LicenseException or IOException or UnauthorizedAccessException)
            {
                // A cache that could not be written is no rejection; only what the server said may revoke.
                var error = ex as LicenseException ?? new LicenseException(LicenseErrorKind.Network, ex.Message, ex);
                Mutate(() =>
                {
                    _serverRejection = LicenseRules.RevocationStatus(error.Kind) ?? _serverRejection;
                    _lastError = error;
                });
            }
            finally
            {
                Mutate(() => _busy--);
            }
        }
        finally
        {
            _operation.Release();
        }
    }

    /// <summary>Loads the seats this license holds. A page appearing passes false and is answered from what already loaded.</summary>
    public async Task LoadDevicesAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        License? license = null;
        var proceed = false;
        Mutate(() =>
        {
            license = _license;
            proceed = license is not null && (force || _deviceState == LicenseListState.Idle);
            if (!proceed)
            {
                return;
            }

            _releaseError = null;
            _refreshError = null;
            if (_deviceState == LicenseListState.Loaded)
            {
                _isRefreshingDevices = true;
            }
            else
            {
                _deviceState = LicenseListState.Loading;
            }
        });
        if (!proceed)
        {
            return;
        }

        try
        {
            var response = await _api.ListActivationsAsync(Request(license!.Key), cancellationToken);
            Mutate(() =>
            {
                _devices = response.Activations ?? [];
                _maxDevices = response.MaxActivations;
                _deviceState = LicenseListState.Loaded;
                _deviceError = null;
            });
        }
        catch (OperationCanceledException)
        {
            // A cancelled load is not an outcome; recording it as a failure would latch the appearance check above.
            Mutate(() => _deviceState = _deviceState == LicenseListState.Loaded ? LicenseListState.Loaded : LicenseListState.Idle);
        }
        catch (LicenseException ex)
        {
            Mutate(() =>
            {
                if (_deviceState == LicenseListState.Loaded)
                {
                    _refreshError = ex;
                }
                else
                {
                    _deviceState = LicenseListState.Failed;
                    _deviceError = ex;
                }
            });
        }
        finally
        {
            Mutate(() => _isRefreshingDevices = false);
        }
    }

    /// <summary>
    /// Releases one seat, then reconciles the list. Nothing is removed optimistically: the row goes only once the server
    /// agreed, so a failure leaves the list as it was with the reason beside it.
    /// </summary>
    public async Task ReleaseDeviceAsync(LicenseActivation device, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(device);
        if (License is null)
        {
            return;
        }

        var isThisMachine = device.MachineId == MachineId;
        Mutate(() =>
        {
            _releasing = new HashSet<string>(_releasing, StringComparer.Ordinal) { device.MachineId };
            _releaseError = null;
        });

        try
        {
            await ReleaseSeatAsync(device.MachineId, cancellationToken);
        }
        catch (LicenseException ex)
        {
            Mutate(() => _releaseError = ex);
            return;
        }
        finally
        {
            Mutate(() =>
            {
                var remaining = new HashSet<string>(_releasing, StringComparer.Ordinal);
                remaining.Remove(device.MachineId);
                _releasing = remaining;
            });
        }

        // This machine's own release already reset the list and said whether the server held the seat.
        if (!isThisMachine)
        {
            Mutate(() =>
            {
                _devices = [.. _devices.Where(d => d.MachineId != device.MachineId)];
                _deviceState = LicenseListState.Loaded;
            });
        }
    }

    /// <summary>Loads a Team license's roster. Read only, because what writes it needs a sign-in the app does not have.</summary>
    public async Task LoadTeamAsync(bool force = false, CancellationToken cancellationToken = default)
    {
        var license = License;
        if (license is null || !ShowsTeamRoster)
        {
            return;
        }

        var proceed = false;
        Mutate(() =>
        {
            proceed = force || _teamState == LicenseListState.Idle;
            if (proceed && _teamState != LicenseListState.Loaded)
            {
                _teamState = LicenseListState.Loading;
            }
        });
        if (!proceed)
        {
            return;
        }

        try
        {
            var team = await _api.TeamAsync(Request(license.Key), cancellationToken);
            Mutate(() =>
            {
                _team = team;
                _teamState = LicenseListState.Loaded;
                _teamError = null;
            });
        }
        catch (OperationCanceledException)
        {
            Mutate(() => _teamState = _teamState == LicenseListState.Loaded ? LicenseListState.Loaded : LicenseListState.Idle);
        }
        catch (LicenseException ex)
        {
            // A roster already on screen survives a refresh that could not reach the server.
            Mutate(() =>
            {
                if (_teamState != LicenseListState.Loaded)
                {
                    _teamState = LicenseListState.Failed;
                    _teamError = ex;
                }
            });
        }
    }

    /// <summary>
    /// Brings the license, its seats and its roster back in step with the server. The check goes first because it
    /// restamps this machine's row, which the reload then reads.
    /// </summary>
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        await RevalidateAsync(cancellationToken);
        await LoadDevicesAsync(force: true, cancellationToken);
        await LoadTeamAsync(force: true, cancellationToken);
    }

    public void Dispose()
    {
        Interlocked.Exchange(ref _periodic, null)?.Cancel();
        _operation.Dispose();
    }

    private async Task ActivateKeyAsync(string key, CancellationToken cancellationToken)
    {
        await RunAsync(
            async _ =>
            {
                var signed = await _api.ActivateAsync(Request(key), cancellationToken);
                await TakeUpAsync(signed, key, cancellationToken);
            },
            cancellationToken,
            requiresLicense: false);
    }

    private async Task AcceptInviteAsync(string code, CancellationToken cancellationToken)
    {
        await RunAsync(
            async _ =>
            {
                var signed = await _api.AcceptInviteAsync(new LicenseInviteRequest(code, MachineId, MachineName, _client.AppVersion, _client.OsVersion), cancellationToken);
                await TakeUpAsync(signed, signed.Data.LicenseKey, cancellationToken);
            },
            cancellationToken,
            requiresLicense: false);
    }

    /// <summary>
    /// Takes up a license just activated here. The seat and roster lists describe the previous license, so they go, and
    /// periodic checks restart because a deactivation earlier in the session stopped them.
    /// </summary>
    private async Task TakeUpAsync(SignedLicensePayload signed, string key, CancellationToken cancellationToken)
    {
        var license = Adopt(signed);
        _store.SaveKey(key);
        await _store.SaveAsync(license, cancellationToken);
        Mutate(() =>
        {
            _license = license;
            _wasDeactivatedLocally = false;
            _serverRejection = null;
            _lastServerContact = _clock.GetUtcNow();
            ResetDevices();
            ResetTeam();
        });
        StartPeriodicValidation();
    }

    private async Task<bool> DeactivateHeldAsync(CancellationToken cancellationToken)
    {
        if (License is not { } license)
        {
            return true;
        }

        Mutate(() =>
        {
            _busy++;
            _lastError = null;
        });
        var reachedServer = true;
        try
        {
            await _api.DeactivateAsync(new LicenseDeactivationRequest(license.Key, MachineId), cancellationToken);
        }
        catch (LicenseException)
        {
            reachedServer = false;
        }
        catch (OperationCanceledException)
        {
            Mutate(() => _busy--);
            throw;
        }

        _store.Clear();
        Interlocked.Exchange(ref _periodic, null)?.Cancel();
        Mutate(() =>
        {
            _license = null;
            _serverRejection = null;
            _lastServerContact = null;
            _wasDeactivatedLocally = true;
            ResetDevices();
            ResetTeam();

            // Said after the reset, which clears it: a silent success would tell somebody their seat was freed while the
            // server still holds it, and their next activation would fail on the seat limit.
            if (!reachedServer)
            {
                _releaseError = new LicenseException(LicenseErrorKind.SeatReleaseUnconfirmed, StorageStrings.Get("License/SeatUnconfirmed"));
            }

            _busy--;
        });
        Removed?.Invoke(this, EventArgs.Empty);
        return reachedServer;
    }

    /// <summary>Runs a license-changing call one at a time, recording its failure for the page.</summary>
    private async Task RunAsync(Func<License, Task> operation, CancellationToken cancellationToken, bool requiresLicense = true)
    {
        await _operation.WaitAsync(cancellationToken);
        try
        {
            var license = License;
            if (requiresLicense && license is null)
            {
                return;
            }

            Mutate(() =>
            {
                _busy++;
                _lastError = null;
            });
            try
            {
                await operation(license!);
            }
            catch (LicenseException ex)
            {
                Mutate(() => _lastError = ex);
                throw;
            }
            finally
            {
                Mutate(() => _busy--);
            }
        }
        finally
        {
            _operation.Release();
        }
    }

    private async Task RunPeriodicValidationAsync(CancellationTokenSource periodic)
    {
        var token = periodic.Token;
        try
        {
            if (License is { } license && (license.DaysSinceLastValidation(_clock.GetUtcNow()) ?? int.MaxValue) >= LicenseRules.RevalidationInterval.TotalDays)
            {
                await RevalidateAsync(token);
            }

            while (!token.IsCancellationRequested)
            {
                await Task.Delay(LicenseRules.RevalidationInterval, _clock, token);
                await RevalidateAsync(token);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
            // The service was disposed while a check waited for its turn.
        }
        finally
        {
            periodic.Dispose();
        }
    }

    /// <summary>Verifies a payload and refuses one the server minted for another machine; every trusted payload passes here.</summary>
    private License Adopt(SignedLicensePayload signed)
    {
        var data = _verifier.Verify(signed);
        if (!LicenseRules.AcceptsMachine(data.MachineId, MachineId))
        {
            throw new LicenseException(LicenseErrorKind.MachineMismatch, StorageStrings.Get("License/MachineMismatch"));
        }

        return new License { SignedPayload = signed, CachedOnMachineId = MachineId };
    }

    private LicenseClientRequest Request(string key) => new(key, MachineId, MachineName, _client.AppVersion, _client.OsVersion);

    private void ResetDevices()
    {
        _devices = [];
        _maxDevices = 0;
        _releasing = new HashSet<string>(StringComparer.Ordinal);
        _releaseError = null;
        _refreshError = null;
        _deviceError = null;
        _deviceState = LicenseListState.Idle;
    }

    private void ResetTeam()
    {
        _team = null;
        _teamError = null;
        _teamState = LicenseListState.Idle;
    }

    private T Read<T>(Func<T> read)
    {
        lock (_lock)
        {
            return read();
        }
    }

    /// <summary>Changes state, settles the status from it, and announces both once the lock is released.</summary>
    private void Mutate(Action change)
    {
        bool statusChanged;
        lock (_lock)
        {
            change();
            var previous = _status;
            _status = EvaluateStatus();
            statusChanged = previous != _status;
        }

        Changed?.Invoke(this, EventArgs.Empty);
        if (statusChanged)
        {
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private LicenseStatus EvaluateStatus()
    {
        if (_license is not { } license)
        {
            return LicenseRules.ResolveUnlicensedStatus(_wasDeactivatedLocally);
        }

        var now = _clock.GetUtcNow();
        var recentContact = _lastServerContact is { } contact && now - contact <= TimeSpan.FromDays(LicenseRules.GracePeriodDays);
        return LicenseRules.ResolveStatus(license.SignedStatus, license.IsExpired(now), license.DaysSinceLastValidation(now), _serverRejection, recentContact);
    }
}
