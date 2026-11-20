using System.Net.Http;
using TablePro.App.Model;
using Windows.ApplicationModel;
using Windows.Management.Deployment;

namespace TablePro.App.Services;

internal abstract record UpdateState
{
    // Only an installed package has a package version and an App Installer file to follow.
    public sealed record Unsupported : UpdateState;

    public sealed record NotChecked : UpdateState;

    public sealed record Checking : UpdateState;

    public sealed record Current(DateTimeOffset CheckedAt) : UpdateState;

    public sealed record Available(string Version, DateTimeOffset CheckedAt) : UpdateState;

    public sealed record Installing(string Version, uint Percent) : UpdateState;

    // Installed without the restart ForceTargetAppShutdown asks for; Windows finishes it when the app closes.
    public sealed record ReadyToRestart(string Version) : UpdateState;

    public sealed record Failed(string Reason, DateTimeOffset CheckedAt) : UpdateState;
}

// Reads the App Installer file this install follows and installs the update it names (ADR 0020).
internal sealed class Updater
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    private Uri? _offered;
    private int _generation;

    public UpdateState State { get; private set; } =
        AppStorage.IsPackaged ? new UpdateState.NotChecked() : new UpdateState.Unsupported();

    // Raised on the UI thread after State changed.
    public event EventHandler? Changed;

    // The channel Settings shows: its own choice, else the channel of the file this install came from.
    public static UpdateChannel ChannelFor(UpdateChannel? chosen)
    {
        if (chosen is not null || !AppStorage.IsPackaged)
        {
            return chosen ?? UpdateChannel.Stable;
        }

        try
        {
            return UpdateFeeds.Effective(InstalledPackage().GetAppInstallerInfo()?.Uri, null);
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            return UpdateChannel.Stable;
        }
    }

    // On Package.Current itself the check fails with access denied (Package.CheckUpdateAvailabilityAsync, Remarks).
    private static Package InstalledPackage() =>
        new PackageManager().FindPackageForUser(string.Empty, Package.Current.Id.FullName);

    public static Uri ReleaseNotes(string version) =>
        new($"https://github.com/TableProApp/TablePro/releases/tag/windows-v{version}");

    public static Version PackageVersion()
    {
        var version = Package.Current.Id.Version;
        return new Version(version.Major, version.Minor, version.Build, version.Revision);
    }

    // A check started while another runs replaces it, so a channel changed mid-check reads the new channel's file.
    public async Task CheckAsync(UpdateChannel? channel)
    {
        if (State is UpdateState.Unsupported or UpdateState.Installing or UpdateState.ReadyToRestart)
        {
            return;
        }

        var generation = ++_generation;
        Set(new UpdateState.Checking());
        Finding finding;
        try
        {
            finding = await Task.Run(() => FindAsync(channel)).ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            // Whatever the network, the file or Windows throws, the check shows it; being offline is no bug to log.
            if (exception is not (HttpRequestException or TaskCanceledException))
            {
                CrashLog.Write(exception);
            }

            finding = new Finding(null, null, null, exception.Message);
        }

        if (generation != _generation)
        {
            return;
        }

        _offered = finding.File;
        Set(finding switch
        {
            { ProblemKey: { } key } => new UpdateState.Failed(Strings.Get(key), DateTimeOffset.Now),
            { Error: { } error } => new UpdateState.Failed(
                Strings.Format("UpdateCheckFailedReason", error), DateTimeOffset.Now),
            { Version: { } version } => new UpdateState.Available(version, DateTimeOffset.Now),
            _ => new UpdateState.Current(DateTimeOffset.Now),
        });
    }

    // ForceTargetAppShutdown closes the app through Restart Manager, which writes the session and starts the new
    // version (AppRestart); a call that returns without that leaves the new version for the next start.
    public async Task InstallAsync()
    {
        if (State is not UpdateState.Available available || _offered is not { } file)
        {
            return;
        }

        ++_generation;
        Set(new UpdateState.Installing(available.Version, 0));
        try
        {
            var manager = new PackageManager();
            var progress = new Progress<DeploymentProgress>(step =>
            {
                if (State is UpdateState.Installing installing)
                {
                    Set(installing with { Percent = step.percentage });
                }
            });
            var options = AddPackageByAppInstallerOptions.ForceTargetAppShutdown;
            await manager
                .AddPackageByAppInstallerFileAsync(file, options, manager.GetDefaultPackageVolume())
                .AsTask(progress)
                .ConfigureAwait(true);
            Set(new UpdateState.ReadyToRestart(available.Version));
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            Set(new UpdateState.Failed(exception.Message, DateTimeOffset.Now));
        }
    }

    // Off the UI thread, so a problem comes back as its resource key and CheckAsync words it.
    private static async Task<Finding> FindAsync(UpdateChannel? channel)
    {
        var package = InstalledPackage();
        var installedFrom = package.GetAppInstallerInfo()?.Uri;
        var file = UpdateFeeds.ToCheck(installedFrom, channel);
        var offer = UpdateOffer.Parse(await ReadAsync(file).ConfigureAwait(false));
        if (offer is null || !offer.IsFor(package.Id.Name, package.Id.Publisher))
        {
            return new Finding(null, null, offer is null ? "UpdateFileUnreadable" : "UpdateFileOtherPackage", null);
        }

        bool available;
        if (installedFrom is not null && file == installedFrom)
        {
            var result = await package.CheckUpdateAvailabilityAsync();
            if (result.Availability is not (PackageUpdateAvailability.Available or PackageUpdateAvailability.Required
                or PackageUpdateAvailability.NoUpdates))
            {
                throw new IOException(result.ExtendedError?.Message ?? result.Availability.ToString());
            }

            available = result.Availability != PackageUpdateAvailability.NoUpdates;
        }
        else
        {
            available = offer.Version > PackageVersion();
        }

        return available
            ? new Finding(ReleaseVersions.Display(offer.Version), file, null, null)
            : new Finding(null, null, null, null);
    }

    private static async Task<string> ReadAsync(Uri file) => file.IsFile
        ? await File.ReadAllTextAsync(file.LocalPath).ConfigureAwait(false)
        : await Http.GetStringAsync(file).ConfigureAwait(false);

    private sealed record Finding(string? Version, Uri? File, string? ProblemKey, string? Error);

    private void Set(UpdateState state)
    {
        if (state == State)
        {
            return;
        }

        State = state;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
