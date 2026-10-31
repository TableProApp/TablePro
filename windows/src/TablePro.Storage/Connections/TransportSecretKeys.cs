using TablePro.Storage.Secrets;

namespace TablePro.Storage.Connections;

/// <summary>Credential Manager names for the secrets a connection's transport keeps, beside its password and SSH secret.</summary>
public static class TransportSecretKeys
{
    public static string ProxyPassword(Guid connectionId) => Key("proxy", connectionId);

    public static string CloudSqlServiceAccountKey(Guid connectionId) => Key("cloudsql-key", connectionId);

    public static string CloudflareTokenId(Guid connectionId) => Key("cloudflare-token-id", connectionId);

    public static string CloudflareTokenSecret(Guid connectionId) => Key("cloudflare-token-secret", connectionId);

    /// <summary>Every transport secret of a connection, for deleting them with it.</summary>
    public static IEnumerable<string> All(Guid connectionId) =>
        [ProxyPassword(connectionId), CloudSqlServiceAccountKey(connectionId), CloudflareTokenId(connectionId), CloudflareTokenSecret(connectionId)];

    private static string Key(string kind, Guid connectionId) => SecretKeys.Prefix + kind + "/" + connectionId.ToString("D");
}
