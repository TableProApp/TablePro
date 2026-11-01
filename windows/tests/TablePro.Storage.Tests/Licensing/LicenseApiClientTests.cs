using System.Net;
using System.Text;
using System.Text.Json;
using TablePro.Core.Licensing;
using TablePro.Storage.Licensing;

namespace TablePro.Storage.Tests.Licensing;

public sealed class LicenseApiClientTests
{
    private static readonly LicenseClientRequest Request = new("AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", "machine", "DESKTOP", "1.0.0", "Windows");

    private static (HttpLicenseApiClient Client, Handler Handler) Create(HttpStatusCode status, string body)
    {
        var handler = new Handler(status, body);
        return (new HttpLicenseApiClient(new HttpClient(handler)) { BaseAddress = new Uri("https://license.test/v1/license/") }, handler);
    }

    [Fact]
    public async Task ActivationPostsTheMacOSRequestAndReadsTheSignedPayload()
    {
        var (client, handler) = Create(HttpStatusCode.OK, """
            {"data":{"billing_cycle":"yearly","license_key":"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE","email":"user@example.com","status":"active","expires_at":null,"issued_at":"2026-01-01T00:00:00Z","tier":"starter","machine_id":"machine"},"signature":"c2ln"}
            """);

        var signed = await client.ActivateAsync(Request, TestContext.Current.CancellationToken);

        Assert.Equal("https://license.test/v1/license/activate", handler.LastUri?.AbsoluteUri);
        Assert.Equal(HttpMethod.Post, handler.LastMethod);
        using var sent = JsonDocument.Parse(handler.LastBody!);
        Assert.Equal(
            ["app_version", "license_key", "machine_id", "machine_name", "os_version"],
            sent.RootElement.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal));
        Assert.Equal("machine", signed.Data.MachineId);
        Assert.Equal("c2ln", signed.Signature);
    }

    [Theory]
    [InlineData("accept-invite")]
    [InlineData("validate")]
    [InlineData("activations")]
    [InlineData("team")]
    [InlineData("deactivate")]
    public async Task EachCallUsesItsMacOSEndpoint(string endpoint)
    {
        var body = endpoint switch
        {
            "activations" => """{"activations":[{"machine_id":"m","machine_name":"n","app_version":"1","os_version":"o","last_validated_at":null,"created_at":"2026-01-01T00:00:00Z"}],"max_activations":3}""",
            "team" => """{"members":[{"email":"a@b.c","role":"owner","joined_at":null}],"seats_used":1,"max_seats":5}""",
            "deactivate" => """{"message":"Deactivated"}""",
            _ => """{"data":{"license_key":"K","email":"e","status":"active","issued_at":"2026-01-01T00:00:00Z","tier":"team"},"signature":"c2ln"}""",
        };
        var (client, handler) = Create(HttpStatusCode.OK, body);
        var token = TestContext.Current.CancellationToken;

        switch (endpoint)
        {
            case "accept-invite":
                await client.AcceptInviteAsync(new LicenseInviteRequest("INVITE", "m", "n", "1", "o"), token);
                break;
            case "validate":
                await client.ValidateAsync(Request, token);
                break;
            case "activations":
                Assert.Equal(3, (await client.ListActivationsAsync(Request, token)).MaxActivations);
                break;
            case "team":
                Assert.Equal(5, (await client.TeamAsync(Request, token)).MaxSeats);
                break;
            default:
                await client.DeactivateAsync(new LicenseDeactivationRequest("K", "m"), token);
                break;
        }

        Assert.Equal("https://license.test/v1/license/" + endpoint, handler.LastUri?.AbsoluteUri);
    }

    [Theory]
    [InlineData(404, """{"message":"License not found"}""", LicenseErrorKind.InvalidKey)]
    [InlineData(404, "<html>captive portal</html>", LicenseErrorKind.Server)]
    [InlineData(409, """{"message":"Limit"}""", LicenseErrorKind.ActivationLimitReached)]
    [InlineData(403, """{"message":"License is suspended"}""", LicenseErrorKind.LicenseSuspended)]
    [InlineData(403, """{"message":"License has expired"}""", LicenseErrorKind.LicenseExpired)]
    [InlineData(403, """{"message":"Machine not activated"}""", LicenseErrorKind.NotActivated)]
    [InlineData(403, """{"message":"Something else"}""", LicenseErrorKind.Server)]
    [InlineData(403, "", LicenseErrorKind.Server)]
    [InlineData(422, """{"message":"The license key format is invalid."}""", LicenseErrorKind.Server)]
    [InlineData(500, "", LicenseErrorKind.Server)]
    public async Task StatusCodesMapAsTheMacOSClientReadsThem(int status, string body, LicenseErrorKind expected)
    {
        var (client, _) = Create((HttpStatusCode)status, body);

        var error = await Assert.ThrowsAsync<LicenseException>(() => client.ValidateAsync(Request, TestContext.Current.CancellationToken));

        Assert.Equal(expected, error.Kind);
        Assert.Equal(status, error.StatusCode);
    }

    [Fact]
    public async Task AnUnreadableSuccessIsADecodingError()
    {
        var (client, _) = Create(HttpStatusCode.OK, "{}");

        Assert.Equal(LicenseErrorKind.Decoding, (await Assert.ThrowsAsync<LicenseException>(() => client.ValidateAsync(Request, TestContext.Current.CancellationToken))).Kind);
    }

    [Fact]
    public async Task AnUnreachableServerIsANetworkError()
    {
        var client = new HttpLicenseApiClient(new HttpClient(new Handler(new HttpRequestException("no route"))));

        Assert.Equal(LicenseErrorKind.Network, (await Assert.ThrowsAsync<LicenseException>(() => client.ValidateAsync(Request, TestContext.Current.CancellationToken))).Kind);
    }

    private sealed class Handler : HttpMessageHandler
    {
        private readonly HttpStatusCode _status;
        private readonly string _body;
        private readonly Exception? _failure;

        public Handler(HttpStatusCode status, string body)
        {
            _status = status;
            _body = body;
        }

        public Handler(Exception failure)
        {
            _body = string.Empty;
            _failure = failure;
        }

        public Uri? LastUri { get; private set; }

        public HttpMethod? LastMethod { get; private set; }

        public string? LastBody { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (_failure is not null)
            {
                throw _failure;
            }

            LastUri = request.RequestUri;
            LastMethod = request.Method;
            LastBody = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
            return new HttpResponseMessage(_status) { Content = new StringContent(_body, Encoding.UTF8, "application/json") };
        }
    }
}
