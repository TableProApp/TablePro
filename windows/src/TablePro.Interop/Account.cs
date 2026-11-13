using System.Runtime.CompilerServices;
using System.Threading.Channels;
using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The callback texts are the browser's page once the sign-in comes back, in the app's language (core ADR 0026).
public sealed record AccountConfiguration(
    string DeviceName,
    string AppVersion,
    string OsVersion,
    string AccountFile,
    string CallbackFinished,
    string CallbackUnknown)
{
    // Both null for tablepro.app; a development build names its local stack's two.
    public string? AccountUrl { get; init; }

    public string? ApiUrl { get; init; }

    // The x of each Ed25519 key a development stack signs with; empty for the release keys.
    public IReadOnlyList<string> EntitlementKeys { get; init; } = [];

    // Null reads MachineGuid from the registry, the only source on Windows; elsewhere a test gives one.
    public string? MachineGuid { get; init; }
}

// The core calls it on a thread it lets block; false or a throw ends the sign-in with account.browser.
public interface IAccountBrowser
{
    Task<bool> OpenAsync(Uri url);
}

public enum AccountState
{
    SignedOut,
    SignedIn,

    // An imported offline file on a machine that is not signed in.
    Offline,
}

public enum FeatureAccess
{
    Available,
    SignedOut,
    NotIncluded,
    Expired,
    RefreshFailed,
    DeviceLimitReached,
}

// Codes stay strings, as the core keeps them: a plan, status or role this build does not know still shows.
public sealed record AccountStatus(
    AccountState State,
    string? AccountId,
    string? Email,
    string? Name,
    IReadOnlyList<string> Features,
    IReadOnlyList<AccountLicense> Licenses,
    DateTimeOffset? EntitlementExpiresAt,
    EntitlementProblem? Problem,
    bool Remembered)
{
    public static AccountStatus SignedOut { get; } =
        new(AccountState.SignedOut, null, null, null, [], [], null, null, false);
}

public abstract record EntitlementProblem
{
    private EntitlementProblem()
    {
    }

    public sealed record Expired : EntitlementProblem
    {
        public static Expired Instance { get; } = new();
    }

    // Code is the error the last refresh met, which the app words.
    public sealed record RefreshFailed(string Code) : EntitlementProblem;

    public sealed record DeviceLimitReached(IReadOnlyList<AccountDevice> Devices) : EntitlementProblem;
}

public sealed record AccountTeam(string Id, string Name);

public sealed record AccountLicense(
    string Id,
    string Plan,
    string Cycle,
    string Source,
    string Status,
    DateTimeOffset? RenewsAt,
    DateTimeOffset? EndsAt,
    AccountTeam? Team);

public sealed record AccountMembership(AccountTeam Team, string Role, bool HasSeat);

public sealed record AccountProfile(
    string Id,
    string Email,
    string? Name,
    IReadOnlyList<AccountLicense> Licenses,
    IReadOnlyList<AccountMembership> Teams);

// Until OfflineUntil, removing the device is refused with the server's offline_file_active.
public sealed record AccountDevice(
    string Id,
    string Platform,
    string Name,
    string AppVersion,
    string OsVersion,
    DateTimeOffset LastSeenAt,
    DateTimeOffset? LicensedAt,
    DateTimeOffset? OfflineUntil,
    bool IsThisMachine);

// One per app; disposing it stops the refresh schedule. Every call throws TableProException with an account.* code.
public sealed class TableProAccount : IDisposable
{
    private readonly Native.AccountService _service;
    private readonly AccountWake _wake;
    private int _reading;
    private volatile bool _disposed;

    internal TableProAccount(Native.AccountService service, AccountWake wake)
    {
        _service = service;
        _wake = wake;
    }

    // A snapshot; cheap enough to read on the UI thread.
    public AccountStatus Status => Mapping.Status(_service.Status());

    // From the entitlement's feature codes only: the app knows no plan or tier.
    public FeatureAccess Access(string feature)
    {
        ArgumentNullException.ThrowIfNull(feature);
        return Mapping.Access(_service.FeatureAccess(feature));
    }

    // Resumes on the caller's context; changes that come while it is busy are read as one. Read once.
    public async IAsyncEnumerable<AccountStatus> ReadStatusChangesAsync(
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        if (Interlocked.Exchange(ref _reading, 1) == 1)
        {
            throw new InvalidOperationException("The account's changes are already being read.");
        }

        while (await _wake.WaitAsync(cancellationToken) && !_disposed)
        {
            _wake.Take();
            yield return Status;
        }
    }

    // The cancel ends only the wait for the browser: once it has come back, the sign-in is kept.
    public Task SignInAsync(CancellationToken cancellationToken = default) =>
        CoreCall.RunAsync(token => _service.SignIn(token), cancellationToken);

    // Signs out here even when the server could not be told, which the error then says.
    public Task SignOutAsync() => CoreCall.RunAsync(() => _service.SignOut());

    public Task RefreshAsync() => CoreCall.RunAsync(() => _service.Refresh());

    // False when the account was not past the device limit, so nothing was asked.
    public Task<bool> RefreshPastDeviceLimitAsync() => CoreCall.RunAsync(() => _service.RefreshPastDeviceLimit());

    public async Task<AccountProfile> GetProfileAsync() =>
        Mapping.Profile(await CoreCall.RunAsync(() => _service.Profile()).ConfigureAwait(false));

    public async Task<IReadOnlyList<AccountDevice>> GetDevicesAsync() =>
        [.. (await CoreCall.RunAsync(() => _service.Devices()).ConfigureAwait(false)).Select(Mapping.Device)];

    public Task RemoveDeviceAsync(string deviceId)
    {
        ArgumentException.ThrowIfNullOrEmpty(deviceId);
        return CoreCall.RunAsync(() => _service.RemoveDevice(deviceId));
    }

    public async Task<ShareLimits> GetShareLimitsAsync() =>
        Mapping.Limits(await CoreCall.RunAsync(() => _service.ShareLimits()).ConfigureAwait(false));

    // A finished set's first visibleColumns columns and maxRows rows; totalRows is a table view's count, else null.
    // Columns is the sheet's choice per visible column, Keep for any it leaves out; the connection's rules mask on top.
    public async Task<CreatedShare> CreateShareAsync(
        ShareRequest request,
        ResultSet? rows = null,
        int visibleColumns = 0,
        long maxRows = 0,
        long? totalRows = null,
        IReadOnlyList<ShareColumnChoice>? columns = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentOutOfRangeException.ThrowIfNegative(visibleColumns);
        ArgumentOutOfRangeException.ThrowIfNegative(maxRows);
        var native = Mapping.Request(request);
        var set = rows?.Handle;
        var limit = (uint)Math.Min(maxRows, uint.MaxValue);
        ulong? total = totalRows is { } count ? checked((ulong)count) : null;
        Native.ShareColumnChoice[] choices = columns is null ? [] : [.. columns.Select(Mapping.Choice)];
        var created = await CoreCall.RunAsync(
                () => _service.CreateShare(native, set, checked((uint)visibleColumns), limit, total, choices))
            .ConfigureAwait(false);
        return Mapping.Created(created);
    }

    // The account's own links, or a team's with teamId, newest first, without their SQL.
    public async Task<SharePage> ListSharesAsync(bool liveOnly, string? teamId = null, string? cursor = null) =>
        Mapping.Page(
            await CoreCall.RunAsync(() => _service.ListShares(liveOnly, teamId, cursor)).ConfigureAwait(false));

    public Task RevokeShareAsync(string shareId)
    {
        ArgumentException.ThrowIfNullOrEmpty(shareId);
        return CoreCall.RunAsync(() => _service.RevokeShare(shareId));
    }

    // A new expiry from now; Free extends a link this way.
    public async Task<SharedLink> ExtendShareAsync(string shareId, ShareExpiry expiry)
    {
        ArgumentException.ThrowIfNullOrEmpty(shareId);
        var native = Mapping.Expiry(expiry);
        return Mapping.Link(await CoreCall.RunAsync(() => _service.ExtendShare(shareId, native)).ConfigureAwait(false));
    }

    // Works signed out. account.share_password_required asks for the password, account.share_password_wrong again.
    public async Task<PublicShare> FetchSharedAsync(string token, string? password = null)
    {
        ArgumentNullException.ThrowIfNull(token);
        var shared = await CoreCall.RunAsync(() => _service.FetchShared(token, password)).ConfigureAwait(false);
        return Mapping.Public(shared);
    }

    public void Dispose()
    {
        _disposed = true;
        _wake.Close();
        _service.Dispose();
    }
}

// The core calls it on a runtime thread; one slot holds every change not yet read.
internal sealed class AccountWake : Native.AccountListener
{
    private readonly Channel<bool> _signal = Channel.CreateBounded<bool>(
        new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
        });

    public void StatusChanged() => _signal.Writer.TryWrite(true);

    // False once the account is disposed and no change is left.
    public ValueTask<bool> WaitAsync(CancellationToken cancellationToken) =>
        _signal.Reader.WaitToReadAsync(cancellationToken);

    public void Take() => _signal.Reader.TryRead(out _);

    public void Close() => _signal.Writer.TryComplete();
}

internal sealed class AccountBrowserAdapter(IAccountBrowser browser) : Native.HostBrowser
{
    // An exception other than the declared one would end the call as a panic in the core.
    public void OpenUrl(string url)
    {
        bool opened;
        try
        {
            opened = browser.OpenAsync(new Uri(url)).GetAwaiter().GetResult();
        }
        catch (Exception exception)
        {
            throw new Native.HostBrowserException.Failed(exception.Message);
        }

        if (!opened)
        {
            throw new Native.HostBrowserException.Failed("the system did not open the page");
        }
    }
}
