using System.Text.Json;
using TablePro.Core.Licensing;
using TablePro.Storage.Secrets;

namespace TablePro.Storage.Licensing;

/// <summary>
/// Keeps the license on disk: the license key in Credential Manager, and the signed payload in <c>license.json</c>.
/// The payload is not a secret, it is a signed blob whose signature is checked again at every start, so it lives in a
/// plain file as the macOS app keeps it in user defaults.
/// </summary>
public sealed class LicenseStore(string path, ISecretStore secrets)
{
    /// <summary>Where Credential Manager holds the license key.</summary>
    public const string KeySecret = SecretKeys.Prefix + "license/key";

    private readonly string _path = Path.GetFullPath(path);

    public LicenseStore(AppPaths paths, ISecretStore secrets)
        : this(Path.Combine(paths.Root, "license.json"), secrets)
    {
    }

    /// <summary>The cached license, or null when there is none or the file cannot be read as one.</summary>
    public async Task<License?> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            return await AtomicFile.ReadJsonAsync(_path, LicenseJson.License, null, cancellationToken);
        }
        catch (Exception ex) when (ex is JsonException or NotSupportedException or InvalidOperationException)
        {
            return null;
        }
    }

    public Task SaveAsync(License license, CancellationToken cancellationToken = default) =>
        AtomicFile.WriteJsonAsync(_path, license, LicenseJson.License, cancellationToken);

    public string? LoadKey() => secrets.Get(KeySecret);

    public void SaveKey(string key) => secrets.Set(KeySecret, key);

    /// <summary>Drops the key and the payload.</summary>
    public void Clear()
    {
        secrets.Delete(KeySecret);
        File.Delete(_path);
    }
}
