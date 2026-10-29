using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Amazon.Runtime;
using TablePro.Core.Connections;
using TablePro.Ssh.SignIn;

namespace TablePro.Ssh.Tests;

public sealed class CloudIamSignInTests : IDisposable
{
    // AWS's documented example key pair, which signs nothing real.
    private const string AccessKeyId = "AKIDEXAMPLE";
    private const string SecretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY";

    private readonly string _directory = Directory.CreateTempSubdirectory("tablepro-iam-").FullName;

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private static ConnectionProfile Redshift(string host, string? user) => new()
    {
        Name = "r",
        Engine = DatabaseEngine.Redshift,
        Host = host,
        Username = user,
        Database = "dev",
        Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamAccessKey, AwsAccessKeyId = AccessKeyId },
    };

    [Fact]
    public async Task ANamedUserGetsClusterCredentialsSignedForRedshift()
    {
        var http = new FakeAws(_ => Xml(
            "<GetClusterCredentialsResponse xmlns=\"http://redshift.amazonaws.com/doc/2012-12-01/\"><GetClusterCredentialsResult>"
            + "<DbUser>IAM:etl</DbUser><DbPassword>temporary</DbPassword><Expiration>2026-10-28T10:00:00Z</Expiration>"
            + "</GetClusterCredentialsResult><ResponseMetadata><RequestId>1</RequestId></ResponseMetadata></GetClusterCredentialsResponse>"));
        var provider = new CloudSignInTokenProvider(null, http, null);

        var signIn = await provider.SignInAsync(Redshift("analytics.abc123.us-east-1.redshift.amazonaws.com", "etl"), SecretAccessKey, Token);

        Assert.Equal(new SignInCredentials("IAM:etl", "temporary"), signIn);
        var (request, body) = Assert.Single(http.Requests);
        Assert.Equal("redshift.us-east-1.amazonaws.com", request.RequestUri!.Host);
        Assert.Contains("Action=GetClusterCredentials&", body, StringComparison.Ordinal);
        Assert.Contains("ClusterIdentifier=analytics", body, StringComparison.Ordinal);
        Assert.Contains("DbUser=etl", body, StringComparison.Ordinal);
        Assert.Contains("DbName=dev", body, StringComparison.Ordinal);
        Assert.Contains("DurationSeconds=900", body, StringComparison.Ordinal);
        Assert.Matches($"AWS4-HMAC-SHA256 Credential={AccessKeyId}/\\d{{8}}/us-east-1/redshift/aws4_request", Authorization(request));
    }

    [Fact]
    public async Task WithoutAUserRedshiftSignsInAsTheIamIdentity()
    {
        var http = new FakeAws(_ => Xml(
            "<GetClusterCredentialsWithIAMResponse xmlns=\"http://redshift.amazonaws.com/doc/2012-12-01/\"><GetClusterCredentialsWithIAMResult>"
            + "<DbUser>IAMR:analyst</DbUser><DbPassword>temporary</DbPassword></GetClusterCredentialsWithIAMResult>"
            + "<ResponseMetadata><RequestId>1</RequestId></ResponseMetadata></GetClusterCredentialsWithIAMResponse>"));
        var provider = new CloudSignInTokenProvider(null, http, null);

        var password = await provider.GetTokenAsync(Redshift("analytics.abc123.eu-west-1.redshift.amazonaws.com", null), SecretAccessKey, Token);

        Assert.Equal("temporary", password);
        var (request, body) = Assert.Single(http.Requests);
        Assert.Contains("Action=GetClusterCredentialsWithIAM&", body, StringComparison.Ordinal);
        Assert.DoesNotContain("DbUser", body, StringComparison.Ordinal);
        Assert.Contains("/eu-west-1/redshift/aws4_request", Authorization(request), StringComparison.Ordinal);
    }

    [Fact]
    public async Task AServerlessWorkgroupGetsCredentialsFromRedshiftServerless()
    {
        var http = new FakeAws(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"dbUser\":\"IAM:etl\",\"dbPassword\":\"temporary\",\"expiration\":1793000000}", Encoding.UTF8, "application/x-amz-json-1.1"),
        });
        var provider = new CloudSignInTokenProvider(null, http, null);

        // A port forward dials the loopback address, so the endpoint names the workgroup instead.
        var profile = Redshift("127.0.0.1", "etl") with
        {
            Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamAccessKey, AwsAccessKeyId = AccessKeyId, AwsRedshiftEndpoint = "reports.123456789012.us-west-2.redshift-serverless.amazonaws.com" },
        };
        var signIn = await provider.SignInAsync(profile, SecretAccessKey, Token);

        Assert.Equal(new SignInCredentials("IAM:etl", "temporary"), signIn);
        var (request, body) = Assert.Single(http.Requests);
        Assert.Equal("RedshiftServerless.GetCredentials", request.Headers.GetValues("X-Amz-Target").Single());
        using var json = JsonDocument.Parse(body);
        Assert.Equal("reports", json.RootElement.GetProperty("workgroupName").GetString());
        Assert.Equal("dev", json.RootElement.GetProperty("dbName").GetString());
        Assert.Contains("/us-west-2/redshift-serverless/aws4_request", Authorization(request), StringComparison.Ordinal);
    }

    [Fact]
    public async Task ARefusalSaysWhatAwsAnswered()
    {
        var http = new FakeAws(_ => Xml(
            "<ErrorResponse xmlns=\"http://redshift.amazonaws.com/doc/2012-12-01/\"><Error><Type>Sender</Type><Code>UnauthorizedOperation</Code>"
            + "<Message>Not authorized to get credentials of user etl</Message></Error><RequestId>1</RequestId></ErrorResponse>",
            HttpStatusCode.Forbidden));
        var provider = new CloudSignInTokenProvider(null, http, null);

        var error = await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await provider.SignInAsync(Redshift("analytics.abc123.us-east-1.redshift.amazonaws.com", "etl"), SecretAccessKey, Token));

        Assert.Contains("UnauthorizedOperation", error.Message, StringComparison.Ordinal);
        Assert.Contains("Not authorized", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnUnknownHostIsRefusedBeforeAnyRequest()
    {
        var http = new FakeAws(_ => throw new InvalidOperationException("no request expected"));
        var provider = new CloudSignInTokenProvider(null, http, null);

        await Assert.ThrowsAsync<InvalidOperationException>(async () => await provider.SignInAsync(Redshift("warehouse.example.com", "etl"), SecretAccessKey, Token));
        Assert.Empty(http.Requests);
    }

    [Fact]
    public async Task AServiceAccountKeyIsExchangedForACloudSqlLoginToken()
    {
        var (json, email) = ServiceAccountKey();
        var http = new FakeGoogle();
        var provider = new CloudSignInTokenProvider(null, null, http);
        var profile = new ConnectionProfile
        {
            Name = "g",
            Engine = DatabaseEngine.PostgreSql,
            Host = "10.0.0.5",
            Username = "sa@project.iam",
            Auth = new ConnectionAuthSettings { Method = SignInMethod.GoogleCloudServiceAccount },
        };

        var path = Path.Combine(_directory, "key.json");
        await File.WriteAllTextAsync(path, json, Token);
        var token = await provider.GetTokenAsync(profile, path, Token);
        var again = await provider.GetTokenAsync(profile, json, Token);

        Assert.Equal("ya29.cloudsql", token);
        Assert.Equal("ya29.cloudsql", again);

        // The token is cached for the key, whether it came from the file or was pasted.
        var (request, body) = Assert.Single(http.Requests);
        Assert.Equal("https://oauth2.googleapis.com/token", request.RequestUri!.AbsoluteUri);
        var form = body.Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
        Assert.Equal("urn:ietf:params:oauth:grant-type:jwt-bearer", form["grant_type"]);
        var claims = JwtClaims(form["assertion"]);
        Assert.Equal(GoogleCloudSqlTokens.LoginScope, claims.GetProperty("scope").GetString());
        Assert.Equal(email, claims.GetProperty("iss").GetString());
    }

    [Fact]
    public void OnlyAServiceAccountKeyIsAccepted()
    {
        var (json, _) = ServiceAccountKey();

        Assert.Equal(json, GoogleCloudSqlTokens.ServiceAccountJson("\xFEFF" + json + "\n"));
        Assert.Throws<InvalidOperationException>(() => GoogleCloudSqlTokens.ServiceAccountJson(" "));
        Assert.Throws<InvalidOperationException>(() => GoogleCloudSqlTokens.ServiceAccountJson("{\"type\":\"authorized_user\"}"));
        Assert.Throws<InvalidOperationException>(() => GoogleCloudSqlTokens.ServiceAccountJson("{not json"));
        Assert.Throws<InvalidOperationException>(() => GoogleCloudSqlTokens.ServiceAccountJson("-----BEGIN PRIVATE KEY-----"));
        Assert.Throws<InvalidOperationException>(() => GoogleCloudSqlTokens.ServiceAccountJson(Path.Combine(_directory, "missing.json")));
    }

    [Fact]
    public void ApplicationDefaultCredentialsAreWhereGcloudWritesThem()
    {
        Assert.Equal(@"C:\keys\adc.json", GoogleCloudSqlTokens.ApplicationDefaultPath("\"C:\\keys\\adc.json\"", @"C:\Users\me\AppData\Roaming"));
        Assert.Equal(@"C:\Users\me\AppData\Roaming\gcloud\application_default_credentials.json", GoogleCloudSqlTokens.ApplicationDefaultPath(null, @"C:\Users\me\AppData\Roaming"));
        Assert.Null(GoogleCloudSqlTokens.ApplicationDefaultPath(" ", null));
    }

    private static (string Json, string Email) ServiceAccountKey()
    {
        using var rsa = RSA.Create(2048);
        const string email = "sa@project.iam.gserviceaccount.com";
        var key = new JsonObject
        {
            ["type"] = "service_account",
            ["project_id"] = "project",
            ["private_key_id"] = "1",
            ["private_key"] = rsa.ExportPkcs8PrivateKeyPem(),
            ["client_email"] = email,
            ["client_id"] = "1",
            ["token_uri"] = "https://oauth2.googleapis.com/token",
        };
        return (key.ToJsonString(), email);
    }

    private static JsonElement JwtClaims(string jwt)
    {
        var payload = jwt.Split('.')[1].Replace('-', '+').Replace('_', '/');
        payload = payload.PadRight(payload.Length + ((4 - (payload.Length % 4)) % 4), '=');
        using var document = JsonDocument.Parse(Convert.FromBase64String(payload));
        return document.RootElement.Clone();
    }

    private static string Authorization(HttpRequestMessage request) =>
        request.Headers.NonValidated.TryGetValues("Authorization", out var values) ? string.Join(", ", values) : string.Empty;

    private static HttpResponseMessage Xml(string body, HttpStatusCode status = HttpStatusCode.OK) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "text/xml") };

    /// <summary>Answers an SDK's requests and records them, with their bodies read before the SDK disposes them.</summary>
    private sealed class RecordingHandler(List<(HttpRequestMessage Request, string Body)> requests, Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var body = request.Content is null ? string.Empty : await request.Content.ReadAsStringAsync(cancellationToken);
            requests.Add((request, body));
            var response = respond(request);
            response.RequestMessage = request;
            return response;
        }
    }

    private sealed class FakeAws(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpClientFactory
    {
        public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

        public override HttpClient CreateHttpClient(IClientConfig clientConfig) => new(new RecordingHandler(Requests, respond));

        public override bool UseSDKHttpClientCaching(IClientConfig clientConfig) => false;

        public override bool DisposeHttpClientsAfterUse(IClientConfig clientConfig) => true;
    }

    private sealed class FakeGoogle : Google.Apis.Http.HttpClientFactory
    {
        public List<(HttpRequestMessage Request, string Body)> Requests { get; } = [];

        protected override HttpMessageHandler CreateHandler(Google.Apis.Http.CreateHttpClientArgs args) => new RecordingHandler(Requests, _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"access_token\":\"ya29.cloudsql\",\"expires_in\":3600,\"token_type\":\"Bearer\"}", Encoding.UTF8, "application/json"),
        });
    }
}
