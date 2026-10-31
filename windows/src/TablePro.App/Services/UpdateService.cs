using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using TablePro.Core.Updates;
using Windows.ApplicationModel;

namespace TablePro.App.Services;

/// <summary>How this copy of TablePro was installed, which decides how it updates.</summary>
public enum UpdateInstallMode
{
    /// <summary>A Debug build, or a policy turned updates off.</summary>
    Disabled,

    /// <summary>Unzipped and run in place. The app offers the download page; it never rewrites a folder it did not install.</summary>
    Portable,

    /// <summary>Installed per user by <c>install.ps1</c>. The app downloads the zip and runs the script to replace itself.</summary>
    ScriptInstall,

    /// <summary>An MSIX opened directly. The app downloads the newer MSIX and hands it to App Installer.</summary>
    Msix,

    /// <summary>An MSIX installed from a <c>.appinstaller</c> file. Windows checks and installs; the app reports and restarts.</summary>
    AppInstaller,

    /// <summary>Installed from the Microsoft Store, which owns updates.</summary>
    Store,
}

public enum UpdateState
{
    Idle,
    Checking,
    UpToDate,
    Available,
    Downloading,
    Installing,
    Failed,
}

/// <summary>
/// Checks <see cref="FeedUri"/> for a newer release on launch, once a day while the app runs, and when the user asks,
/// as Sparkle does on macOS: stable and beta channels, phased rollouts, skipped versions and critical releases. It
/// downloads over HTTPS, checks the size and SHA-256 the feed published, then starts the installer and quits.
/// A packaged install defers to App Installer or the Store, which own its updates.
/// </summary>
/// <remarks>
/// <see cref="Changed"/> is raised on the synchronization context the service was created on, the UI thread in the
/// app, so a handler can touch controls directly.
/// </remarks>
public sealed partial class UpdateService : IDisposable
{
    /// <summary>The feed the release workflow publishes, next to the macOS appcast.</summary>
    public static readonly Uri DefaultFeedUri = new("https://updates.tablepro.app/windows/feed.json");

    /// <summary>The page a portable copy opens, where every Windows release is listed.</summary>
    public static readonly Uri ReleasesPage = new("https://github.com/TableProApp/TablePro/releases");

    private const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\TablePro";
    private const string PolicyKey = @"Software\Policies\TablePro";
    private const int MaxFeedBytes = 1024 * 1024;
    private const int AppModelErrorNoPackage = 15700;
    private static readonly TimeSpan FeedTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan LaunchDelay = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan ScheduleTick = TimeSpan.FromHours(1);

    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly string _preferencesFile;
    private readonly string _downloadDirectory;
    private readonly Func<Task<bool>> _canQuit;
    private readonly Action _quit;
    private readonly SynchronizationContext? _context;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly CancellationTokenSource _lifetime = new();

    /// <param name="dataRoot">The app's data folder, <c>%LOCALAPPDATA%\TablePro</c>, where the preferences and downloads go.</param>
    /// <param name="canQuit">Asks every window to close, as quitting does, and answers false when the user keeps one open.</param>
    /// <param name="quit">Ends the process once the installer is running.</param>
    /// <param name="http">A client for tests; the app passes none and the service makes its own.</param>
    public UpdateService(string dataRoot, Func<Task<bool>> canQuit, Action quit, HttpClient? http = null)
    {
        _preferencesFile = Path.Combine(dataRoot, "updates.json");
        _downloadDirectory = Path.Combine(dataRoot, "updates");
        _canQuit = canQuit;
        _quit = quit;
        _context = SynchronizationContext.Current;
        CurrentVersion = ReadCurrentVersion();
        FeedUri = FeedOverride() ?? DefaultFeedUri;
        Mode = DetectMode(FeedUri != DefaultFeedUri);
        _ownsHttp = http is null;
        _http = http ?? CreateHttpClient(CurrentVersion);
        Preferences = LoadPreferences(_preferencesFile);
    }

    public event EventHandler? Changed;

    public Uri FeedUri { get; }

    public UpdateInstallMode Mode { get; }

    public AppVersion CurrentVersion { get; }

    public UpdatePreferences Preferences { get; private set; }

    public UpdateState State { get; private set; }

    /// <summary>The release the last check found, or null. For an App Installer package it may be null while <see cref="State"/> is Available.</summary>
    public UpdateOffer? Available { get; private set; }

    /// <summary>The download's progress from 0 to 1 while <see cref="State"/> is Downloading.</summary>
    public double DownloadProgress { get; private set; }

    public string? LastError { get; private set; }

    public bool CanCheck => Mode is not (UpdateInstallMode.Disabled or UpdateInstallMode.Store);

    /// <summary>
    /// False for an App Installer package: its channel is the <c>.appinstaller</c> file it came from, so the
    /// Settings page shows the channel instead of a picker.
    /// </summary>
    public bool CanChooseChannel => Mode is UpdateInstallMode.Portable or UpdateInstallMode.ScriptInstall or UpdateInstallMode.Msix;

    /// <summary>The menu item's title, which says when an update is waiting, as the macOS app menu does.</summary>
    public string CheckForUpdatesTitle => State == UpdateState.Available ? Strings.Get("Updates/MenuUpdateAvailable") : Strings.Get("Updates/MenuCheckForUpdates");

    /// <summary>One line for the Settings page about where updates stand.</summary>
    public string StatusText => State switch
    {
        _ when Mode == UpdateInstallMode.Disabled => Strings.Get("Updates/StatusDisabled"),
        _ when Mode == UpdateInstallMode.Store => Strings.Get("Updates/StatusStore"),
        UpdateState.Checking => Strings.Get("Updates/StatusChecking"),
        UpdateState.Available when Available is { } offer => Strings.Format("Updates/AvailableVersion", offer.Version, CurrentVersion),
        UpdateState.Available => Strings.Get("Updates/StatusAvailable"),
        UpdateState.Downloading => Strings.Format("Updates/StatusDownloading", DownloadProgress),
        UpdateState.Installing => Strings.Get("Updates/StatusInstalling"),
        UpdateState.Failed => Strings.Format("Updates/StatusFailed", LastError),
        UpdateState.UpToDate => Strings.Format("Updates/StatusUpToDate", CurrentVersion),
        _ when Preferences.LastCheck is { } last => Strings.Format("Updates/StatusLastChecked", last.ToLocalTime()),
        _ => Strings.Format("Updates/StatusVersion", CurrentVersion),
    };

    /// <summary>
    /// Starts the schedule: a first check shortly after launch when one is due, then a look every hour for the next.
    /// It returns at once; the checks run in the background until the service is disposed.
    /// </summary>
    public void Start()
    {
        if (!CanCheck)
        {
            return;
        }

        RemoveOldDownloads();
        _ = RunScheduleAsync(_lifetime.Token);
    }

    /// <summary>
    /// Reads the feed and records what it offers. A scheduled check (<paramref name="userInitiated"/> false) follows
    /// the rollout phases and the skipped version; a check the user asks for ignores both, as Sparkle does.
    /// </summary>
    public async Task<UpdateOffer?> CheckAsync(bool userInitiated, CancellationToken cancellationToken = default)
    {
        if (!CanCheck)
        {
            return null;
        }

        if (!await _gate.WaitAsync(userInitiated ? Timeout.InfiniteTimeSpan : TimeSpan.Zero, cancellationToken))
        {
            return Available;
        }

        try
        {
            SetState(UpdateState.Checking);
            var preferences = Preferences.RolloutGroup is null
                ? Preferences with { RolloutGroup = Random.Shared.Next(UpdateSelector.RolloutGroupCount) }
                : Preferences;

            var packageHasUpdate = Mode == UpdateInstallMode.AppInstaller && await PackageHasUpdateAsync();
            UpdateOffer? offer = null;
            try
            {
                var feed = await FetchFeedAsync(cancellationToken);
                offer = UpdateSelector.Select(feed, Criteria(preferences, userInitiated));
            }
            catch (Exception ex) when (Mode == UpdateInstallMode.AppInstaller && IsNetworkOrFeedError(ex))
            {
                // Windows already answered for the package; the feed only adds the version and notes.
            }

            await SavePreferencesAsync(preferences with { LastCheck = DateTimeOffset.UtcNow });
            Available = offer;
            LastError = null;
            SetState(offer is not null || packageHasUpdate ? UpdateState.Available : UpdateState.UpToDate);
            return offer;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            SetState(UpdateState.Idle);
            throw;
        }
        catch (Exception ex) when (IsNetworkOrFeedError(ex))
        {
            LastError = ex.Message;
            SetState(UpdateState.Failed);
            return null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SetChannelAsync(UpdateChannel channel)
    {
        if (channel == Preferences.Channel)
        {
            return;
        }

        // A new channel deserves a fresh look, as Sparkle resets its update cycle when the beta setting changes.
        await SavePreferencesAsync(Preferences with { Channel = channel, SkippedVersion = null });
        Available = null;
        SetState(UpdateState.Idle);
        _ = CheckAsync(userInitiated: false, _lifetime.Token);
    }

    public Task SetAutomaticallyChecksAsync(bool enabled) =>
        SavePreferencesAsync(Preferences with { AutomaticallyChecks = enabled });

    /// <summary>Keeps scheduled checks quiet about this version until a newer one ships. A critical release ignores it.</summary>
    public async Task SkipAsync(UpdateOffer offer)
    {
        await SavePreferencesAsync(Preferences with { SkippedVersion = offer.Version.ToString() });
        Available = null;
        SetState(UpdateState.Idle);
    }

    /// <summary>
    /// Installs the offered release the way this installation updates: it downloads and verifies the file, asks the
    /// windows to close, starts the installer and quits. A portable copy opens the download page instead, and an
    /// App Installer package restarts so Windows applies the update it found.
    /// </summary>
    public async Task InstallAsync(UpdateOffer? offer, CancellationToken cancellationToken = default)
    {
        switch (Mode)
        {
            case UpdateInstallMode.Disabled:
                return;
            case UpdateInstallMode.Store:
                OpenUri(new Uri("ms-windows-store://downloadsandupdates"));
                return;
            case UpdateInstallMode.Portable:
                OpenUri(offer?.Item.ReleaseNotesUrl ?? ReleasesPage);
                return;
            case UpdateInstallMode.AppInstaller:
                await RestartIntoAppInstallerAsync();
                return;
        }

        ArgumentNullException.ThrowIfNull(offer);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var file = await DownloadAsync(offer.Asset, cancellationToken);
            if (!await _canQuit())
            {
                SetState(UpdateState.Available);
                return;
            }

            SetState(UpdateState.Installing);
            if (Mode == UpdateInstallMode.ScriptInstall)
            {
                StartInstallScript(file, offer);
            }
            else
            {
                // App Installer opens the package and replaces the running version once the app has quit.
                Process.Start(new ProcessStartInfo(file) { UseShellExecute = true })?.Dispose();
            }

            _quit();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            SetState(UpdateState.Available);
            throw;
        }
        catch (Exception ex) when (IsNetworkOrFeedError(ex) || ex is System.ComponentModel.Win32Exception)
        {
            LastError = ex.Message;
            SetState(UpdateState.Failed);
        }
        finally
        {
            _gate.Release();
        }
    }

    public void Dispose()
    {
        // The gate is left to the collector: a scheduled check may still be leaving it, and a SemaphoreSlim whose
        // wait handle was never read holds nothing to release.
        _lifetime.Cancel();
        _lifetime.Dispose();
        if (_ownsHttp)
        {
            _http.Dispose();
        }
    }

    private async Task RunScheduleAsync(CancellationToken cancellationToken)
    {
        try
        {
            // The first windows and the stores load before the network is touched.
            await Task.Delay(LaunchDelay, cancellationToken);
            using var timer = new PeriodicTimer(ScheduleTick);
            do
            {
                if (Preferences.IsCheckDue(DateTimeOffset.UtcNow) && State is not (UpdateState.Downloading or UpdateState.Installing))
                {
                    await CheckAsync(userInitiated: false, cancellationToken);
                }
            }
            while (await timer.WaitForNextTickAsync(cancellationToken));
        }
        catch (OperationCanceledException)
        {
        }
    }

    private UpdateCriteria Criteria(UpdatePreferences preferences, bool userInitiated) => new()
    {
        CurrentVersion = CurrentVersion,
        Channel = preferences.Channel,
        Architecture = RuntimeInformation.ProcessArchitecture,
        AssetKind = Mode == UpdateInstallMode.ScriptInstall || Mode == UpdateInstallMode.Portable ? UpdateAssetKind.Zip : UpdateAssetKind.Msix,
        WindowsBuild = Environment.OSVersion.Version.Build,
        Now = DateTimeOffset.UtcNow,
        RolloutGroup = preferences.RolloutGroup ?? 0,
        UserInitiated = userInitiated,
        SkippedVersion = preferences.Skipped,
    };

    private async Task<UpdateFeed> FetchFeedAsync(CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(FeedTimeout);
        using var response = await _http.GetAsync(FeedUri, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        EnsureHttps(response);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength > MaxFeedBytes)
        {
            throw new InvalidDataException(Strings.Get("Updates/ErrorFeedTooLarge"));
        }

        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var reader = new StreamReader(new LimitedStream(stream, MaxFeedBytes));
        return UpdateFeed.Parse(await reader.ReadToEndAsync(timeout.Token));
    }

    private async Task<string> DownloadAsync(UpdateAsset asset, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_downloadDirectory);
        var name = Path.GetFileName(asset.Url.AbsolutePath);
        if (string.IsNullOrEmpty(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            name = asset.Kind == UpdateAssetKind.Zip ? "TablePro-update.zip" : "TablePro-update.msix";
        }

        var target = Path.Combine(_downloadDirectory, name);
        if (File.Exists(target) && await FileMatchesAsync(target, asset, cancellationToken))
        {
            return target;
        }

        DownloadProgress = 0;
        SetState(UpdateState.Downloading);
        var partial = target + ".partial";
        using (var response = await _http.GetAsync(asset.Url, HttpCompletionOption.ResponseHeadersRead, cancellationToken))
        {
            EnsureHttps(response);
            response.EnsureSuccessStatusCode();
            await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
            await using var destination = new FileStream(partial, FileMode.Create, FileAccess.Write, FileShare.None, 81920, useAsync: true);
            var buffer = new byte[81920];
            long received = 0;
            var reported = -1;
            int read;
            while ((read = await source.ReadAsync(buffer, cancellationToken)) > 0)
            {
                received += read;
                if (received > asset.Size)
                {
                    break;
                }

                await destination.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                var percent = (int)(received * 100 / asset.Size);
                if (percent != reported)
                {
                    reported = percent;
                    DownloadProgress = percent / 100.0;
                    RaiseChanged();
                }
            }
        }

        if (!await FileMatchesAsync(partial, asset, cancellationToken))
        {
            File.Delete(partial);
            throw new InvalidDataException(Strings.Get("Updates/ErrorChecksumMismatch"));
        }

        File.Move(partial, target, overwrite: true);
        return target;
    }

    private static async Task<bool> FileMatchesAsync(string path, UpdateAsset asset, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true);
        return await UpdateDownload.MatchesAsync(stream, asset, cancellationToken);
    }

    /// <summary>
    /// Unpacks the verified zip beside the download and runs its install.ps1, which waits for this process to end,
    /// replaces the installed files and starts the new version.
    /// </summary>
    private void StartInstallScript(string zip, UpdateOffer offer)
    {
        var staging = Path.Combine(_downloadDirectory, offer.Version + "-" + offer.Asset.Architecture.ToString().ToLowerInvariant());
        if (Directory.Exists(staging))
        {
            Directory.Delete(staging, recursive: true);
        }

        // ExtractToDirectory refuses an entry that would land outside the folder.
        ZipFile.ExtractToDirectory(zip, staging);
        var script = Directory.EnumerateFiles(staging, "install.ps1", SearchOption.AllDirectories).FirstOrDefault()
            ?? throw new InvalidDataException(Strings.Get("Updates/ErrorNoInstallScript"));

        // The full path keeps a powershell.exe earlier on PATH from running instead.
        var powershell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        var start = new ProcessStartInfo(powershell)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetTempPath(),
        };
        foreach (var argument in new[]
        {
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script,
            "-InstallDir", AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar),
            "-WaitForProcessId", Environment.ProcessId.ToString(CultureInfo.InvariantCulture),
            "-Launch", "-Quiet",
        })
        {
            start.ArgumentList.Add(argument);
        }

        Process.Start(start)?.Dispose();
    }

    private static async Task<bool> PackageHasUpdateAsync()
    {
        var result = await Package.Current.CheckUpdateAvailabilityAsync();
        return result.Availability is PackageUpdateAvailability.Available or PackageUpdateAvailability.Required;
    }

    /// <summary>
    /// The .appinstaller file asks Windows to check on every launch and prompt, so a restart is how the update the
    /// check found gets applied. If the restart is refused, the .appinstaller link opens App Installer directly.
    /// </summary>
    private async Task RestartIntoAppInstallerAsync()
    {
        if (!await _canQuit())
        {
            return;
        }

        SetState(UpdateState.Installing);
        var failure = Microsoft.Windows.AppLifecycle.AppInstance.Restart(string.Empty);
        LastError = failure.ToString();
        if (Package.Current.GetAppInstallerInfo()?.Uri is { } source)
        {
            OpenUri(source);
        }

        SetState(UpdateState.Failed);
    }

    private void RemoveOldDownloads()
    {
        try
        {
            if (Directory.Exists(_downloadDirectory))
            {
                Directory.Delete(_downloadDirectory, recursive: true);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The install script of the update that just ran may still be closing; the next launch tries again.
        }
    }

    private async Task SavePreferencesAsync(UpdatePreferences preferences)
    {
        Preferences = preferences;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_preferencesFile)!);
            var temporary = _preferencesFile + ".tmp";
            await File.WriteAllTextAsync(temporary, preferences.Serialize());
            File.Move(temporary, _preferencesFile, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Losing the file costs one extra check; the choice still holds for this session.
            CrashLog.Write("Saving update preferences failed", ex);
        }

        RaiseChanged();
    }

    private static UpdatePreferences LoadPreferences(string path)
    {
        try
        {
            return UpdatePreferences.Deserialize(File.Exists(path) ? File.ReadAllText(path) : null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new UpdatePreferences();
        }
    }

    private void SetState(UpdateState state)
    {
        State = state;
        RaiseChanged();
    }

    private void RaiseChanged()
    {
        if (_context is null || SynchronizationContext.Current == _context)
        {
            Changed?.Invoke(this, EventArgs.Empty);
        }
        else
        {
            _context.Post(_ => Changed?.Invoke(this, EventArgs.Empty), null);
        }
    }

    private static void OpenUri(Uri uri) =>
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })?.Dispose();

    // A redirect from HTTPS to plain HTTP is refused by HttpClient already; this also covers a feed URL override.
    private static void EnsureHttps(HttpResponseMessage response)
    {
        if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
        {
            throw new HttpRequestException(Strings.Get("Updates/ErrorHttpsOnly"));
        }
    }

    private static bool IsNetworkOrFeedError(Exception ex) =>
        ex is HttpRequestException or TaskCanceledException or FormatException or IOException or InvalidDataException
            or UnauthorizedAccessException or COMException;

    private static AppVersion ReadCurrentVersion()
    {
        var informational = (Assembly.GetEntryAssembly() ?? typeof(UpdateService).Assembly)
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        return AppVersion.TryParse(informational, out var version) ? version : default;
    }

    private static HttpClient CreateHttpClient(AppVersion version)
    {
        var client = new HttpClient(new SocketsHttpHandler
        {
            AutomaticDecompression = System.Net.DecompressionMethods.All,
            PooledConnectionLifetime = TimeSpan.FromMinutes(10),
        })
        {
            // Each call carries its own deadline; a large download on a slow line must not hit a global one.
            Timeout = Timeout.InfiniteTimeSpan,
        };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("TablePro", version.ToString()));
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue($"(Windows; {RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()})"));
        return client;
    }

    /// <summary><c>TABLEPRO_UPDATE_FEED</c> points a build at a test feed, and turns updates on in a Debug build to try them.</summary>
    private static Uri? FeedOverride() =>
        Uri.TryCreate(Environment.GetEnvironmentVariable("TABLEPRO_UPDATE_FEED"), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
            ? uri
            : null;

    private static UpdateInstallMode DetectMode(bool feedOverridden)
    {
        // A Debug build shares the installed app's data folder, and an update would replace it with a release.
        if ((IsDebugBuild && !feedOverridden) || PolicyDisablesUpdates())
        {
            return UpdateInstallMode.Disabled;
        }

        if (IsPackaged())
        {
            var package = Package.Current;
            if (package.SignatureKind == PackageSignatureKind.Store)
            {
                return UpdateInstallMode.Store;
            }

            return package.GetAppInstallerInfo() is null ? UpdateInstallMode.Msix : UpdateInstallMode.AppInstaller;
        }

        return IsScriptInstalled() ? UpdateInstallMode.ScriptInstall : UpdateInstallMode.Portable;
    }

    /// <summary>
    /// <c>HKLM\Software\Policies\TablePro</c> or the same key under HKCU, value <c>DisableUpdates</c> = 1, turns updates
    /// off, the Windows counterpart of a managed <c>SUEnableAutomaticChecks</c> on macOS.
    /// </summary>
    private static bool PolicyDisablesUpdates()
    {
        foreach (var hive in new[] { Registry.LocalMachine, Registry.CurrentUser })
        {
            using var key = hive.OpenSubKey(PolicyKey);
            if (key?.GetValue("DisableUpdates") is int value && value != 0)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>install.ps1 records the folder it installed to; running from that folder means the script owns it.</summary>
    private static bool IsScriptInstalled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(UninstallKey);
        if (key?.GetValue("InstallLocation") is not string location || string.IsNullOrWhiteSpace(location))
        {
            return false;
        }

        static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar);
        return string.Equals(Normalize(location), Normalize(AppContext.BaseDirectory), StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsPackaged()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) != AppModelErrorNoPackage;
    }

#if DEBUG
    private static bool IsDebugBuild => true;
#else
    private static bool IsDebugBuild => false;
#endif

    [LibraryImport("kernel32.dll")]
    private static partial int GetCurrentPackageFullName(ref uint packageFullNameLength, IntPtr packageFullName);

    /// <summary>Stops a feed response at a size no real feed reaches, whatever the server claims.</summary>
    private sealed class LimitedStream(Stream inner, long limit) : Stream
    {
        private long _read;

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => throw new NotSupportedException();

        public override long Position { get => _read; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

        public override int Read(Span<byte> buffer)
        {
            var read = inner.Read(buffer);
            return Count(read);
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = await inner.ReadAsync(buffer, cancellationToken);
            return Count(read);
        }

        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        private int Count(int read)
        {
            _read += read;
            return _read > limit ? throw new InvalidDataException(Strings.Get("Updates/ErrorFeedTooLarge")) : read;
        }
    }
}
