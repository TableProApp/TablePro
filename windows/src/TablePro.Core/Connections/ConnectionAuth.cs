namespace TablePro.Core.Connections;

/// <summary>
/// How a profile signs in to the database. The macOS app keeps the same choice in its additional fields, as
/// <c>awsAuth</c> (off, accessKey, profile, sso, kerberos) and <c>mssqlAuthMethod</c> (sql, windows, entra).
/// </summary>
public enum SignInMethod
{
    /// <summary>The user and the password the credential vault holds.</summary>
    Password,

    /// <summary>SQL Server Windows authentication: the signed-in Windows account, by Kerberos or NTLM.</summary>
    WindowsIntegrated,

    /// <summary>GSSAPI with the Windows logon's Kerberos ticket, for PostgreSQL and MariaDB. No password is sent.</summary>
    Kerberos,

    /// <summary>An RDS IAM token signed with an access key; the secret access key takes the password's place.</summary>
    AwsIamAccessKey,

    /// <summary>An RDS IAM token signed with a profile from <c>%USERPROFILE%\.aws</c>.</summary>
    AwsIamProfile,

    /// <summary>An RDS IAM token signed with an IAM Identity Center (SSO) profile.</summary>
    AwsIamSso,

    /// <summary>Microsoft Entra ID: SQL Server, Azure Database for PostgreSQL and Azure Database for MySQL.</summary>
    EntraId,
}

/// <summary>Which Entra credential signs in. The SQL Server names map to SqlClient's <c>Authentication</c> keyword.</summary>
public enum EntraAuthMode
{
    /// <summary>A browser sign-in, remembered for the rest of the session.</summary>
    Interactive,

    /// <summary>A code entered at microsoft.com/devicelogin, for a machine whose browser cannot sign in.</summary>
    DeviceCode,

    /// <summary>Whatever the environment offers: Azure CLI, Visual Studio, environment variables, managed identity.</summary>
    Default,

    /// <summary>The Azure resource's managed identity; a client id picks a user-assigned one.</summary>
    ManagedIdentity,

    /// <summary>An app registration's client id and secret; the secret takes the password's place.</summary>
    ServicePrincipal,

    /// <summary>The Windows account of a domain joined to Entra, without a prompt. SQL Server only.</summary>
    Integrated,
}

/// <summary>PostgreSQL's <c>gssencmode</c>: whether the connection is encrypted with GSSAPI instead of TLS.</summary>
public enum GssEncryptionMode
{
    Disable,
    Prefer,
    Require,
}

/// <summary>The sign-in a profile uses when it is not a plain password. Null on the profile means a password.</summary>
public sealed record ConnectionAuthSettings
{
    public SignInMethod Method { get; init; } = SignInMethod.Password;

    /// <summary>The region the token is signed for. Empty reads it from an RDS host name.</summary>
    public string? AwsRegion { get; init; }

    public string? AwsAccessKeyId { get; init; }

    /// <summary>The profile in <c>%USERPROFILE%\.aws\config</c>. Empty means <c>default</c>.</summary>
    public string? AwsProfileName { get; init; }

    /// <summary>
    /// The RDS endpoint the token is signed for, as <c>host[:port]</c>, when the host the app dials is a proxy or
    /// a custom DNS name. Empty signs for the profile's host and port.
    /// </summary>
    public string? AwsRdsEndpoint { get; init; }

    public EntraAuthMode EntraMode { get; init; } = EntraAuthMode.Interactive;

    /// <summary>The directory to sign in to. Empty lets Entra pick the account's home tenant.</summary>
    public string? EntraTenantId { get; init; }

    /// <summary>The app registration for a service principal, or a user-assigned managed identity.</summary>
    public string? EntraClientId { get; init; }

    /// <summary>The Kerberos service name: PostgreSQL's <c>krbsrvname</c> (default <c>postgres</c>), MariaDB's server SPN.</summary>
    public string? KerberosServiceName { get; init; }

    public GssEncryptionMode GssEncryption { get; init; } = GssEncryptionMode.Prefer;
}

/// <summary>Which sign-in methods an engine offers, and what each one asks of the form.</summary>
public static class SignInMethods
{
    /// <summary>The methods the form offers for an engine, with the plain password first.</summary>
    public static IReadOnlyList<SignInMethod> Available(DatabaseEngine engine) => engine switch
    {
        DatabaseEngine.PostgreSql => [SignInMethod.Password, SignInMethod.AwsIamAccessKey, SignInMethod.AwsIamProfile, SignInMethod.AwsIamSso, SignInMethod.EntraId, SignInMethod.Kerberos],
        DatabaseEngine.MySql => [SignInMethod.Password, SignInMethod.AwsIamAccessKey, SignInMethod.AwsIamProfile, SignInMethod.AwsIamSso, SignInMethod.EntraId],

        // MariaDB's GSSAPI plugin is what MySqlConnector speaks; Azure no longer hosts MariaDB, so it has no Entra sign-in.
        DatabaseEngine.MariaDb => [SignInMethod.Password, SignInMethod.AwsIamAccessKey, SignInMethod.AwsIamProfile, SignInMethod.AwsIamSso, SignInMethod.Kerberos],
        DatabaseEngine.SqlServer => [SignInMethod.Password, SignInMethod.WindowsIntegrated, SignInMethod.EntraId],
        _ => [SignInMethod.Password],
    };

    public static IReadOnlyList<EntraAuthMode> EntraModes(DatabaseEngine engine) => engine == DatabaseEngine.SqlServer
        ? [EntraAuthMode.Interactive, EntraAuthMode.DeviceCode, EntraAuthMode.Default, EntraAuthMode.ManagedIdentity, EntraAuthMode.ServicePrincipal, EntraAuthMode.Integrated]
        : [EntraAuthMode.Interactive, EntraAuthMode.DeviceCode, EntraAuthMode.Default, EntraAuthMode.ManagedIdentity, EntraAuthMode.ServicePrincipal];

    public static string DisplayName(this SignInMethod method, DatabaseEngine engine) => method switch
    {
        SignInMethod.Password when engine == DatabaseEngine.SqlServer => "SQL Server Authentication",
        SignInMethod.Password => "Password",
        SignInMethod.WindowsIntegrated => "Windows Authentication",
        SignInMethod.Kerberos => "Kerberos (GSSAPI)",
        SignInMethod.AwsIamAccessKey => "AWS IAM (Access Key)",
        SignInMethod.AwsIamProfile => "AWS IAM (Profile)",
        SignInMethod.AwsIamSso => "AWS IAM (SSO)",
        SignInMethod.EntraId => "Microsoft Entra ID",
        _ => method.ToString(),
    };

    public static string DisplayName(this EntraAuthMode mode) => mode switch
    {
        EntraAuthMode.Interactive => "Interactive (browser)",
        EntraAuthMode.DeviceCode => "Device code",
        EntraAuthMode.Default => "Default (Azure CLI, Visual Studio, environment)",
        EntraAuthMode.ManagedIdentity => "Managed identity",
        EntraAuthMode.ServicePrincipal => "Service principal",
        EntraAuthMode.Integrated => "Integrated (Windows account)",
        _ => mode.ToString(),
    };

    /// <summary>The sign-in in force, treating a method the engine does not offer as a password.</summary>
    public static SignInMethod EffectiveSignIn(this ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var method = profile.Auth?.Method ?? SignInMethod.Password;
        return Available(profile.Engine).Contains(method) ? method : SignInMethod.Password;
    }

    public static bool IsAwsIam(this SignInMethod method) =>
        method is SignInMethod.AwsIamAccessKey or SignInMethod.AwsIamProfile or SignInMethod.AwsIamSso;

    /// <summary>
    /// Whether every new physical connection asks <see cref="SignInTokens"/> for a short-lived token instead of
    /// sending the saved password. SQL Server's Entra sign-in is done by SqlClient itself, so it is not one.
    /// </summary>
    public static bool UsesSignInToken(this ConnectionProfile profile)
    {
        var method = profile.EffectiveSignIn();
        return method.IsAwsIam() || (method == SignInMethod.EntraId && profile.Engine != DatabaseEngine.SqlServer);
    }

    /// <summary>
    /// Whether the profile's saved password slot holds something: the password itself, the AWS secret access key,
    /// or a service principal's client secret.
    /// </summary>
    public static bool UsesSecret(this ConnectionProfile profile)
    {
        var method = profile.EffectiveSignIn();
        return method is SignInMethod.Password or SignInMethod.AwsIamAccessKey
            || (method == SignInMethod.EntraId && profile.Auth!.EntraMode == EntraAuthMode.ServicePrincipal);
    }

    /// <summary>
    /// Whether the form shows the user field. Windows and Kerberos sign in as the Windows account. SqlClient takes an
    /// Entra user name only as the interactive login hint; PostgreSQL and MySQL need the Entra user or group as the
    /// database role name.
    /// </summary>
    public static bool UsesUsername(this ConnectionProfile profile)
    {
        var method = profile.EffectiveSignIn();
        if (method is SignInMethod.WindowsIntegrated or SignInMethod.Kerberos)
        {
            return false;
        }

        return method != SignInMethod.EntraId || profile.Engine != DatabaseEngine.SqlServer || profile.Auth!.EntraMode == EntraAuthMode.Interactive;
    }

    /// <summary>The label of the secret field for a method, since IAM and service principals put a key there.</summary>
    public static string SecretLabel(SignInMethod method, EntraAuthMode entraMode) => method switch
    {
        SignInMethod.AwsIamAccessKey => "Secret access key",
        SignInMethod.EntraId when entraMode == EntraAuthMode.ServicePrincipal => "Client secret",
        _ => "Password",
    };

    /// <summary>
    /// Tokens travel as cleartext passwords, so TLS is required unless the transport already encrypts the hop, as the
    /// Cloud SQL Auth Proxy does. Matches the macOS rule for IAM sign-in.
    /// </summary>
    public static SslMode EffectiveSslMode(this ConnectionProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        if (profile.UsesSignInToken() && profile.SslMode < SslMode.Required && profile.ActiveTransport() != ConnectionTransport.CloudSqlProxy)
        {
            return SslMode.Required;
        }

        return profile.SslMode;
    }
}
