using System.Net;
using TablePro.Interop;

namespace TablePro.App.Services;

// Where downloadable drivers are listed and fetched from. The core picks the release and checks the file; this
// only moves bytes. TABLEPRO_DRIVER_REGISTRY names another catalog, a path or URL, as for a local mirror.
internal static class DriverCatalog
{
    private static readonly Uri DefaultLocation = new("https://updates.tablepro.app/drivers/v1.json");
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(5) };

    public static Uri Location { get; } = Resolve();

    // The catalog's text, or null when none is published at this location yet.
    public static async Task<string?> FetchAsync(CancellationToken cancellationToken)
    {
        if (Location.IsFile)
        {
            return File.Exists(Location.LocalPath)
                ? await File.ReadAllTextAsync(Location.LocalPath, cancellationToken).ConfigureAwait(false)
                : null;
        }

        using var response = await Http.GetAsync(Location, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
    }

    // Into a temporary file the caller deletes; the core then checks it against the catalog's checksum.
    public static Task<string> DownloadAsync(AvailableDriver driver, CancellationToken cancellationToken) =>
        DownloadAsync(driver, cancellationToken, Http, Location, TimeSpan.FromMinutes(5), Path.GetTempPath());

    internal static async Task<string> DownloadAsync(
        AvailableDriver driver,
        CancellationToken cancellationToken,
        HttpClient http,
        Uri location,
        TimeSpan timeout,
        string directory)
    {
        ArgumentNullException.ThrowIfNull(driver);
        if (!Uri.TryCreate(location, driver.Url, out var source))
        {
            throw new InvalidOperationException("The driver's download URL is invalid.");
        }

        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        cancellationToken = deadline.Token;
        var target = Path.Combine(directory, $"tablepro-driver-{Guid.NewGuid():N}.dll");
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            // Only a catalog on this PC may name a file, and never a share: opening one sends the user's credentials.
            if (source.IsFile && location.IsFile && !source.IsUnc)
            {
                using var input = File.OpenRead(source.LocalPath);
                using var output = File.Create(target);
                await input.CopyToAsync(output, cancellationToken).ConfigureAwait(false);
                return target;
            }

            if (source.Scheme != Uri.UriSchemeHttps)
            {
                throw new InvalidOperationException($"A driver downloads over HTTPS only, not from {source}.");
            }

            using var response = await http.GetAsync(source, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            var file = File.Create(target);
            await using (file.ConfigureAwait(false))
            {
                await response.Content.CopyToAsync(file, cancellationToken).ConfigureAwait(false);
            }

            return target;
        }
        catch
        {
            File.Delete(target);
            throw;
        }
    }

    private static Uri Resolve()
    {
        var custom = Environment.GetEnvironmentVariable("TABLEPRO_DRIVER_REGISTRY");
        if (string.IsNullOrWhiteSpace(custom))
        {
            return DefaultLocation;
        }

        return Uri.TryCreate(custom, UriKind.Absolute, out var uri) ? uri : new Uri(Path.GetFullPath(custom));
    }
}
