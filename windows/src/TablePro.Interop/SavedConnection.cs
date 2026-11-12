using System.Text;

namespace TablePro.Interop;

public enum TlsMode
{
    Disable,
    Prefer,
    Require,
    VerifyFull,
    Strict,
}

public enum SafeMode
{
    Off,
    ConfirmWrites,
    ReadOnly,
}

public enum SshAuthMethod
{
    Agent,
    PrivateKey,
    Password,
    KeyboardInteractive,
}

public sealed record TlsSettings(
    TlsMode Mode,
    string? CaFile = null,
    string? ClientCertificate = null,
    string? ClientKey = null,
    string? ServerName = null)
{
    public static TlsSettings Disabled { get; } = new(TlsMode.Disable);
}

public sealed record SshSettings(
    string Host,
    int? Port,
    string? UserName,
    IReadOnlyList<string> JumpHosts,
    SshAuthMethod Auth,
    string? KeyPath = null,
    bool KeyHasPassphrase = false);

// Saving keeps the core's fields this record leaves out. Id is null until saved; Database is a file engine's path.
public sealed record SavedConnection(
    Guid? Id,
    string Name,
    string EngineId,
    string Host,
    int Port,
    string Database,
    string UserName,
    TlsSettings Tls,
    SafeMode SafeMode = SafeMode.Off,
    bool IntegratedAuth = false,
    SshSettings? Ssh = null,
    int? QueryTimeoutSeconds = null,
    string? Color = null,
    Guid? GroupId = null,
    DateTimeOffset? LastOpened = null)
{
    // Read only: a save keeps the stored tags, which change through ConnectionLibrary.TagAsync.
    public IReadOnlyList<Guid> Tags { get; init; } = [];
}

// A null secret keeps what is stored; an empty one is stored as empty, for a server that takes none.
public sealed record ConnectionSecrets(
    string? DatabasePassword = null,
    string? SshPassword = null,
    string? SshPassphrase = null)
{
    public static ConnectionSecrets None { get; } = new();

    // A record's ToString prints every property, so a log line or an assert message would carry the passwords.
    private bool PrintMembers(StringBuilder builder)
    {
        builder.Append("DatabasePassword = ").Append(Redaction.Of(DatabasePassword));
        builder.Append(", SshPassword = ").Append(Redaction.Of(SshPassword));
        builder.Append(", SshPassphrase = ").Append(Redaction.Of(SshPassphrase));
        return true;
    }
}

public sealed record ConnectionGroup(Guid Id, string Name, Guid? ParentId, int Order, string? Color);

// A label several connections share. Color is one of the connection colours' ids.
public sealed record ConnectionTag(Guid Id, string Name, string Color);

// Connections come in each group's order, groups depth first in each parent's order, tags in the order they were made.
public sealed record LibrarySnapshot(
    IReadOnlyList<SavedConnection> Connections,
    IReadOnlyList<ConnectionGroup> Groups,
    IReadOnlyList<Guid> Favorites,
    IReadOnlyList<Guid> Recent)
{
    public IReadOnlyList<ConnectionTag> Tags { get; init; } = [];
}

public sealed record ImportSummary(int Added, int Updated);

public sealed record ParsedConnectionUrl(
    string EngineId,
    string Host,
    int? Port,
    string UserName,
    string? Password,
    string Database,
    TlsMode? TlsMode,
    string? CaFile = null,
    string? ClientCertificate = null,
    string? ClientKey = null,
    string? ServerName = null)
{
    private bool PrintMembers(StringBuilder builder)
    {
        builder.Append("EngineId = ").Append(EngineId);
        builder.Append(", Host = ").Append(Host);
        builder.Append(", Port = ").Append(Port);
        builder.Append(", UserName = ").Append(UserName);
        builder.Append(", Password = ").Append(Redaction.Of(Password));
        builder.Append(", Database = ").Append(Database);
        builder.Append(", TlsMode = ").Append(TlsMode);
        builder.Append(", CaFile = ").Append(CaFile);
        builder.Append(", ClientCertificate = ").Append(ClientCertificate);
        builder.Append(", ClientKey = ").Append(ClientKey);
        builder.Append(", ServerName = ").Append(ServerName);
        return true;
    }
}

// Null prints as nothing, as a record prints any null property.
internal static class Redaction
{
    public static string? Of(string? secret) => secret is null ? null : "[REDACTED]";
}
