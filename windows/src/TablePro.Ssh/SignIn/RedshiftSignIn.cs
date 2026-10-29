using Amazon;
using Amazon.Redshift;
using Amazon.Redshift.Model;
using Amazon.RedshiftServerless;
using Amazon.Runtime;
using TablePro.Core.Connections;
using ServerlessGetCredentialsRequest = Amazon.RedshiftServerless.Model.GetCredentialsRequest;

namespace TablePro.Ssh.SignIn;

/// <summary>
/// Asks AWS for a Redshift user and temporary password, as the macOS app does: <c>GetClusterCredentials</c> for a named
/// database user, <c>GetClusterCredentialsWithIAM</c> when the user comes from the IAM identity, and Redshift Serverless
/// <c>GetCredentials</c> for a workgroup.
/// </summary>
internal static class RedshiftSignIn
{
    /// <param name="endpoint">The cluster or workgroup.</param>
    /// <param name="region">The region to call, which the profile may set apart from the endpoint's.</param>
    /// <param name="credentials">The resolved AWS credentials.</param>
    /// <param name="databaseUser">The user to sign in as, or null to sign in as the IAM identity.</param>
    /// <param name="database">The database the password is for, or null for any.</param>
    /// <param name="http">Replaces the SDK's HTTP stack; tests pass a fake one.</param>
    /// <param name="cancellationToken">Stops the request.</param>
    public static async Task<SignInCredentials> RequestAsync(
        RedshiftEndpoint endpoint,
        string region,
        AWSCredentials credentials,
        string? databaseUser,
        string? database,
        HttpClientFactory? http,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        var regionEndpoint = RegionEndpoint.GetBySystemName(region);
        var dbName = string.IsNullOrWhiteSpace(database) ? null : database.Trim();
        try
        {
            if (endpoint.Kind == RedshiftEndpointKind.Serverless)
            {
                var config = new AmazonRedshiftServerlessConfig { RegionEndpoint = regionEndpoint };
                if (http is not null)
                {
                    config.HttpClientFactory = http;
                }

                using var serverless = new AmazonRedshiftServerlessClient(credentials, config);
                var response = await serverless.GetCredentialsAsync(
                    new ServerlessGetCredentialsRequest { WorkgroupName = endpoint.Identifier, DbName = dbName, DurationSeconds = RedshiftAuth.CredentialLifetimeSeconds },
                    cancellationToken);
                return Issued(response.DbUser, response.DbPassword);
            }

            var clusterConfig = new AmazonRedshiftConfig { RegionEndpoint = regionEndpoint };
            if (http is not null)
            {
                clusterConfig.HttpClientFactory = http;
            }

            using var cluster = new AmazonRedshiftClient(credentials, clusterConfig);
            if (databaseUser is not null)
            {
                var named = await cluster.GetClusterCredentialsAsync(
                    new GetClusterCredentialsRequest { ClusterIdentifier = endpoint.Identifier, DbUser = databaseUser, DbName = dbName, DurationSeconds = RedshiftAuth.CredentialLifetimeSeconds },
                    cancellationToken);
                return Issued(named.DbUser, named.DbPassword);
            }

            var iam = await cluster.GetClusterCredentialsWithIAMAsync(
                new GetClusterCredentialsWithIAMRequest { ClusterIdentifier = endpoint.Identifier, DbName = dbName, DurationSeconds = RedshiftAuth.CredentialLifetimeSeconds },
                cancellationToken);
            return Issued(iam.DbUser, iam.DbPassword);
        }
        catch (AmazonServiceException ex)
        {
            var code = string.IsNullOrEmpty(ex.ErrorCode) ? string.Empty : ex.ErrorCode + ": ";
            throw new InvalidOperationException($"AWS did not issue Redshift credentials: {code}{ex.Message}", ex);
        }
    }

    private static SignInCredentials Issued(string? user, string? password) =>
        string.IsNullOrEmpty(user) || string.IsNullOrEmpty(password)
            ? throw new InvalidOperationException("AWS answered without the Redshift user and password.")
            : new SignInCredentials(user, password);
}
