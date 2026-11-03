using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// AbiVersion is the driver ABI both sides speak once it loaded; Error says why it did not.
public sealed record InstalledDriver(string Id, string Name, string Version, string Path, string? AbiVersion, CoreError? Error)
{
    public bool IsLoaded => Error is null;
}

// A catalog entry with a release for this computer's processor; the app downloads Url and hands the file back.
public sealed record AvailableDriver(string Id, string Name, string Version, string Url, string Sha256);

// Drivers the user adds, kept in the data folder and loaded once their signature checks out (core ADR 0004).
public sealed class DriverPlugins : IDisposable
{
    private readonly Native.DriverPlugins _plugins;

    internal DriverPlugins(Native.DriverPlugins plugins)
    {
        _plugins = plugins;
    }

    public static IReadOnlyList<AvailableDriver> Available(string catalog)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        return [.. CoreCall.Run(() => Native.CoreMethods.AvailableDrivers(catalog))
            .Select(driver => new AvailableDriver(driver.Id, driver.Name, driver.Version, driver.Url, driver.Sha256))];
    }

    // The first call loads every installed driver, so it can take a moment.
    public async Task<IReadOnlyList<InstalledDriver>> GetInstalledAsync()
    {
        var drivers = await CoreCall.RunAsync(() => _plugins.Installed()).ConfigureAwait(false);
        return [.. drivers.Select(Map)];
    }

    // A driver with the same id is replaced; the one it replaces stays loaded until the app quits.
    public async Task<InstalledDriver> InstallFileAsync(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        return Map(await CoreCall.RunAsync(() => _plugins.InstallFile(path)).ConfigureAwait(false));
    }

    // path is the file downloaded from the release Available listed for id in the same catalog.
    public async Task<InstalledDriver> InstallReleaseAsync(string catalog, string id, string path)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(id);
        ArgumentNullException.ThrowIfNull(path);
        return Map(await CoreCall.RunAsync(() => _plugins.InstallRelease(catalog, id, path)).ConfigureAwait(false));
    }

    public Task RemoveAsync(string id)
    {
        ArgumentNullException.ThrowIfNull(id);
        return CoreCall.RunAsync(() => _plugins.Remove(id));
    }

    public void Dispose() => _plugins.Dispose();

    private static InstalledDriver Map(Native.InstalledDriverInfo driver) => new(
        driver.Id,
        driver.DisplayName,
        driver.Version,
        driver.Path,
        driver.Abi,
        driver.Error is { } error ? Mapping.Error(error) : null);
}
