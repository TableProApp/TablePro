using System.Globalization;
using System.Text;
using TablePro.Core.Connections;

namespace TablePro.Storage.Connections;

/// <summary>A connection the import could not take, with the reason the UI shows next to its name.</summary>
public sealed record SkippedConnection(string Name, string Reason);

public sealed record ConnectionImportResult(
    IReadOnlyList<ConnectionProfile> Imported,
    IReadOnlyList<ConnectionGroup> CreatedGroups,
    IReadOnlyList<SkippedConnection> Skipped);

/// <summary>Maps profiles to and from the macOS app's portable bundle.</summary>
internal static class ConnectionPortability
{
    public const int SupportedFormatVersion = 1;

    // Keys the macOS app refuses on import, because they would run code or reach a credential the user never saw.
    private static readonly string[] BlockedAdditionalFieldKeys =
    [
        "postdisconnectscript", "preconnectscript", "pretunnelhost", "pretunnelport", "promptforpassword",
        "spendpoint", "sslclientkeypassphrase", "usepgpass",
    ];

    public static PortableConnectionFile Export(
        IEnumerable<ConnectionProfile> profiles,
        IReadOnlyList<ConnectionGroup> groups,
        string appVersion,
        DateTimeOffset now)
    {
        var groupsByKey = groups.ToDictionary(g => g.Key, StringComparer.OrdinalIgnoreCase);
        var file = new PortableConnectionFile
        {
            ExportedAt = new DateTime(now.UtcTicks - (now.UtcTicks % TimeSpan.TicksPerSecond), DateTimeKind.Utc),
            AppVersion = appVersion,
        };

        var usedGroups = new Dictionary<string, PortableGroup>(StringComparer.OrdinalIgnoreCase);
        foreach (var profile in profiles)
        {
            ConnectionGroup? group = null;
            if (profile.Group is { Length: > 0 } key)
            {
                group = groupsByKey.GetValueOrDefault(key) ?? groups.FirstOrDefault(g => string.Equals(g.Name, key, StringComparison.OrdinalIgnoreCase));
            }

            if (group is not null && !usedGroups.ContainsKey(group.Name))
            {
                usedGroups[group.Name] = new PortableGroup { Name = group.Name, Color = ColorName(group.Color) };
            }

            file.Connections.Add(ToPortable(profile, group?.Name));
        }

        file.Groups = usedGroups.Count == 0 ? null : [.. usedGroups.Values];
        return file;
    }

    public static ConnectionImportResult Import(PortableConnectionFile file, IReadOnlyList<ConnectionGroup> existingGroups)
    {
        if (file.FormatVersion > SupportedFormatVersion)
        {
            throw new InvalidDataException(
                string.Create(CultureInfo.InvariantCulture, $"This file uses connection format {file.FormatVersion}. TablePro for Windows reads format {SupportedFormatVersion}."));
        }

        var groupColors = new Dictionary<string, ConnectionColor>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in file.Groups ?? [])
        {
            if (!string.IsNullOrWhiteSpace(group.Name))
            {
                groupColors.TryAdd(group.Name.Trim(), ParseColor(group.Color));
            }
        }

        var groupsByName = new Dictionary<string, ConnectionGroup>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in existingGroups.Where(g => g.ParentId is null))
        {
            groupsByName.TryAdd(group.Name, group);
        }

        var created = new List<ConnectionGroup>();
        var imported = new List<ConnectionProfile>();
        var skipped = new List<SkippedConnection>();
        var nextGroupOrder = existingGroups.Count == 0 ? 0 : existingGroups.Max(g => g.SortOrder) + 1;

        foreach (var connection in file.Connections)
        {
            var name = string.IsNullOrWhiteSpace(connection.Name) ? "Imported connection" : connection.Name.Trim();
            if (ParseEngine(connection.Type) is not { } engine)
            {
                skipped.Add(new SkippedConnection(name, $"TablePro for Windows has no driver for {connection.Type}."));
                continue;
            }

            string? groupKey = null;
            if (connection.GroupName is { } groupName && !string.IsNullOrWhiteSpace(groupName))
            {
                groupName = groupName.Trim();
                if (!groupsByName.TryGetValue(groupName, out var group))
                {
                    group = new ConnectionGroup
                    {
                        Name = groupName,
                        Color = groupColors.GetValueOrDefault(groupName),
                        SortOrder = nextGroupOrder++,
                    };
                    groupsByName[groupName] = group;
                    created.Add(group);
                }

                groupKey = group.Key;
            }

            imported.Add(FromPortable(connection, name, engine, groupKey));
        }

        return new ConnectionImportResult(imported, created, skipped);
    }

    private static PortableConnection ToPortable(ConnectionProfile profile, string? groupName)
    {
        var descriptor = profile.Descriptor;
        return new PortableConnection
        {
            Name = profile.Name,
            Host = descriptor.IsFileBased ? string.Empty : profile.Host,
            Port = descriptor.IsFileBased ? 0 : profile.EffectivePort,
            Database = (descriptor.IsFileBased ? profile.FilePath : profile.Database) ?? string.Empty,
            Username = profile.Username ?? string.Empty,
            Type = EngineName(profile.Engine),
            SshConfig = profile.Ssh is { } ssh ? ToPortable(ssh) : null,
            SslConfig = descriptor.IsFileBased ? null : new PortableSslConfig { Mode = SslModeName(profile.SslMode) },
            Color = profile.Color == ConnectionColor.None ? null : ColorName(profile.Color),
            SafeModeLevel = SafeModeName(profile.SafeMode),
            AiPolicy = AiPolicyName(profile.AiPolicy),
            ConnectTimeoutSeconds = profile.ConnectTimeoutSeconds,
            AdditionalFields = profile.AdditionalOptions.Count == 0 ? null : new Dictionary<string, string>(profile.AdditionalOptions),
            StartupCommands = string.IsNullOrEmpty(profile.StartupCommands) ? null : profile.StartupCommands,
            GroupName = groupName,
        };
    }

    private static PortableSshConfig ToPortable(SshTunnelSettings ssh) => new()
    {
        Enabled = ssh.Enabled,
        Host = ssh.Host,
        Port = ssh.Port,
        Username = ssh.Username ?? string.Empty,
        AuthMethod = SshAuthName(ssh.AuthMethod),
        PrivateKeyPath = ssh.PrivateKeyPath ?? string.Empty,
        JumpHosts = JumpHostSpec.Parse(ssh.JumpHosts) is { Count: > 0 } hops
            ? [.. hops.Select(h => new PortableJumpHost { Host = h.Host, Port = h.Port, Username = h.User ?? string.Empty, AuthMethod = "SSH Agent" })]
            : null,
    };

    private static ConnectionProfile FromPortable(PortableConnection connection, string name, DatabaseEngine engine, string? groupKey)
    {
        var descriptor = EngineDescriptor.For(engine);
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (key, value) in connection.AdditionalFields ?? [])
        {
            var normalized = key.ToLowerInvariant();
            if (!BlockedAdditionalFieldKeys.Contains(normalized) && !normalized.StartsWith("aws", StringComparison.Ordinal))
            {
                options[key] = value;
            }
        }

        return new ConnectionProfile
        {
            Name = name,
            Engine = engine,
            Host = descriptor.IsFileBased || string.IsNullOrWhiteSpace(connection.Host) ? "localhost" : connection.Host.Trim(),
            Port = descriptor.IsFileBased || connection.Port <= 0 ? 0 : connection.Port,
            Database = descriptor.IsFileBased || string.IsNullOrEmpty(connection.Database) ? null : connection.Database,
            FilePath = descriptor.IsFileBased && !string.IsNullOrEmpty(connection.Database) ? connection.Database : null,
            Username = string.IsNullOrEmpty(connection.Username) ? null : connection.Username,
            SslMode = ParseSslMode(connection.SslConfig?.Mode) ?? SslMode.Preferred,
            SafeMode = ParseSafeMode(connection.SafeModeLevel),
            Color = ParseColor(connection.Color),
            Group = groupKey,
            ConnectTimeoutSeconds = connection.ConnectTimeoutSeconds is { } timeout ? Math.Clamp(timeout, 1, 600) : 15,
            Ssh = connection.SshConfig is { } ssh ? FromPortable(ssh) : null,
            AiPolicy = ParseAiPolicy(connection.AiPolicy),
            StartupCommands = string.IsNullOrEmpty(connection.StartupCommands) ? null : connection.StartupCommands,
            AdditionalOptions = options,
        };
    }

    private static SshTunnelSettings FromPortable(PortableSshConfig ssh)
    {
        var auth = ParseSshAuth(ssh.AuthMethod);
        var hops = ssh.JumpHosts is { Count: > 0 } list
            ? string.Join(',', list.Where(h => !string.IsNullOrWhiteSpace(h.Host)).Select(h => new JumpHostSpec(h.Username is { Length: > 0 } u ? u : null, h.Host.Trim(), h.Port).ToString()))
            : null;
        return new SshTunnelSettings
        {
            Enabled = ssh.Enabled,
            Host = ssh.Host.Trim(),
            Port = ssh.Port is > 0 and <= 65535 ? ssh.Port.Value : 22,
            Username = string.IsNullOrEmpty(ssh.Username) ? null : ssh.Username,
            AuthMethod = auth,
            PrivateKeyPath = string.IsNullOrEmpty(ssh.PrivateKeyPath) ? null : ssh.PrivateKeyPath,
            JumpHosts = string.IsNullOrEmpty(hops) ? null : hops,
        };
    }

    internal static string EngineName(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => "PostgreSQL",
        DatabaseEngine.MySql => "MySQL",
        DatabaseEngine.MariaDb => "MariaDB",
        DatabaseEngine.SqlServer => "SQL Server",
        DatabaseEngine.Sqlite => "SQLite",
        DatabaseEngine.DuckDb => "DuckDB",
        _ => engine.ToString(),
    };

    internal static DatabaseEngine? ParseEngine(string? type) => Squash(type) switch
    {
        "postgresql" or "postgres" => DatabaseEngine.PostgreSql,
        "mysql" => DatabaseEngine.MySql,
        "mariadb" => DatabaseEngine.MariaDb,
        "sqlserver" or "mssql" => DatabaseEngine.SqlServer,
        "sqlite" => DatabaseEngine.Sqlite,
        "duckdb" => DatabaseEngine.DuckDb,
        _ => null,
    };

    private static string SslModeName(SslMode mode) => mode switch
    {
        SslMode.Disabled => "Disabled",
        SslMode.Required => "Required",
        SslMode.VerifyCa => "Verify CA",
        SslMode.VerifyIdentity => "Verify Identity",
        _ => "Preferred",
    };

    // Reads the macOS, iOS and libpq spellings, as the macOS PortableSSLMode does.
    private static SslMode? ParseSslMode(string? mode) => Squash(mode) switch
    {
        "disabled" or "disable" => SslMode.Disabled,
        "preferred" or "prefer" => SslMode.Preferred,
        "required" or "require" => SslMode.Required,
        "verifyca" => SslMode.VerifyCa,
        "verifyidentity" or "verifyfull" => SslMode.VerifyIdentity,
        _ => null,
    };

    // The macOS reader maps these older level names onto its own three levels, so the finer Windows level survives a round trip.
    private static string SafeModeName(SafeModeLevel level) => level switch
    {
        SafeModeLevel.Silent => "silent",
        SafeModeLevel.Alert => "alert",
        SafeModeLevel.AlertFull => "alertFull",
        SafeModeLevel.SafeMode => "safeMode",
        SafeModeLevel.SafeModeFull => "safeModeFull",
        _ => "readOnly",
    };

    private static SafeModeLevel ParseSafeMode(string? level) => Squash(level) switch
    {
        null or "" or "silent" or "off" => SafeModeLevel.Silent,
        "alert" or "confirmwrites" => SafeModeLevel.Alert,
        "alertfull" => SafeModeLevel.AlertFull,
        "safemode" => SafeModeLevel.SafeMode,
        "safemodefull" => SafeModeLevel.SafeModeFull,
        "readonly" => SafeModeLevel.ReadOnly,
        _ => SafeModeLevel.Alert,
    };

    private static string AiPolicyName(AiPolicy policy) => policy switch
    {
        AiPolicy.Allow => "alwaysAllow",
        AiPolicy.Never => "never",
        _ => "askEachTime",
    };

    private static AiPolicy ParseAiPolicy(string? policy) => Squash(policy) switch
    {
        "alwaysallow" or "allow" => AiPolicy.Allow,
        "never" => AiPolicy.Never,
        _ => AiPolicy.AskEachTime,
    };

    private static string SshAuthName(SshAuthMethod method) => method switch
    {
        SshAuthMethod.Password => "Password",
        SshAuthMethod.PrivateKey => "Private Key",
        _ => "SSH Agent",
    };

    private static SshAuthMethod ParseSshAuth(string? method) => Squash(method) switch
    {
        "password" or "keyboardinteractive" => SshAuthMethod.Password,
        "privatekey" => SshAuthMethod.PrivateKey,
        _ => SshAuthMethod.Agent,
    };

    private static string? ColorName(ConnectionColor color) => color == ConnectionColor.None ? null : color.ToString();

    private static ConnectionColor ParseColor(string? color) =>
        Enum.TryParse<ConnectionColor>(color, ignoreCase: true, out var parsed) && Enum.IsDefined(parsed) ? parsed : ConnectionColor.None;

    /// <summary>Lowercases and drops spaces, hyphens and underscores, so every platform's spelling of a value compares equal.</summary>
    private static string? Squash(string? value)
    {
        if (value is null)
        {
            return null;
        }

        var builder = new StringBuilder(value.Length);
        foreach (var c in value)
        {
            if (!char.IsWhiteSpace(c) && c is not '-' and not '_')
            {
                builder.Append(char.ToLowerInvariant(c));
            }
        }

        return builder.ToString();
    }
}
