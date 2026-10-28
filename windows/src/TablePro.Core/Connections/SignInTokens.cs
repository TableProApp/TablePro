namespace TablePro.Core.Connections;

/// <summary>Mints the short-lived password an IAM or Entra sign-in sends in place of a saved one.</summary>
public interface ISignInTokenProvider
{
    /// <param name="profile">The profile, whose host and port are the server's own even behind a tunnel.</param>
    /// <param name="secret">The profile's saved secret: the AWS secret access key or a service principal's client secret.</param>
    /// <param name="cancellationToken">Stops a sign-in that waits on the network or the user.</param>
    ValueTask<string> GetTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken);
}

/// <summary>How often a driver's pool refreshes a sign-in token.</summary>
public static class SignInTokenRefresh
{
    /// <summary>Well inside an RDS token's 15 minutes; an Entra token lasts an hour and comes from the SDK's cache.</summary>
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(10);

    /// <summary>The wait before trying again after a refresh failed, such as a network blip.</summary>
    public static readonly TimeSpan RetryInterval = TimeSpan.FromSeconds(15);
}

/// <summary>What the user must type at the verification page to finish an Entra device code sign-in.</summary>
public sealed record DeviceCodePrompt(Uri VerificationUri, string UserCode, string Message);

/// <summary>
/// Where drivers get sign-in tokens. Drivers reference only Core, while the AWS and Azure SDKs that mint tokens live
/// with the app's other network code, so the app installs the provider once at startup. Drivers ask on every new
/// physical connection, because a pooled connection opened an hour later needs a token that has not expired.
/// </summary>
public static class SignInTokens
{
    private static ISignInTokenProvider? _provider;
    private static Func<DeviceCodePrompt, CancellationToken, Task>? _deviceCodeHandler;

    public static ISignInTokenProvider? Provider
    {
        get => Volatile.Read(ref _provider);
        set => Volatile.Write(ref _provider, value);
    }

    /// <summary>Shows a device code to the user. Without one, the sign-in fails with the message in its text.</summary>
    public static Func<DeviceCodePrompt, CancellationToken, Task>? DeviceCodeHandler
    {
        get => Volatile.Read(ref _deviceCodeHandler);
        set => Volatile.Write(ref _deviceCodeHandler, value);
    }

    public static ValueTask<string> GetAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var provider = Provider ?? throw new InvalidOperationException($"{profile.EffectiveSignIn().DisplayName(profile.Engine)} sign-in is not available in this build.");
        return provider.GetTokenAsync(profile, secret, cancellationToken);
    }

    public static Task ShowDeviceCodeAsync(DeviceCodePrompt prompt, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(prompt);
        return DeviceCodeHandler is { } handler
            ? handler(prompt, cancellationToken)
            : throw new InvalidOperationException(prompt.Message);
    }
}
