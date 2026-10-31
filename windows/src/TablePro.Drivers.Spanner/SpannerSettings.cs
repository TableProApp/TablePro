using System.Globalization;
using Google.Cloud.Spanner.Data;
using TablePro.Core.Drivers;
using TablePro.Drivers.Spanner.Localization;

namespace TablePro.Drivers.Spanner;

/// <summary>
/// What a Spanner session reads from the form: Host as <c>projects/p/instances/i/databases/d</c>, or AdditionalOptions
/// <c>project</c> and <c>instance</c> with Database as the database; FilePath as a credentials JSON file (empty uses
/// Application Default Credentials); AdditionalOptions <c>emulatorHost</c> (<c>localhost:9010</c>) for the emulator
/// and <c>databaseRole</c> for fine-grained access control.
/// </summary>
public sealed record SpannerSettings(string DatabasePath, string? CredentialsFile, string? EmulatorHost, int EmulatorPort, string? DatabaseRole)
{
    public const string ProjectOption = "project";
    public const string InstanceOption = "instance";
    public const string DatabaseOption = "database";
    public const string EmulatorHostOption = "emulatorHost";
    public const string DatabaseRoleOption = "databaseRole";

    public bool UsesEmulator => EmulatorHost is not null;

    /// <summary>The database id, the last segment of the path.</summary>
    public string DatabaseId => DatabasePath[(DatabasePath.LastIndexOf('/') + 1)..];

    public static SpannerSettings From(ConnectionRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var host = profile.Host?.Trim() ?? string.Empty;
        var database = Option(options, DatabaseOption) ?? (string.IsNullOrWhiteSpace(request.Database) ? null : request.Database.Trim());

        string path;
        if (host.StartsWith("projects/", StringComparison.Ordinal))
        {
            path = host.TrimEnd('/');
            if (!path.Contains("/databases/", StringComparison.Ordinal) && database is not null)
            {
                path = string.Concat(path, "/databases/", database);
            }
        }
        else
        {
            var project = Option(options, ProjectOption) ?? throw new ArgumentException(SpannerStrings.Get("Spanner/MissingProject"));
            var instance = Option(options, InstanceOption) ?? throw new ArgumentException(SpannerStrings.Get("Spanner/MissingInstance"));
            path = $"projects/{project}/instances/{instance}/databases/{database ?? throw new ArgumentException(SpannerStrings.Get("Spanner/MissingDatabase"))}";
        }

        var segments = path.Split('/');
        if (segments.Length != 6 || segments[0] != "projects" || segments[2] != "instances" || segments[4] != "databases" || segments.Any(string.IsNullOrWhiteSpace))
        {
            throw new ArgumentException(SpannerStrings.Format("Spanner/NotADatabasePath", path), nameof(request));
        }

        string? emulatorHost = null;
        var emulatorPort = 9010;
        if (Option(options, EmulatorHostOption) is { } emulator)
        {
            var text = emulator.Contains("://", StringComparison.Ordinal) ? new Uri(emulator).Authority : emulator;
            var colon = text.LastIndexOf(':');
            if (colon > 0 && int.TryParse(text[(colon + 1)..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var port))
            {
                emulatorHost = text[..colon];
                emulatorPort = port;
            }
            else
            {
                emulatorHost = text;
            }
        }

        return new SpannerSettings(
            path,
            string.IsNullOrWhiteSpace(profile.FilePath) ? null : profile.FilePath.Trim(),
            emulatorHost,
            emulatorPort,
            Option(options, DatabaseRoleOption));
    }

    /// <summary>The emulator speaks plain gRPC without credentials, so it gets an endpoint and no credentials file.</summary>
    public SpannerConnectionStringBuilder ToConnectionStringBuilder()
    {
        var builder = new SpannerConnectionStringBuilder { DataSource = DatabasePath };
        if (UsesEmulator)
        {
            builder.Host = EmulatorHost;
            builder.Port = EmulatorPort;
        }
        else if (CredentialsFile is not null)
        {
            builder.CredentialFile = CredentialsFile;
        }

        if (DatabaseRole is not null)
        {
            builder.DatabaseRole = DatabaseRole;
        }

        return builder;
    }


    private static string? Option(IReadOnlyDictionary<string, string> options, string key)
    {
        foreach (var (name, value) in options)
        {
            if (string.Equals(name, key, StringComparison.OrdinalIgnoreCase) && !string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }

        return null;
    }
}
