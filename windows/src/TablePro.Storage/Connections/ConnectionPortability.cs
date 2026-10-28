using System.Globalization;
using System.Text;
using TablePro.Core.Connections;

namespace TablePro.Storage.Connections;

/// <summary>A connection the import could not take, with the reason the UI shows next to its name.</summary>
public sealed record SkippedConnection(string Name, string Reason);

/// <summary>The secrets that travel with a connection inside an encrypted export.</summary>
public sealed record ConnectionSecrets
{
    public string? Password { get; init; }

    /// <summary>The SSH password, or the private key's passphrase, as the app keeps one SSH secret per connection.</summary>
    public string? SshSecret { get; init; }

    public bool IsEmpty => string.IsNullOrEmpty(Password) && string.IsNullOrEmpty(SshSecret);
}

/// <summary>A saved query from a format 2 file, for the favorites library. The folder path runs from the top.</summary>
public sealed record ImportedSavedQuery(string Name, string Sql, string? Keyword, IReadOnlyList<string> FolderPath, Guid? ConnectionId);

public sealed record ConnectionImportResult(
    IReadOnlyList<ConnectionProfile> Imported,
    IReadOnlyList<ConnectionGroup> CreatedGroups,
    IReadOnlyList<SkippedConnection> Skipped)
{
    /// <summary>Secrets from an encrypted file, by the new profile's id, for the caller to put in the credential vault.</summary>
    public IReadOnlyDictionary<Guid, ConnectionSecrets> Secrets { get; init; } = new Dictionary<Guid, ConnectionSecrets>();

    public IReadOnlyList<ImportedSavedQuery> SavedQueries { get; init; } = [];

    /// <summary>
    /// Connections whose tunnel command came in turned off: it names a program to run, so the user reviews it in the
    /// connection form before it ever starts, as the macOS import asks first.
    /// </summary>
    public IReadOnlyList<string> TunnelCommandsToReview { get; init; } = [];
}

/// <summary>Maps profiles to and from the macOS app's portable bundle, format 1 and format 2.</summary>
internal static class ConnectionPortability
{
    public const int SupportedFormatVersion = 2;

    // Keys the macOS app refuses on import, because they would run code or reach a credential the user never saw.
    private static readonly string[] BlockedAdditionalFieldKeys =
    [
        "postdisconnectscript", "preconnectscript", "pretunnelhost", "pretunnelport", "promptforpassword",
        "spendpoint", "sslclientkeypassphrase", "usepgpass",
    ];

    // macOS plugin fields that the Windows profile holds in typed settings, or that no Windows driver reads. Kept out
    // of AdditionalOptions, which go to the driver as connection string keywords.
    private static readonly string[] MacOnlyFieldKeys =
    [
        "connecttimeoutseconds", "querytimeoutseconds", "mssqlauthmethod", "mssqlschema", "mssqlkerberosprincipal",
        "entratenantid", "entraclientid", "entraaccount", "kerberosprincipal", "gssencryptionmode", "enablecleartextplugin",
    ];

    public static PortableConnectionFile Export(
        IEnumerable<ConnectionProfile> profiles,
        IReadOnlyList<ConnectionGroup> groups,
        string appVersion,
        DateTimeOffset now,
        Func<ConnectionProfile, ConnectionSecrets?>? secrets = null)
    {
        var list = profiles.ToList();
        var groupsById = groups.GroupBy(g => g.Id).ToDictionary(g => g.Key, g => g.First());
        var chains = list.Select(p => GroupChain(FindGroup(p, groups), groupsById)).ToList();

        // Format 1 when it holds everything, so older builds on either platform still open the file, as macOS does.
        var usedTopLevel = chains.Where(c => c.Count == 1).Select(c => c[0]).Distinct().ToList();
        var fitsFormat1 = chains.All(c => c.Count <= 1)
            && usedTopLevel.Select(g => g.Name.Trim()).Distinct(StringComparer.OrdinalIgnoreCase).Count() == usedTopLevel.Count;

        var file = new PortableConnectionFile
        {
            FormatVersion = fitsFormat1 ? 1 : 2,
            ExportedAt = new DateTime(now.UtcTicks - (now.UtcTicks % TimeSpan.TicksPerSecond), DateTimeKind.Utc),
            AppVersion = appVersion,
        };

        var credentials = new Dictionary<string, PortableCredentials>(StringComparer.Ordinal);
        var groupRefs = new Dictionary<Guid, string>();
        var portableGroups = new List<PortableGroup>();
        for (var i = 0; i < list.Count; i++)
        {
            var profile = list[i];
            var chain = chains[i];
            var connection = ToPortable(profile);
            var reference = (i + 1).ToString(CultureInfo.InvariantCulture);
            if (fitsFormat1)
            {
                connection.GroupName = chain.Count == 1 ? chain[0].Name : null;
                foreach (var group in chain.Where(g => groupRefs.TryAdd(g.Id, g.Name)))
                {
                    portableGroups.Add(new PortableGroup { Name = group.Name, Color = ColorName(group.Color) });
                }
            }
            else
            {
                connection.Ref = reference;
                string? parentRef = null;
                foreach (var group in chain)
                {
                    if (!groupRefs.TryGetValue(group.Id, out var groupRef))
                    {
                        groupRef = "g" + (groupRefs.Count + 1).ToString(CultureInfo.InvariantCulture);
                        groupRefs[group.Id] = groupRef;
                        portableGroups.Add(new PortableGroup { Ref = groupRef, Name = group.Name, Color = ColorName(group.Color), ParentRef = parentRef });
                    }

                    parentRef = groupRef;
                }

                connection.GroupRef = parentRef;
            }

            if (secrets?.Invoke(profile) is { IsEmpty: false } secret)
            {
                // Format 1 keys credentials by position from zero, format 2 by ref.
                credentials[fitsFormat1 ? i.ToString(CultureInfo.InvariantCulture) : reference] = ToPortable(secret, profile.Ssh);
            }

            file.Connections.Add(connection);
        }

        file.Groups = portableGroups.Count == 0 ? null : portableGroups;
        file.Credentials = credentials.Count == 0 ? null : credentials;
        return file;
    }

    /// <param name="file">The parsed file.</param>
    /// <param name="existingGroups">The groups already saved, which imported connections join by name.</param>
    /// <param name="includeCredentials">Whether the file was encrypted; a plain file's credentials are ignored, as on macOS.</param>
    public static ConnectionImportResult Import(PortableConnectionFile file, IReadOnlyList<ConnectionGroup> existingGroups, bool includeCredentials = false)
    {
        if (file.FormatVersion < 1)
        {
            throw new InvalidDataException("This file is not a valid TablePro export.");
        }

        if (file.FormatVersion > SupportedFormatVersion)
        {
            throw new InvalidDataException(
                string.Create(CultureInfo.InvariantCulture, $"This file requires a newer version of TablePro (format version {file.FormatVersion})."));
        }

        var isFormat2 = file.FormatVersion >= 2;
        if (isFormat2 && ConnectionBundleValidation.FirstViolation(file) is { } violation)
        {
            throw new InvalidDataException("This file is not a valid TablePro export: " + violation + ".");
        }

        var groups = new GroupResolver(existingGroups);
        var paths = isFormat2 ? Format2GroupPaths(file) : null;
        var format1Colors = isFormat2 ? null : Format1GroupColors(file);
        var profilesByName = new Dictionary<string, PortableCredentialProfile>(StringComparer.OrdinalIgnoreCase);
        var profilesByRef = new Dictionary<string, PortableCredentialProfile>(StringComparer.Ordinal);
        foreach (var credentialProfile in file.CredentialProfiles ?? [])
        {
            profilesByName.TryAdd(credentialProfile.Name.Trim(), credentialProfile);
            if (credentialProfile.Ref is { } profileRef)
            {
                profilesByRef.TryAdd(profileRef, credentialProfile);
            }
        }

        var imported = new List<ConnectionProfile>();
        var skipped = new List<SkippedConnection>();
        var secrets = new Dictionary<Guid, ConnectionSecrets>();
        var review = new List<string>();
        var idsByRef = new Dictionary<string, Guid>(StringComparer.Ordinal);

        for (var index = 0; index < file.Connections.Count; index++)
        {
            var connection = file.Connections[index];
            var name = string.IsNullOrWhiteSpace(connection.Name) ? "Imported connection" : connection.Name.Trim();
            if (ParseEngine(connection.Type) is not { } engine)
            {
                skipped.Add(new SkippedConnection(name, $"TablePro for Windows has no driver for {connection.Type}."));
                continue;
            }

            IReadOnlyList<(string Name, ConnectionColor Color)> path = isFormat2
                ? connection.GroupRef is { } groupRef ? paths![groupRef] : []
                : connection.GroupName is { } groupName && !string.IsNullOrWhiteSpace(groupName)
                    ? [(groupName.Trim(), format1Colors!.GetValueOrDefault(groupName.Trim()))]
                    : [];

            var credentialProfile = isFormat2
                ? connection.CredentialProfileRef is { } profileRef ? profilesByRef.GetValueOrDefault(profileRef) : null
                : connection.CredentialProfileName is { } profileName ? profilesByName.GetValueOrDefault(profileName.Trim()) : null;

            var profile = FromPortable(connection, name, engine, groups.Resolve(path), credentialProfile);
            imported.Add(profile);
            if (connection.Ref is { } connectionRef)
            {
                idsByRef[connectionRef] = profile.Id;
            }

            if (profile.TunnelCommand is not null)
            {
                review.Add(profile.Name);
            }

            var credentialKey = isFormat2 ? connection.Ref : index.ToString(CultureInfo.InvariantCulture);
            if (includeCredentials && credentialKey is not null && file.Credentials?.GetValueOrDefault(credentialKey) is { } stored
                && FromPortable(stored, profile.Ssh) is { IsEmpty: false } secret)
            {
                secrets[profile.Id] = secret;
            }
        }

        return new ConnectionImportResult(imported, groups.Created, skipped)
        {
            Secrets = secrets,
            SavedQueries = isFormat2 ? SavedQueries(file, idsByRef) : [],
            TunnelCommandsToReview = review,
        };
    }

    private static ConnectionGroup? FindGroup(ConnectionProfile profile, IReadOnlyList<ConnectionGroup> groups)
    {
        if (profile.Group is not { Length: > 0 } key)
        {
            return null;
        }

        return groups.FirstOrDefault(g => string.Equals(g.Key, key, StringComparison.OrdinalIgnoreCase))
            ?? groups.FirstOrDefault(g => string.Equals(g.Name, key, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>The group and its ancestors, from the top down. A parent loop ends the walk.</summary>
    private static List<ConnectionGroup> GroupChain(ConnectionGroup? group, Dictionary<Guid, ConnectionGroup> groupsById)
    {
        var chain = new List<ConnectionGroup>();
        var seen = new HashSet<Guid>();
        for (var current = group; current is not null && seen.Add(current.Id) && chain.Count < ConnectionBundleValidation.MaximumNestingDepth;
             current = current.ParentId is { } parent ? groupsById.GetValueOrDefault(parent) : null)
        {
            chain.Insert(0, current);
        }

        return chain;
    }

    private static Dictionary<string, ConnectionColor> Format1GroupColors(PortableConnectionFile file)
    {
        var colors = new Dictionary<string, ConnectionColor>(StringComparer.OrdinalIgnoreCase);
        foreach (var group in file.Groups ?? [])
        {
            if (!string.IsNullOrWhiteSpace(group.Name))
            {
                colors.TryAdd(group.Name.Trim(), ParseColor(group.Color));
            }
        }

        return colors;
    }

    /// <summary>Each format 2 group's path of names from the top, which validation has proved finite.</summary>
    private static Dictionary<string, IReadOnlyList<(string Name, ConnectionColor Color)>> Format2GroupPaths(PortableConnectionFile file)
    {
        var byRef = (file.Groups ?? []).ToDictionary(g => g.Ref!, StringComparer.Ordinal);
        var paths = new Dictionary<string, IReadOnlyList<(string, ConnectionColor)>>(StringComparer.Ordinal);
        foreach (var start in byRef.Keys)
        {
            var path = new List<(string, ConnectionColor)>();
            for (var current = byRef[start]; ; current = byRef[current.ParentRef!])
            {
                path.Insert(0, (string.IsNullOrWhiteSpace(current.Name) ? "Imported" : current.Name.Trim(), ParseColor(current.Color)));
                if (current.ParentRef is null)
                {
                    break;
                }
            }

            paths[start] = path;
        }

        return paths;
    }

    private static List<ImportedSavedQuery> SavedQueries(PortableConnectionFile file, Dictionary<string, Guid> idsByRef)
    {
        var folders = (file.QueryFolders ?? []).ToDictionary(f => f.Ref, StringComparer.Ordinal);
        var result = new List<ImportedSavedQuery>();
        foreach (var query in file.SavedQueries ?? [])
        {
            var path = new List<string>();
            for (var folder = query.FolderRef is { } folderRef ? folders[folderRef] : null; folder is not null;
                 folder = folder.ParentRef is { } parent ? folders[parent] : null)
            {
                path.Insert(0, folder.Name);
            }

            Guid? connectionId = query.ConnectionRef is { } connectionRef && idsByRef.TryGetValue(connectionRef, out var id) ? id : null;
            result.Add(new ImportedSavedQuery(query.Name, query.Sql, string.IsNullOrWhiteSpace(query.Keyword) ? null : query.Keyword, path, connectionId));
        }

        return result;
    }

    private static PortableConnection ToPortable(ConnectionProfile profile)
    {
        var descriptor = profile.Descriptor;
        var fields = new Dictionary<string, string>(profile.AdditionalOptions);
        foreach (var (key, value) in AuthFields(profile))
        {
            fields[key] = value;
        }

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
            AdditionalFields = fields.Count == 0 ? null : fields,
            StartupCommands = string.IsNullOrEmpty(profile.StartupCommands) ? null : profile.StartupCommands,
            TunnelCommand = profile.TunnelCommand is { Enabled: true } command ? ToPortable(command) : null,
        };
    }

    /// <summary>The sign-in in the macOS app's field names. AWS fields are left out: macOS drops every aws key on import.</summary>
    private static IEnumerable<KeyValuePair<string, string>> AuthFields(ConnectionProfile profile)
    {
        if (profile.Engine != DatabaseEngine.SqlServer)
        {
            yield break;
        }

        var method = profile.EffectiveSignIn();
        yield return new("mssqlAuthMethod", method switch
        {
            SignInMethod.WindowsIntegrated => "windows",
            SignInMethod.EntraId => "entra",
            _ => "sql",
        });
        if (method == SignInMethod.EntraId && profile.Auth is { } auth)
        {
            if (!string.IsNullOrWhiteSpace(auth.EntraTenantId))
            {
                yield return new("entraTenantId", auth.EntraTenantId.Trim());
            }

            if (!string.IsNullOrWhiteSpace(auth.EntraClientId))
            {
                yield return new("entraClientId", auth.EntraClientId.Trim());
            }
        }
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

    private static PortableTunnelCommand ToPortable(TunnelCommandSettings command) => new()
    {
        Method = command.Method switch
        {
            TunnelCommandMethod.Kubectl => "kubectl",
            TunnelCommandMethod.AwsSsm => "awsSSM",
            _ => "custom",
        },
        Command = command.Command,
        ExecutablePath = command.ExecutablePath,
        KubernetesNamespace = command.KubernetesNamespace,
        KubernetesResource = command.KubernetesResource,
        KubernetesContext = command.KubernetesContext,
        AwsTarget = command.AwsTarget,
        AwsProfile = command.AwsProfile,
        AwsRegion = command.AwsRegion,
    };

    private static PortableCredentials ToPortable(ConnectionSecrets secrets, SshTunnelSettings? ssh) => new()
    {
        Password = secrets.Password,
        SshPassword = ssh?.AuthMethod == SshAuthMethod.Password ? secrets.SshSecret : null,
        KeyPassphrase = ssh?.AuthMethod == SshAuthMethod.Password ? null : secrets.SshSecret,
    };

    private static ConnectionSecrets FromPortable(PortableCredentials credentials, SshTunnelSettings? ssh) => new()
    {
        Password = credentials.Password,
        SshSecret = ssh?.AuthMethod == SshAuthMethod.Password
            ? credentials.SshPassword ?? credentials.KeyPassphrase
            : credentials.KeyPassphrase ?? credentials.SshPassword,
    };

    private static ConnectionProfile FromPortable(PortableConnection connection, string name, DatabaseEngine engine, string? groupKey, PortableCredentialProfile? credentialProfile)
    {
        var descriptor = EngineDescriptor.For(engine);
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        var macFields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (key, value) in connection.AdditionalFields ?? [])
        {
            var normalized = key.ToLowerInvariant();
            if (BlockedAdditionalFieldKeys.Contains(normalized) || normalized.StartsWith("aws", StringComparison.Ordinal))
            {
                continue;
            }

            if (MacOnlyFieldKeys.Contains(normalized))
            {
                macFields[key] = value;
            }
            else
            {
                options[key] = value;
            }
        }

        var username = string.IsNullOrEmpty(connection.Username) ? credentialProfile?.Username : connection.Username;
        return new ConnectionProfile
        {
            Name = name,
            Engine = engine,
            Host = descriptor.IsFileBased || string.IsNullOrWhiteSpace(connection.Host) ? "localhost" : connection.Host.Trim(),
            Port = descriptor.IsFileBased || connection.Port <= 0 ? 0 : connection.Port,
            Database = descriptor.IsFileBased || string.IsNullOrEmpty(connection.Database) ? null : connection.Database,
            FilePath = descriptor.IsFileBased && !string.IsNullOrEmpty(connection.Database) ? connection.Database : null,
            Username = string.IsNullOrEmpty(username) ? null : username,
            SslMode = ParseSslMode(connection.SslConfig?.Mode) ?? SslMode.Preferred,
            SafeMode = ParseSafeMode(connection.SafeModeLevel),
            Color = ParseColor(connection.Color),
            Group = groupKey,
            ConnectTimeoutSeconds = connection.ConnectTimeoutSeconds is { } timeout and >= 1 and <= 600 ? timeout : 15,
            Ssh = connection.SshConfig is { } ssh ? FromPortable(ssh) : null,
            AiPolicy = ParseAiPolicy(connection.AiPolicy),
            StartupCommands = string.IsNullOrEmpty(connection.StartupCommands) ? null : connection.StartupCommands,
            AdditionalOptions = options,
            Auth = AuthFromFields(engine, macFields),
            TunnelCommand = connection.TunnelCommand is { } command ? FromPortable(command) : null,
        };
    }

    private static ConnectionAuthSettings? AuthFromFields(DatabaseEngine engine, Dictionary<string, string> fields)
    {
        if (engine != DatabaseEngine.SqlServer || !fields.TryGetValue("mssqlAuthMethod", out var method))
        {
            return null;
        }

        return Squash(method) switch
        {
            "windows" => new ConnectionAuthSettings { Method = SignInMethod.WindowsIntegrated },

            // The macOS app signs in to Entra with the device code flow only.
            "entra" => new ConnectionAuthSettings
            {
                Method = SignInMethod.EntraId,
                EntraMode = EntraAuthMode.DeviceCode,
                EntraTenantId = fields.GetValueOrDefault("entraTenantId") is { Length: > 0 } tenant ? tenant : null,
                EntraClientId = fields.GetValueOrDefault("entraClientId") is { Length: > 0 } client ? client : null,
            },
            _ => null,
        };
    }

    /// <summary>Imported turned off: the user turns it on in the form after reading what it runs.</summary>
    private static TunnelCommandSettings FromPortable(PortableTunnelCommand command) => new()
    {
        Enabled = false,
        Method = Squash(command.Method) switch
        {
            "kubectl" => TunnelCommandMethod.Kubectl,
            "awsssm" => TunnelCommandMethod.AwsSsm,
            _ => TunnelCommandMethod.Custom,
        },
        Command = command.Command,
        ExecutablePath = command.ExecutablePath,
        KubernetesNamespace = command.KubernetesNamespace,
        KubernetesResource = command.KubernetesResource,
        KubernetesContext = command.KubernetesContext,
        AwsTarget = command.AwsTarget,
        AwsProfile = command.AwsProfile,
        AwsRegion = command.AwsRegion,
    };

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

    // The macOS DatabaseType raw values. PGlite, Elasticsearch, Typesense and SAP HANA have none there; the Mac skips them.
    private static readonly (DatabaseEngine Engine, string Name)[] EngineNames =
    [
        (DatabaseEngine.PostgreSql, "PostgreSQL"), (DatabaseEngine.MySql, "MySQL"), (DatabaseEngine.MariaDb, "MariaDB"),
        (DatabaseEngine.SqlServer, "SQL Server"), (DatabaseEngine.Sqlite, "SQLite"), (DatabaseEngine.DuckDb, "DuckDB"),
        (DatabaseEngine.Redis, "Redis"), (DatabaseEngine.MongoDb, "MongoDB"), (DatabaseEngine.ClickHouse, "ClickHouse"),
        (DatabaseEngine.Oracle, "Oracle"), (DatabaseEngine.Cassandra, "Cassandra"), (DatabaseEngine.ScyllaDb, "ScyllaDB"),
        (DatabaseEngine.CockroachDb, "CockroachDB"), (DatabaseEngine.Redshift, "Redshift"), (DatabaseEngine.TiDb, "TiDB"),
        (DatabaseEngine.OceanBase, "OceanBase"), (DatabaseEngine.Databend, "Databend"), (DatabaseEngine.PGlite, "PGlite"),
        (DatabaseEngine.LibSql, "libSQL"), (DatabaseEngine.Turso, "Turso"), (DatabaseEngine.Snowflake, "Snowflake"),
        (DatabaseEngine.BigQuery, "BigQuery"), (DatabaseEngine.Trino, "Trino"), (DatabaseEngine.Spanner, "Spanner"),
        (DatabaseEngine.Teradata, "Teradata"), (DatabaseEngine.DynamoDb, "DynamoDB"), (DatabaseEngine.Elasticsearch, "Elasticsearch"),
        (DatabaseEngine.Typesense, "Typesense"), (DatabaseEngine.Weaviate, "Weaviate"), (DatabaseEngine.Kafka, "Kafka"),
        (DatabaseEngine.Etcd, "etcd"), (DatabaseEngine.SurrealDb, "SurrealDB"), (DatabaseEngine.CloudflareD1, "Cloudflare D1"),
        (DatabaseEngine.CloudflareR2Sql, "Cloudflare R2 SQL"), (DatabaseEngine.Dameng, "Dameng"), (DatabaseEngine.SapHana, "SAP HANA"),
        (DatabaseEngine.Beancount, "Beancount"),
    ];

    internal static string EngineName(DatabaseEngine engine)
    {
        foreach (var (candidate, name) in EngineNames)
        {
            if (candidate == engine)
            {
                return name;
            }
        }

        return engine.ToString();
    }

    internal static DatabaseEngine? ParseEngine(string? type)
    {
        var squashed = Squash(type);
        if (string.IsNullOrEmpty(squashed))
        {
            return null;
        }

        foreach (var (engine, name) in EngineNames)
        {
            if (Squash(name) == squashed)
            {
                return engine;
            }
        }

        return squashed switch
        {
            "postgres" => DatabaseEngine.PostgreSql,
            "mssql" => DatabaseEngine.SqlServer,
            "amazonredshift" => DatabaseEngine.Redshift,
            "dm8" or "damengdm8" => DatabaseEngine.Dameng,
            "saphana" or "hana" => DatabaseEngine.SapHana,
            _ => null,
        };
    }

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

    /// <summary>Finds or creates the groups an imported connection's path names, matching existing ones by parent and name.</summary>
    private sealed class GroupResolver
    {
        private readonly List<ConnectionGroup> _all;
        private int _nextOrder;

        public GroupResolver(IReadOnlyList<ConnectionGroup> existing)
        {
            _all = [.. existing];
            _nextOrder = existing.Count == 0 ? 0 : existing.Max(g => g.SortOrder) + 1;
        }

        public List<ConnectionGroup> Created { get; } = [];

        public string? Resolve(IReadOnlyList<(string Name, ConnectionColor Color)> path)
        {
            ConnectionGroup? parent = null;
            foreach (var (name, color) in path)
            {
                var parentId = parent?.Id;
                var match = _all.FirstOrDefault(g => g.ParentId == parentId && string.Equals(g.Name, name, StringComparison.OrdinalIgnoreCase));
                if (match is null)
                {
                    match = new ConnectionGroup { Name = name, Color = color, ParentId = parentId, SortOrder = _nextOrder++ };
                    _all.Add(match);
                    Created.Add(match);
                }

                parent = match;
            }

            return parent?.Key;
        }
    }
}
