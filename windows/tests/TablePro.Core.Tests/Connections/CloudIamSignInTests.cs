using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Core.Tests.Connections;

public sealed class CloudIamSignInTests
{
    private static ConnectionProfile Redshift(string host = "analytics.abc123.us-east-1.redshift.amazonaws.com", string? user = "etl") => new()
    {
        Name = "r",
        Engine = DatabaseEngine.Redshift,
        Host = host,
        Username = user,
        Database = "dev",
        Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile },
    };

    [Fact]
    public void GoogleCloudIamIsOfferedWhereCloudSqlSignsInIamUsers()
    {
        Assert.Contains(SignInMethod.GoogleCloudApplicationDefault, SignInMethods.Available(DatabaseEngine.PostgreSql));
        Assert.Contains(SignInMethod.GoogleCloudServiceAccount, SignInMethods.Available(DatabaseEngine.MySql));
        Assert.DoesNotContain(SignInMethod.GoogleCloudApplicationDefault, SignInMethods.Available(DatabaseEngine.MariaDb));
        Assert.DoesNotContain(SignInMethod.GoogleCloudApplicationDefault, SignInMethods.Available(DatabaseEngine.SqlServer));
        Assert.Equal([SignInMethod.Password, SignInMethod.AwsIamAccessKey, SignInMethod.AwsIamProfile, SignInMethod.AwsIamSso], SignInMethods.Available(DatabaseEngine.Redshift));
    }

    [Theory]
    [InlineData(SignInMethod.GoogleCloudApplicationDefault, false)]
    [InlineData(SignInMethod.GoogleCloudServiceAccount, true)]
    public void GoogleSignInSendsATokenAndOnlyTheKeyIsASecret(SignInMethod method, bool secret)
    {
        var profile = new ConnectionProfile { Name = "g", Engine = DatabaseEngine.PostgreSql, Host = "10.0.0.5", SslMode = SslMode.Preferred, Auth = new ConnectionAuthSettings { Method = method } };

        Assert.True(profile.UsesSignInToken());
        Assert.Equal(secret, profile.UsesSecret());
        Assert.True(profile.UsesUsername());
        Assert.Equal(SslMode.Required, profile.EffectiveSslMode());
        Assert.False(profile.IssuesSignInUser());
    }

    [Fact]
    public void OnlyRedshiftIamIssuesTheUser()
    {
        Assert.True(Redshift().IssuesSignInUser());
        Assert.True(Redshift().UsesSignInToken());
        Assert.False((Redshift() with { Auth = null }).IssuesSignInUser());
        Assert.False((Redshift() with { Engine = DatabaseEngine.PostgreSql }).IssuesSignInUser());
    }

    [Theory]
    [InlineData("analytics.abc123.us-east-1.redshift.amazonaws.com", RedshiftEndpointKind.Cluster, "analytics", "us-east-1")]
    [InlineData("Analytics.ABC123.eu-west-2.redshift.amazonaws.com.", RedshiftEndpointKind.Cluster, "analytics", "eu-west-2")]
    [InlineData("reports.123456789012.us-west-2.redshift-serverless.amazonaws.com", RedshiftEndpointKind.Serverless, "reports", "us-west-2")]
    [InlineData("wh.abc.cn-north-1.redshift.amazonaws.com.cn", RedshiftEndpointKind.Cluster, "wh", "cn-north-1")]
    public void RedshiftEndpointsAreReadFromTheNamesAwsIssues(string host, RedshiftEndpointKind kind, string identifier, string region)
    {
        Assert.Equal(new RedshiftEndpoint(kind, identifier, region), RedshiftAuth.ParseHost(host));
    }

    [Theory]
    [InlineData("db.abc.us-east-1.rds.amazonaws.com")]
    [InlineData("analytics.abc123.us-east-1.redshift.example.com")]
    [InlineData("wh.abc.cn-north-1.redshift.amazonaws.com")]
    [InlineData("redshift.amazonaws.com")]
    [InlineData("localhost")]
    [InlineData("")]
    public void OtherHostsAreNotRedshiftEndpoints(string host)
    {
        Assert.Null(RedshiftAuth.ParseHost(host));
    }

    [Fact]
    public void TheEndpointOverrideAppliesOnlyToAForwardOrTheSameHost()
    {
        var forwarded = Redshift("127.0.0.1") with { Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile, AwsRedshiftEndpoint = "https://wg.123.us-east-2.redshift-serverless.amazonaws.com:5439/dev" } };
        Assert.Equal(new RedshiftEndpoint(RedshiftEndpointKind.Serverless, "wg", "us-east-2"), RedshiftAuth.ResolveEndpoint(forwarded));

        var elsewhere = forwarded with { Host = "proxy.example.com" };
        Assert.Throws<InvalidOperationException>(() => RedshiftAuth.ResolveEndpoint(elsewhere));

        var invalid = forwarded with { Auth = forwarded.Auth! with { AwsRedshiftEndpoint = "db.example.com" } };
        Assert.Throws<InvalidOperationException>(() => RedshiftAuth.ResolveEndpoint(invalid));

        Assert.Equal("analytics", RedshiftAuth.ResolveEndpoint(Redshift()).Identifier);
        Assert.Throws<InvalidOperationException>(() => RedshiftAuth.ResolveEndpoint(Redshift("db.example.com")));
    }

    [Theory]
    [InlineData("us-east-1", "amazonaws.com")]
    [InlineData("cn-northwest-1", "amazonaws.com.cn")]
    [InlineData("us-gov-west-1", "amazonaws.com")]
    [InlineData("us-isob-east-1", "sc2s.sgov.gov")]
    [InlineData("eusc-de-east-1", "amazonaws.eu")]
    public void PartitionsHaveTheirOwnDnsSuffix(string region, string suffix)
    {
        Assert.Equal(suffix, RedshiftAuth.DnsSuffix(region));
    }

    [Fact]
    public async Task PrepareCarriesTheIssuedUserAndRemembersTheRequestedOne()
    {
        var provider = new IssuingProvider();
        var request = ConnectionRequest.Direct(Redshift(), "secret");

        var prepared = await SignInTokens.PrepareAsync(request, provider, TestContext.Current.CancellationToken);

        Assert.Equal("IAM:etl", prepared.Profile.Username);
        Assert.Equal(new RedshiftIssuedUser("etl"), prepared.Profile.Auth!.RedshiftIssued);
        Assert.Equal("secret", prepared.Password);
        Assert.Equal("etl", RedshiftAuth.RequestedUser(prepared.Profile));
        Assert.Equal("secret", provider.LastSecret);

        // A reconnect with the prepared request, or a later refresh, asks for the same user again.
        Assert.Same(prepared, await SignInTokens.PrepareAsync(prepared, provider, TestContext.Current.CancellationToken));
        Assert.Equal(1, provider.Calls);
    }

    [Fact]
    public async Task PrepareLetsRedshiftPickTheUserWhenNoneIsNamed()
    {
        var prepared = await SignInTokens.PrepareAsync(ConnectionRequest.Direct(Redshift(user: " "), null), new IssuingProvider(), TestContext.Current.CancellationToken);

        Assert.Equal("IAMR:role", prepared.Profile.Username);
        Assert.Null(RedshiftAuth.RequestedUser(prepared.Profile));
    }

    [Fact]
    public async Task PreparePassesOtherSignInsThrough()
    {
        var request = ConnectionRequest.Direct(Redshift() with { Engine = DatabaseEngine.PostgreSql }, "p");

        Assert.Same(request, await SignInTokens.PrepareAsync(request, null, TestContext.Current.CancellationToken));
        await Assert.ThrowsAsync<InvalidOperationException>(async () => await SignInTokens.PrepareAsync(ConnectionRequest.Direct(Redshift(), null), null, TestContext.Current.CancellationToken));
    }

    [Fact]
    public void TheIssuedUserIsNeverSaved()
    {
        var auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile, RedshiftIssued = new RedshiftIssuedUser("etl") };

        var json = System.Text.Json.JsonSerializer.Serialize(auth);

        Assert.DoesNotContain("RedshiftIssued", json, StringComparison.Ordinal);
    }

    private sealed class IssuingProvider : ISignInTokenProvider
    {
        public int Calls { get; private set; }

        public string? LastSecret { get; private set; }

        public ValueTask<string> GetTokenAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken) => ValueTask.FromResult("password");

        public ValueTask<SignInCredentials> SignInAsync(ConnectionProfile profile, string? secret, CancellationToken cancellationToken)
        {
            Calls++;
            LastSecret = secret;
            var user = RedshiftAuth.RequestedUser(profile);
            return ValueTask.FromResult(new SignInCredentials(user is null ? "IAMR:role" : "IAM:" + user, "password"));
        }
    }
}
