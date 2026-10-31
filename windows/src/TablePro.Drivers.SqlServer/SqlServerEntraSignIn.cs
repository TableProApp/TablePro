using Microsoft.Data.SqlClient;
using Microsoft.Identity.Client;
using TablePro.Core.Connections;

namespace TablePro.Drivers.SqlServer;

/// <summary>
/// Installs SqlClient's Entra ID provider once. Its default device code callback writes the code to the console,
/// which a windowed app does not have, so the code goes to the app's prompt instead.
/// </summary>
internal static class SqlServerEntraSignIn
{
    private static readonly SqlAuthenticationMethod[] Methods =
    [
        SqlAuthenticationMethod.ActiveDirectoryInteractive,
        SqlAuthenticationMethod.ActiveDirectoryDeviceCodeFlow,
        SqlAuthenticationMethod.ActiveDirectoryDefault,
        SqlAuthenticationMethod.ActiveDirectoryManagedIdentity,
        SqlAuthenticationMethod.ActiveDirectoryServicePrincipal,
        SqlAuthenticationMethod.ActiveDirectoryIntegrated,
    ];

    private static readonly Lazy<bool> Registered = new(Register, LazyThreadSafetyMode.ExecutionAndPublication);

    public static void EnsureRegistered() => _ = Registered.Value;

    private static bool Register()
    {
        var provider = new ActiveDirectoryAuthenticationProvider(ShowDeviceCodeAsync);
        foreach (var method in Methods)
        {
            SqlAuthenticationProvider.SetProvider(method, provider);
        }

        return true;
    }

    private static Task ShowDeviceCodeAsync(DeviceCodeResult result) =>
        SignInTokens.ShowDeviceCodeAsync(new DeviceCodePrompt(new Uri(result.VerificationUrl), result.UserCode, result.Message), CancellationToken.None);
}
