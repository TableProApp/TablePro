using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using Azure.Core;
using Azure.Identity;
using TablePro.Core.Connections;

namespace TablePro.Ssh.SignIn;

/// <summary>
/// Mints the tokens PostgreSQL and MySQL send as passwords: Amazon RDS IAM tokens, signed with an access key or a
/// profile from the AWS config files (static keys, assumed roles, IAM Identity Center), and Microsoft Entra ID tokens
/// for Azure Database. Credentials are kept per profile for the app's lifetime, so an interactive or device code
/// sign-in happens once and the SDKs refresh what they hold.
/// </summary>
public sealed class CloudSignInTokenProvider : ISignInTokenProvider
{
    /// <summary>The scope Azure Database for PostgreSQL and MySQL accept tokens for.</summary>
    public const string AzureDatabaseScope = "https://ossrdbms-aad.database.windows.net/.default";

    private readonly ConcurrentDictionary<string, Lazy<AWSCredentials>> _awsProfiles = new(StringComparer.Ordinal);
    private readonly ConcurrentDictionary<string, Lazy<TokenCredential>> _entra = new(StringComparer.Ordinal);
    private readonly TimeProvider _time;

    public CloudSignInTokenProvider(TimeProvider? time = null)
    {
        _time = time ?? TimeProvider.System;
    }

    public async ValueTask<string> GetTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(profile);
        var method = profile.EffectiveSignIn();
        if (method.IsAwsIam())
        {
            return await AwsTokenAsync(profile, method, secret, cancellationToken);
        }

        if (method == SignInMethod.EntraId)
        {
            return await EntraTokenAsync(profile, secret, cancellationToken);
        }

        throw new InvalidOperationException($"{method.DisplayName(profile.Engine)} does not use a sign-in token.");
    }

    private async Task<string> AwsTokenAsync(ConnectionProfile profile, SignInMethod method, string? secret, CancellationToken cancellationToken)
    {
        var auth = profile.Auth ?? new ConnectionAuthSettings();
        var user = profile.Username?.Trim();
        if (string.IsNullOrEmpty(user))
        {
            throw new InvalidOperationException("Enter the database user the IAM token signs in as.");
        }

        var (host, port) = RdsAuthToken.SigningEndpoint(profile);
        AwsCredentialSet credentials;
        string? profileRegion = null;
        if (method == SignInMethod.AwsIamAccessKey)
        {
            if (string.IsNullOrWhiteSpace(auth.AwsAccessKeyId) || string.IsNullOrEmpty(secret))
            {
                throw new InvalidOperationException("Enter the access key ID and the secret access key.");
            }

            credentials = new AwsCredentialSet(auth.AwsAccessKeyId.Trim(), secret);
        }
        else
        {
            var name = string.IsNullOrWhiteSpace(auth.AwsProfileName) ? "default" : auth.AwsProfileName.Trim();
            var chain = new CredentialProfileStoreChain();
            if (chain.TryGetProfile(name, out var stored))
            {
                profileRegion = stored.Region?.SystemName;
            }

            ImmutableCredentials resolved;
            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                var source = _awsProfiles.GetOrAdd(name, key => new Lazy<AWSCredentials>(() => LoadProfile(chain, key))).Value;
                resolved = await source.GetCredentialsAsync();
            }
            catch (InvalidOperationException)
            {
                _awsProfiles.TryRemove(name, out _);
                throw;
            }
            catch (AmazonClientException ex)
            {
                // A failed SSO or role session must not stay cached; the next connect reads the profile again.
                _awsProfiles.TryRemove(name, out _);
                var hint = method == SignInMethod.AwsIamSso ? $" Run “aws sso login --profile {name}” and connect again." : string.Empty;
                throw new InvalidOperationException($"The AWS profile {name} gave no credentials: {ex.Message}{hint}", ex);
            }

            credentials = new AwsCredentialSet(resolved.AccessKey, resolved.SecretKey, string.IsNullOrEmpty(resolved.Token) ? null : resolved.Token);
        }

        string region;
        try
        {
            region = RdsAuthToken.SigningRegion(profile, host);
        }
        catch (InvalidOperationException) when (profileRegion is not null)
        {
            region = profileRegion;
        }

        return RdsAuthToken.Generate(credentials, host, port, region, user, _time.GetUtcNow());
    }

    private static AWSCredentials LoadProfile(CredentialProfileStoreChain chain, string name) =>
        chain.TryGetAWSCredentials(name, out var credentials)
            ? credentials
            : throw new InvalidOperationException($"The AWS profile {name} is not in %USERPROFILE%\\.aws\\config or credentials.");

    private async Task<string> EntraTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken)
    {
        var auth = profile.Auth ?? new ConnectionAuthSettings();
        var key = EntraKey(auth, profile.Username, secret);
        try
        {
            var credential = _entra.GetOrAdd(key, _ => new Lazy<TokenCredential>(() => CreateEntraCredential(auth, profile.Username, secret))).Value;
            var token = await credential.GetTokenAsync(new TokenRequestContext([AzureDatabaseScope]), cancellationToken);
            return token.Token;
        }
        catch (InvalidOperationException)
        {
            _entra.TryRemove(key, out _);
            throw;
        }
        catch (AuthenticationFailedException ex)
        {
            _entra.TryRemove(key, out _);
            throw new InvalidOperationException($"Microsoft Entra ID sign-in failed: {ex.Message}", ex);
        }
    }

    internal static TokenCredential CreateEntraCredential(ConnectionAuthSettings auth, string? username, string? secret)
    {
        var tenant = Blank(auth.EntraTenantId);
        var clientId = Blank(auth.EntraClientId);
        switch (auth.EntraMode)
        {
            case EntraAuthMode.DeviceCode:
                return new DeviceCodeCredential(new DeviceCodeCredentialOptions
                {
                    TenantId = tenant,
                    ClientId = clientId,
                    DeviceCodeCallback = (info, token) => SignInTokens.ShowDeviceCodeAsync(new DeviceCodePrompt(info.VerificationUri, info.UserCode, info.Message), token),
                });
            case EntraAuthMode.Default:
                return new DefaultAzureCredential(new DefaultAzureCredentialOptions { TenantId = tenant, ManagedIdentityClientId = clientId });
            case EntraAuthMode.ManagedIdentity:
                return new ManagedIdentityCredential(clientId is null ? ManagedIdentityId.SystemAssigned : ManagedIdentityId.FromUserAssignedClientId(clientId));
            case EntraAuthMode.ServicePrincipal:
                if (tenant is null || clientId is null || string.IsNullOrEmpty(secret))
                {
                    throw new InvalidOperationException("A service principal needs the directory (tenant) ID, the application (client) ID and the client secret.");
                }

                return new ClientSecretCredential(tenant, clientId, secret);
            case EntraAuthMode.Integrated:
                throw new InvalidOperationException("Integrated Entra sign-in is available for SQL Server only.");
            default:
                return new InteractiveBrowserCredential(new InteractiveBrowserCredentialOptions
                {
                    TenantId = tenant,
                    ClientId = clientId,
                    LoginHint = Blank(username),
                });
        }
    }

    /// <summary>One credential per distinct sign-in, so editing the tenant or the secret starts a fresh one.</summary>
    private static string EntraKey(ConnectionAuthSettings auth, string? username, string? secret)
    {
        var secretHash = string.IsNullOrEmpty(secret) ? string.Empty : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(secret)));
        return string.Join('\u001F', auth.EntraMode, auth.EntraTenantId?.Trim(), auth.EntraClientId?.Trim(), username?.Trim(), secretHash);
    }

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}
