using Native = TablePro.Interop.Native;

namespace TablePro.Interop;

// The core calls it on a thread it lets block. Throw SecretStoreException for a failure the user can act on.
public interface ISecretStore
{
    string? Load(Guid connectionId, SecretKind kind);

    void Store(Guid connectionId, SecretKind kind, string secret, string label);

    void Relabel(Guid connectionId, SecretKind kind, string label);

    void Delete(Guid connectionId, SecretKind kind);

    void DeleteConnection(Guid connectionId);

    // Every secret of an SSH or credential profile, which the store keeps apart from connections'. NotOwned says another
    // app keeps them, and the core stops asking.
    SecretDeletion DeleteProfile(Guid profileId, ProfileKind kind);

    string? LoadItem(SecretItem item);

    // The app names the item in its own words.
    void StoreItem(SecretItem item, string secret);

    void DeleteItem(SecretItem item);
}

public enum SecretKind
{
    DatabasePassword,
    SshPassword,
    SshPassphrase,
}

public enum ProfileKind
{
    Ssh,
    Credential,
}

public enum SecretDeletion
{
    Deleted,
    NotOwned,
}

public enum SecretItemKind
{
    McpToken,
    AnthropicKey,
    OpenAIKey,
    OpenAICompatibleKey,

    // The TablePro account's refresh token, which only the account asks for.
    AccountRefreshToken,
}

// A secret no connection owns. tablepro.app's refresh token has no sign-in key; another server's names one, so each
// server keeps its own item (core ADR 0047).
public readonly record struct SecretItem(SecretItemKind Kind, string? SignInKey = null)
{
    public static SecretItem McpToken { get; } = new(SecretItemKind.McpToken);

    public static SecretItem AnthropicKey { get; } = new(SecretItemKind.AnthropicKey);

    public static SecretItem OpenAIKey { get; } = new(SecretItemKind.OpenAIKey);

    public static SecretItem OpenAICompatibleKey { get; } = new(SecretItemKind.OpenAICompatibleKey);

    public static SecretItem AccountRefreshToken { get; } = new(SecretItemKind.AccountRefreshToken);

    public static SecretItem AccountRefreshTokenFor(string signInKey) =>
        new(SecretItemKind.AccountRefreshToken, signInKey);
}

public enum SecretStoreFailure
{
    Unavailable,
    Locked,

    // The user dismissed the unlock prompt.
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

    public Native.SecretDeletionTag DeleteProfile(string profileId, Native.ProfileKindTag kind) =>
        Call(() => Mapping.Deletion(store.DeleteProfile(Guid.Parse(profileId), Mapping.Profile(kind))));

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
