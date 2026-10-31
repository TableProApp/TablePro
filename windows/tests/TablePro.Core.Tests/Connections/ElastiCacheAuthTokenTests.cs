using TablePro.Core.Connections;

namespace TablePro.Core.Tests.Connections;

public sealed class ElastiCacheAuthTokenTests
{
    // AWS's documented example key pair and the clock the macOS tests sign with.
    private static readonly AwsCredentialSet Credentials = new("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY");
    private static readonly DateTimeOffset Now = DateTimeOffset.FromUnixTimeSeconds(1_440_938_160);

    private static ConnectionProfile Profile(ConnectionAuthSettings? auth) =>
        new() { Name = "c", Engine = DatabaseEngine.Redis, Host = "master.my-cache.abc123.use1.cache.amazonaws.com", Auth = auth };

    [Fact]
    public void TheTokenIsAPresignedConnectForTheCacheWithoutAScheme()
    {
        var token = ElastiCacheAuthToken.Generate(Credentials, "my-cache", "us-east-1", "iam_user", Now);

        Assert.StartsWith("my-cache/?Action=connect&User=iam_user&X-Amz-Algorithm=AWS4-HMAC-SHA256", token, StringComparison.Ordinal);
        Assert.Contains("&X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Felasticache%2Faws4_request&", token, StringComparison.Ordinal);
        Assert.Contains("&X-Amz-Date=20150830T123600Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host&X-Amz-Signature=", token, StringComparison.Ordinal);
        Assert.DoesNotContain("https://", token, StringComparison.Ordinal);
        Assert.DoesNotContain("X-Amz-Security-Token", token, StringComparison.Ordinal);
        Assert.Matches("X-Amz-Signature=[0-9a-f]{64}$", token);
        Assert.Equal(token, ElastiCacheAuthToken.Generate(Credentials, "my-cache", "us-east-1", "iam_user", Now));
    }

    [Fact]
    public void TemporaryCredentialsCarryTheirSessionToken()
    {
        var token = ElastiCacheAuthToken.Generate(Credentials with { SessionToken = "FQoGZXIvYXdzEXAMPLE" }, "my-cache", "us-east-1", "iam_user", Now);

        Assert.Contains("X-Amz-Security-Token=FQoGZXIvYXdzEXAMPLE", token, StringComparison.Ordinal);
    }

    [Fact]
    public void TheSignatureIsTheSigV4OfTheCacheAsHost()
    {
        var token = ElastiCacheAuthToken.Generate(Credentials, "my-cache", "us-east-1", "iam_user", Now);
        var query = token["my-cache/?".Length..token.IndexOf("&X-Amz-Signature=", StringComparison.Ordinal)];
        var expected = AwsSigV4.PresignQuery("GET", "my-cache", "/", [new("Action", "connect"), new("User", "iam_user")], Credentials, "us-east-1", "elasticache", Now, 900, AwsSigV4.EmptyPayloadHash);

        Assert.Equal(expected, token["my-cache/?".Length..]);
        Assert.StartsWith(query, expected, StringComparison.Ordinal);
    }

    [Fact]
    public void TheCacheAndRegionComeFromTheProfile()
    {
        var auth = new ConnectionAuthSettings { AwsElastiCacheName = " my-cache ", AwsRegion = "eu-west-1" };

        Assert.Equal("my-cache", ElastiCacheAuthToken.CacheName(Profile(auth)));
        Assert.Equal("eu-west-1", ElastiCacheAuthToken.SigningRegion(Profile(auth), "us-east-1"));
        Assert.Equal("us-east-1", ElastiCacheAuthToken.SigningRegion(Profile(null), "us-east-1"));
        Assert.Throws<InvalidOperationException>(() => ElastiCacheAuthToken.SigningRegion(Profile(null), null));
        Assert.Throws<InvalidOperationException>(() => ElastiCacheAuthToken.CacheName(Profile(null)));
    }

    [Fact]
    public void AnIamSignInOnRedisUsesATokenAndTls()
    {
        var profile = Profile(new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile });

        Assert.True(profile.UsesSignInToken());
        Assert.False(profile.UsesSecret());
        Assert.Equal(SslMode.Required, profile.EffectiveSslMode());
    }
}
