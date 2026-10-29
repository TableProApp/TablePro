using TablePro.Core.Connections;

namespace TablePro.App.Localization;

/// <summary>
/// The translated names of the connection choices Core defines. Core keeps English names for logs and its own
/// messages; the connection form shows these instead.
/// </summary>
internal static class ConnectionNames
{
    public static string SignIn(SignInMethod method, DatabaseEngine engine) => method switch
    {
        SignInMethod.Password when engine == DatabaseEngine.SqlServer => Strings.Get("Connection/SignInSqlServer"),
        SignInMethod.Password => Strings.Get("Connection/SignInPassword"),
        SignInMethod.WindowsIntegrated => Strings.Get("Connection/SignInWindows"),
        SignInMethod.Kerberos => Strings.Get("Connection/SignInKerberos"),
        SignInMethod.AwsIamAccessKey => Strings.Get("Connection/SignInAwsAccessKey"),
        SignInMethod.AwsIamProfile => Strings.Get("Connection/SignInAwsProfile"),
        SignInMethod.AwsIamSso => Strings.Get("Connection/SignInAwsSso"),
        SignInMethod.EntraId => Strings.Get("Connection/SignInEntra"),
        _ => method.ToString(),
    };

    public static string Entra(EntraAuthMode mode) => mode switch
    {
        EntraAuthMode.Interactive => Strings.Get("Connection/EntraInteractive"),
        EntraAuthMode.DeviceCode => Strings.Get("Connection/EntraDeviceCode"),
        EntraAuthMode.Default => Strings.Get("Connection/EntraDefault"),
        EntraAuthMode.ManagedIdentity => Strings.Get("Connection/EntraManagedIdentity"),
        EntraAuthMode.ServicePrincipal => Strings.Get("Connection/EntraServicePrincipal"),
        EntraAuthMode.Integrated => Strings.Get("Connection/EntraIntegrated"),
        _ => mode.ToString(),
    };

    /// <summary>The label of the secret field for a method, since IAM and service principals put a key there.</summary>
    public static string SecretLabel(SignInMethod method, EntraAuthMode entraMode) => method switch
    {
        SignInMethod.AwsIamAccessKey => Strings.Get("Connection/SecretAccessKeyHeader"),
        SignInMethod.EntraId when entraMode == EntraAuthMode.ServicePrincipal => Strings.Get("Connection/ClientSecretHeader"),
        _ => Strings.Get("Connection/PasswordHeader"),
    };

    public static string Transport(ConnectionTransport transport) => transport switch
    {
        ConnectionTransport.Ssh => Strings.Get("Connection/TransportSsh"),
        ConnectionTransport.Proxy => Strings.Get("Connection/TransportProxy"),
        ConnectionTransport.CloudSqlProxy => Strings.Get("Connection/TransportCloudSql"),
        ConnectionTransport.CloudflareTunnel => Strings.Get("Connection/TransportCloudflare"),
        ConnectionTransport.TunnelCommand => Strings.Get("Connection/TransportCommand"),
        _ => Strings.Get("Connection/TransportDirect"),
    };

    public static string TransportSummary(ConnectionTransport transport) => transport switch
    {
        ConnectionTransport.Ssh => Strings.Get("Connection/TransportSshSummary"),
        ConnectionTransport.Proxy => Strings.Get("Connection/TransportProxySummary"),
        ConnectionTransport.CloudSqlProxy => Strings.Get("Connection/TransportCloudSqlSummary"),
        ConnectionTransport.CloudflareTunnel => Strings.Get("Connection/TransportCloudflareSummary"),
        ConnectionTransport.TunnelCommand => Strings.Get("Connection/TransportCommandSummary"),
        _ => Strings.Get("Connection/TransportDirectSummary"),
    };

    public static string Color(ConnectionColor color) => color switch
    {
        ConnectionColor.Red => Strings.Get("Connection/ColorRed"),
        ConnectionColor.Orange => Strings.Get("Connection/ColorOrange"),
        ConnectionColor.Yellow => Strings.Get("Connection/ColorYellow"),
        ConnectionColor.Green => Strings.Get("Connection/ColorGreen"),
        ConnectionColor.Blue => Strings.Get("Connection/ColorBlue"),
        ConnectionColor.Purple => Strings.Get("Connection/ColorPurple"),
        ConnectionColor.Pink => Strings.Get("Connection/ColorPink"),
        ConnectionColor.Gray => Strings.Get("Connection/ColorGray"),
        _ => Strings.Get("Common/None"),
    };
}
