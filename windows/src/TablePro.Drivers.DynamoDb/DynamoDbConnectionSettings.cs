using System.Net;
using System.Text.RegularExpressions;
using Amazon;
using Amazon.DynamoDBv2;
using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.DynamoDb;

public enum DynamoDbCredentialSource
{
    /// <summary>The user name is the access key ID and the password the secret access key.</summary>
    AccessKey,

    /// <summary>A named profile from the shared AWS config and credentials files.</summary>
    Profile,

    /// <summary>DynamoDB Local accepts any signature, so a fixed placeholder key signs its requests.</summary>
    Local,

    /// <summary>The SDK's own chain: environment, the default profile, SSO, then the instance or container role.</summary>
    DefaultChain,
}

/// <summary>Where requests go and how they are signed, read once from the connection request.</summary>
public sealed partial record DynamoDbConnectionSettings
{
    public const string DefaultRegion = "us-east-1";
    public const string RegionOption = "region";
    public const string EndpointOption = "endpoint";
    public const string SessionTokenOption = "sessionToken";
    public const string ProfileOption = "profile";

    public required string Region { get; init; }

    /// <summary>An endpoint that replaces AWS's, such as DynamoDB Local; null for the region's own endpoint.</summary>
    public string? ServiceUrl { get; init; }

    public required DynamoDbCredentialSource CredentialSource { get; init; }

    public string? AccessKeyId { get; init; }

    public string? SecretAccessKey { get; init; }

    public string? SessionToken { get; init; }

    public string? ProfileName { get; init; }

    public int TimeoutSeconds { get; init; } = 15;

    public bool IsLocal => ServiceUrl is not null && Uri.TryCreate(ServiceUrl, UriKind.Absolute, out var uri) && IsLoopback(uri.Host);

    /// <summary>
    /// The host field holds a region such as <c>us-east-1</c>; any other host names an endpoint of its own, reached at the
    /// request's host and port so an SSH tunnel to DynamoDB Local works as it does for the other engines.
    /// </summary>
    public static DynamoDbConnectionSettings From(ConnectionRequest request)
    {
        var profile = request.Profile;
        var options = profile.AdditionalOptions;
        var host = profile.Host.Trim();

        var region = Option(options, RegionOption) ?? (IsRegion(host) ? host : DefaultRegion);
        if (!IsRegion(region))
        {
            throw new ArgumentException($"\"{region}\" is not an AWS region such as us-east-1.");
        }

        var serviceUrl = Option(options, EndpointOption);
        if (serviceUrl is null && host.Length > 0 && !IsRegion(host))
        {
            var scheme = IsLoopback(request.Host) ? "http" : "https";
            serviceUrl = new UriBuilder(scheme, request.Host, request.Port).Uri.ToString();
        }

        if (serviceUrl is not null)
        {
            ValidateEndpoint(serviceUrl);
        }

        var accessKey = string.IsNullOrWhiteSpace(profile.Username) ? null : profile.Username.Trim();
        var profileName = Option(options, ProfileOption);
        var isLocal = serviceUrl is not null && IsLoopback(new Uri(serviceUrl).Host);
        var source = accessKey is not null ? DynamoDbCredentialSource.AccessKey
            : profileName is not null ? DynamoDbCredentialSource.Profile
            : isLocal ? DynamoDbCredentialSource.Local
            : DynamoDbCredentialSource.DefaultChain;

        if (source == DynamoDbCredentialSource.AccessKey && string.IsNullOrEmpty(request.Password))
        {
            throw new ArgumentException("Enter the secret access key as the password for access key ID " + accessKey + ".");
        }

        return new DynamoDbConnectionSettings
        {
            Region = region,
            ServiceUrl = serviceUrl,
            CredentialSource = source,
            AccessKeyId = accessKey,
            SecretAccessKey = source == DynamoDbCredentialSource.AccessKey ? request.Password : null,
            SessionToken = Option(options, SessionTokenOption),
            ProfileName = profileName,
            TimeoutSeconds = Math.Max(profile.ConnectTimeoutSeconds, 1),
        };
    }

    /// <summary>A region name holds only what a host label holds; it becomes part of the endpoint and the signature.</summary>
    public static bool IsRegion(string text) => RegionPattern().IsMatch(text);

    public AmazonDynamoDBConfig CreateConfig()
    {
        var config = new AmazonDynamoDBConfig
        {
            Timeout = TimeSpan.FromSeconds(Math.Max(TimeoutSeconds, 30)),
            MaxErrorRetry = 3,
        };

        if (ServiceUrl is null)
        {
            config.RegionEndpoint = RegionEndpoint.GetBySystemName(Region);
        }
        else
        {
            config.ServiceURL = ServiceUrl;
            config.AuthenticationRegion = Region;
        }

        return config;
    }

    /// <summary>The credentials to sign with, or null to let the SDK walk its default chain.</summary>
    public AWSCredentials? CreateCredentials() => CredentialSource switch
    {
        DynamoDbCredentialSource.AccessKey when !string.IsNullOrEmpty(SessionToken) => new SessionAWSCredentials(AccessKeyId, SecretAccessKey, SessionToken),
        DynamoDbCredentialSource.AccessKey => new BasicAWSCredentials(AccessKeyId, SecretAccessKey),
        DynamoDbCredentialSource.Local => new BasicAWSCredentials("local", "local"),
        DynamoDbCredentialSource.Profile => new CredentialProfileStoreChain().TryGetAWSCredentials(ProfileName, out var credentials)
            ? credentials
            : throw new InvalidOperationException($"No AWS profile named \"{ProfileName}\" was found in the shared config or credentials file."),
        _ => null,
    };

    // The secret never reaches a log through the record's generated ToString.
    public override string ToString() => $"DynamoDbConnectionSettings {{ Region = {Region}, ServiceUrl = {ServiceUrl}, CredentialSource = {CredentialSource} }}";

    /// <summary>Compares the literal host, without a DNS lookup, so a name cannot resolve its way into the plain-HTTP allowance.</summary>
    public static bool IsLoopback(string host)
    {
        var trimmed = host.Trim('[', ']');
        return trimmed.Equals("localhost", StringComparison.OrdinalIgnoreCase)
            || (IPAddress.TryParse(trimmed, out var address) && IPAddress.IsLoopback(address));
    }

    private static void ValidateEndpoint(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Host.Length == 0)
        {
            throw new ArgumentException($"\"{url}\" is not a URL. Enter an endpoint such as http://localhost:8000.");
        }

        if (uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)
        {
            throw new ArgumentException("The endpoint must start with https:// or http://.");
        }

        // A custom endpoint receives the signed request, session token included, so plain HTTP stays on this machine.
        if (uri.Scheme == Uri.UriSchemeHttp && !IsLoopback(uri.Host))
        {
            throw new ArgumentException("Plain HTTP is only allowed for an endpoint on this computer (localhost). Use https:// for any other host.");
        }
    }

    private static string? Option(IReadOnlyDictionary<string, string> options, string key) =>
        options.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;

    [GeneratedRegex(@"^[a-z]{2}(-[a-z]+)+-\d{1,2}$", RegexOptions.CultureInvariant)]
    private static partial Regex RegionPattern();
}
