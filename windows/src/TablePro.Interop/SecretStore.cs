using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

/// <summary>
/// The platform's secret store, which the app implements over the Windows Credential Manager. The core calls
/// it on a thread of its own and lets it block. A failure the user can act on is a
/// <see cref="SecretStoreException"/>; any other exception reaches the core as <see cref="SecretStoreFailure.Failed"/>.
/// </summary>
public interface ISecretStore
{
    string? Load(Guid connectionId, SecretKind kind);

    void Store(Guid connectionId, SecretKind kind, string secret, string label);

    void Relabel(Guid connectionId, SecretKind kind, string label);

    void Delete(Guid connectionId, SecretKind kind);

    void DeleteConnection(Guid connectionId);

    string? LoadItem(SecretItem item);

    /// <summary>The app names the item in its own words.</summary>
    void StoreItem(SecretItem item, string secret);

    void DeleteItem(SecretItem item);
}

public enum SecretKind
{
    DatabasePassword,
    SshPassword,
    SshPassphrase,
}

/// <summary>A secret no connection owns.</summary>
public enum SecretItem
{
    McpToken,
    AnthropicKey,
    OpenAIKey,
    OpenAICompatibleKey,
}

public enum SecretStoreFailure
{
    Unavailable,
    Locked,

    /// <summary>The user dismissed the unlock prompt.</summary>
    Dismissed,
    Failed,
}

public sealed class SecretStoreException : Exception
{
    public SecretStoreException(SecretStoreFailure failure, string message)
        : base(message)
    {
        Failure = failure;
    }

    public SecretStoreFailure Failure { get; }
}

internal sealed class SecretStoreAdapter(ISecretStore store) : Native.HostSecrets
{
    public string? Load(string connectionId, Native.SecretKindTag kind) =>
        Call(() => store.Load(Guid.Parse(connectionId), Mapping.Kind(kind)));

    public void Store(string connectionId, Native.SecretKindTag kind, string secret, string label) =>
        Call(() => store.Store(Guid.Parse(connectionId), Mapping.Kind(kind), secret, label));

    public void Relabel(string connectionId, Native.SecretKindTag kind, string label) =>
        Call(() => store.Relabel(Guid.Parse(connectionId), Mapping.Kind(kind), label));

    public void Delete(string connectionId, Native.SecretKindTag kind) =>
        Call(() => store.Delete(Guid.Parse(connectionId), Mapping.Kind(kind)));

    public void DeleteConnection(string connectionId) =>
        Call(() => store.DeleteConnection(Guid.Parse(connectionId)));

    public string? LoadItem(Native.SecretItemTag item) => Call(() => store.LoadItem(Mapping.Item(item)));

    public void StoreItem(Native.SecretItemTag item, string secret) =>
        Call(() => store.StoreItem(Mapping.Item(item), secret));

    public void DeleteItem(Native.SecretItemTag item) => Call(() => store.DeleteItem(Mapping.Item(item)));

    private static void Call(Action call) => Call(() =>
    {
        call();
        return true;
    });

    // An exception other than the declared one would end the call as a panic in the core.
    private static T Call<T>(Func<T> call)
    {
        try
        {
            return call();
        }
        catch (SecretStoreException exception)
        {
            throw exception.Failure switch
            {
                SecretStoreFailure.Unavailable => new Native.HostSecretException.Unavailable(exception.Message),
                SecretStoreFailure.Locked => new Native.HostSecretException.Locked(),
                SecretStoreFailure.Dismissed => new Native.HostSecretException.Dismissed(),
                _ => new Native.HostSecretException.Failed(exception.Message),
            };
        }
        catch (Exception exception)
        {
            throw new Native.HostSecretException.Failed(exception.Message);
        }
    }
}
