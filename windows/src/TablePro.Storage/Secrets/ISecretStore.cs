using System.Collections.Concurrent;

namespace TablePro.Storage.Secrets;

/// <summary>
/// Passwords, passphrases and API keys, kept out of every JSON file. Calls are synchronous because the
/// Credential Manager answers from a local service in well under a millisecond.
/// </summary>
public interface ISecretStore
{
    string? Get(string key);

    void Set(string key, string secret);

    /// <returns>False when there was nothing stored under <paramref name="key"/>.</returns>
    bool Delete(string key);
}

/// <summary>The names secrets are stored under. They show in Windows' Credential Manager, so they read as TablePro's.</summary>
public static class SecretKeys
{
    public const string Prefix = "TablePro/";

    public static string Connection(Guid connectionId) => Prefix + "connection/" + connectionId.ToString("D");

    /// <summary>The SSH password, or the passphrase of the profile's private key.</summary>
    public static string Ssh(Guid connectionId) => Prefix + "ssh/" + connectionId.ToString("D");

    public static string Ai(string provider)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(provider);
        return Prefix + "ai/" + provider.ToLowerInvariant();
    }
}

/// <summary>A process-local store for tests and for builds that must not touch the user's vault.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly ConcurrentDictionary<string, string> _secrets = new(StringComparer.OrdinalIgnoreCase);

    public int Count => _secrets.Count;

    public string? Get(string key)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        return _secrets.TryGetValue(key, out var secret) ? secret : null;
    }

    public void Set(string key, string secret)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        ArgumentNullException.ThrowIfNull(secret);
        _secrets[key] = secret;
    }

    public bool Delete(string key)
    {
        ArgumentException.ThrowIfNullOrEmpty(key);
        return _secrets.TryRemove(key, out _);
    }
}
