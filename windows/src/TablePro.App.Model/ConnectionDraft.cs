using System.Globalization;
using TablePro.Interop;

namespace TablePro.App.Model;

public enum FormField
{
    Host,
    Port,
    File,
    SshHost,
    SshPort,
    SshKey,
    ClientKey,
    Timeout,
}

public enum FieldProblem
{
    Required,
    NotANumber,
    OutOfRange,
    NotAbsolute,
}

public sealed record FieldError(FormField Field, FieldProblem Problem);

// Numbers stay text as typed, so Validate can name the field that does not parse.
public sealed class ConnectionDraft
{
    private SshSettings? _savedSsh;

    public Guid? Id { get; set; }

    public string EngineId { get; set; } = string.Empty;

    public bool IsFileEngine { get; set; }

    public bool SupportsClientIdentity { get; set; }

    public ServerNameOverride ServerNameOverride { get; set; } = ServerNameOverride.Unsupported;

    public string Name { get; set; } = string.Empty;

    public string Host { get; set; } = string.Empty;

    public string Port { get; set; } = string.Empty;

    public string Database { get; set; } = string.Empty;

    public string UserName { get; set; } = string.Empty;

    public bool IntegratedAuth { get; set; }

    // Left empty while editing, the stored password stays.
    public string Password { get; set; } = string.Empty;

    public bool UseSsh { get; set; }

    public string SshHost { get; set; } = string.Empty;

    public string SshPort { get; set; } = string.Empty;

    public string SshUserName { get; set; } = string.Empty;

    public SshAuthMethod SshAuth { get; set; } = SshAuthMethod.Agent;

    public string SshKeyPath { get; set; } = string.Empty;

    public string SshPassword { get; set; } = string.Empty;

    public TlsMode TlsMode { get; set; } = TlsMode.Disable;

    // A saved connection's mode was picked when it was saved; a new one follows the engine's default until the user picks.
    public bool TlsModeChosen { get; set; }

    public string CaFile { get; set; } = string.Empty;

    public string ServerName { get; set; } = string.Empty;

    public string ClientCertificate { get; set; } = string.Empty;

    public string ClientKey { get; set; } = string.Empty;

    public SafeMode SafeMode { get; set; } = SafeMode.Off;

    public string Timeout { get; set; } = string.Empty;

    public string? Color { get; set; }

    public Guid? GroupId { get; set; }

    public DateTimeOffset? LastOpened { get; set; }

    public bool IsNew => Id is null;

    public bool VerifiesCertificate => TlsMode is TlsMode.VerifyFull or TlsMode.Strict;

    public bool UsesClientIdentity => SupportsClientIdentity && TlsMode != TlsMode.Disable;

    // MySQL checks the host it dials, so another name works only where the dial goes through an SSH forward.
    public bool ShowsServerName => VerifiesCertificate && ServerNameOverride switch
    {
        ServerNameOverride.AnyRoute => true,
        ServerNameOverride.SshForwardOnly => UseSsh,
        _ => false,
    };

    public static ConnectionDraft New(DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(engine);
        return new ConnectionDraft
        {
            EngineId = engine.Id,
            IsFileEngine = engine.DefaultPort is null,
            SupportsClientIdentity = engine.SupportsClientIdentity,
            ServerNameOverride = engine.ServerNameOverride,
            Host = engine.DefaultPort is null ? string.Empty : "localhost",
            Port = engine.DefaultPort?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
            TlsMode = engine.NewConnectionTls(engine.DefaultPort),
        };
    }

    public static ConnectionDraft From(SavedConnection connection, DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(engine);
        return new ConnectionDraft
        {
            _savedSsh = connection.Ssh,
            Id = connection.Id,
            EngineId = connection.EngineId,
            IsFileEngine = engine.DefaultPort is null,
            SupportsClientIdentity = engine.SupportsClientIdentity,
            ServerNameOverride = engine.ServerNameOverride,
            Name = connection.Name,
            Host = connection.Host,
            Port = connection.Port > 0 ? connection.Port.ToString(CultureInfo.InvariantCulture) : string.Empty,
            Database = connection.Database,
            UserName = connection.UserName,
            IntegratedAuth = connection.IntegratedAuth,
            UseSsh = connection.Ssh is not null,
            SshHost = connection.Ssh?.Host ?? string.Empty,
            SshPort = connection.Ssh?.Port?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
            SshUserName = connection.Ssh?.UserName ?? string.Empty,
            SshAuth = connection.Ssh?.Auth ?? SshAuthMethod.Agent,
            SshKeyPath = connection.Ssh?.KeyPath ?? string.Empty,
            TlsMode = connection.Tls.Mode,
            TlsModeChosen = true,
            CaFile = connection.Tls.CaFile ?? string.Empty,
            ServerName = connection.Tls.ServerName ?? string.Empty,
            ClientCertificate = connection.Tls.ClientCertificate ?? string.Empty,
            ClientKey = connection.Tls.ClientKey ?? string.Empty,
            SafeMode = connection.SafeMode,
            Timeout = connection.QueryTimeoutSeconds?.ToString(CultureInfo.InvariantCulture) ?? string.Empty,
            Color = connection.Color,
            GroupId = connection.GroupId,
            LastOpened = connection.LastOpened,
        };
    }

    public void Apply(ParsedConnectionUrl url, DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(url);
        ArgumentNullException.ThrowIfNull(engine);
        EngineId = url.EngineId;
        IsFileEngine = engine.DefaultPort is null;
        SupportsClientIdentity = engine.SupportsClientIdentity;
        ServerNameOverride = engine.ServerNameOverride;
        Host = url.Host;
        Port = (url.Port ?? engine.DefaultPort)?.ToString(CultureInfo.InvariantCulture) ?? string.Empty;
        UserName = url.UserName;
        Password = url.Password ?? Password;
        Database = url.Database;
        // A mode the engine lacks, such as sslmode=prefer on SQL Server, leaves the engine's default.
        if (url.TlsMode is { } mode && engine.SupportedTlsModes.Contains(mode))
        {
            TlsMode = mode;
            TlsModeChosen = true;
        }
        else
        {
            TlsModeChosen = false;
            FollowTlsDefault(engine);
        }
    }

    public void FollowTlsDefault(DatabaseEngine engine)
    {
        ArgumentNullException.ThrowIfNull(engine);
        if (!TlsModeChosen || !engine.SupportedTlsModes.Contains(TlsMode))
        {
            TlsMode = engine.NewConnectionTls(ParsePort(Port));
            TlsModeChosen = false;
        }
    }

    public IReadOnlyList<FieldError> Validate()
    {
        var errors = new List<FieldError>();
        if (IsFileEngine)
        {
            if (string.IsNullOrWhiteSpace(Database))
            {
                errors.Add(new FieldError(FormField.File, FieldProblem.Required));
            }
            else if (!System.IO.Path.IsPathFullyQualified(Database.Trim()))
            {
                errors.Add(new FieldError(FormField.File, FieldProblem.NotAbsolute));
            }

            return errors;
        }

        if (string.IsNullOrWhiteSpace(Host))
        {
            errors.Add(new FieldError(FormField.Host, FieldProblem.Required));
        }

        CheckPort(errors, FormField.Port, Port, required: true);
        if (UseSsh)
        {
            if (string.IsNullOrWhiteSpace(SshHost))
            {
                errors.Add(new FieldError(FormField.SshHost, FieldProblem.Required));
            }

            CheckPort(errors, FormField.SshPort, SshPort, required: false);
            if (SshAuth == SshAuthMethod.PrivateKey && string.IsNullOrWhiteSpace(SshKeyPath))
            {
                errors.Add(new FieldError(FormField.SshKey, FieldProblem.Required));
            }
        }

        if (UsesClientIdentity && (string.IsNullOrWhiteSpace(ClientCertificate) != string.IsNullOrWhiteSpace(ClientKey)))
        {
            errors.Add(new FieldError(FormField.ClientKey, FieldProblem.Required));
        }

        if (!string.IsNullOrWhiteSpace(Timeout))
        {
            if (!int.TryParse(Timeout.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var seconds))
            {
                errors.Add(new FieldError(FormField.Timeout, FieldProblem.NotANumber));
            }
            else if (seconds > 86_400)
            {
                errors.Add(new FieldError(FormField.Timeout, FieldProblem.OutOfRange));
            }
        }

        return errors;
    }

    public string SuggestedName()
    {
        if (IsFileEngine)
        {
            var file = System.IO.Path.GetFileNameWithoutExtension(Database.Trim());
            return string.IsNullOrEmpty(file) ? EngineId : file;
        }

        var host = Host.Trim();
        var database = Database.Trim();
        return database.Length > 0 && host.Length > 0 ? $"{database}@{host}" : host.Length > 0 ? host : EngineId;
    }

    // Call after Validate found nothing.
    public SavedConnection ToConnection()
    {
        var name = string.IsNullOrWhiteSpace(Name) ? SuggestedName() : Name.Trim();
        if (IsFileEngine)
        {
            return new SavedConnection(
                Id, name, EngineId, string.Empty, 0, Database.Trim(), string.Empty, TlsSettings.Disabled,
                SafeMode, Color: Color, GroupId: GroupId, LastOpened: LastOpened);
        }

        return new SavedConnection(
            Id,
            name,
            EngineId,
            Host.Trim(),
            ParsePort(Port) ?? 0,
            Database.Trim(),
            UserName.Trim(),
            new TlsSettings(
                TlsMode,
                VerifiesCertificate ? Blank(CaFile) : null,
                UsesClientIdentity ? Blank(ClientCertificate) : null,
                UsesClientIdentity ? Blank(ClientKey) : null,
                ShowsServerName ? Blank(ServerName) : null),
            SafeMode,
            IntegratedAuth: IntegratedAuth,
            Ssh: UseSsh
                ? new SshSettings(
                    SshHost.Trim(),
                    ParsePort(SshPort),
                    Blank(SshUserName),
                    _savedSsh?.JumpHosts ?? [],
                    SshAuth,
                    SshAuth == SshAuthMethod.PrivateKey ? Blank(SshKeyPath) : null,
                    SshAuth == SshAuthMethod.PrivateKey && _savedSsh is { KeyHasPassphrase: true }
                        && string.Equals(_savedSsh.KeyPath, Blank(SshKeyPath), StringComparison.Ordinal))
                : null,
            QueryTimeoutSeconds: string.IsNullOrWhiteSpace(Timeout)
                ? null
                : int.Parse(Timeout.Trim(), NumberStyles.None, CultureInfo.InvariantCulture),
            Color: Color,
            GroupId: GroupId,
            LastOpened: LastOpened);
    }

    // A new connection saves even an empty password, for a server that takes none; an edit keeps the stored one.
    public ConnectionSecrets Secrets()
    {
        if (IsFileEngine)
        {
            return ConnectionSecrets.None;
        }

        var password = !IntegratedAuth && (IsNew || Password.Length > 0) ? Password : null;
        var sshPassword = UseSsh && SshAuth == SshAuthMethod.Password && (IsNew || SshPassword.Length > 0)
            ? SshPassword
            : null;
        return new ConnectionSecrets(password, sshPassword);
    }

    private static void CheckPort(List<FieldError> errors, FormField field, string text, bool required)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            if (required)
            {
                errors.Add(new FieldError(field, FieldProblem.Required));
            }

            return;
        }

        if (!int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var port))
        {
            errors.Add(new FieldError(field, FieldProblem.NotANumber));
        }
        else if (port is < 1 or > 65_535)
        {
            errors.Add(new FieldError(field, FieldProblem.OutOfRange));
        }
    }

    private static int? ParsePort(string text) =>
        int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var port) ? port : null;

    private static string? Blank(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}
