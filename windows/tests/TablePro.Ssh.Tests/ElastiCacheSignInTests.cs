using TablePro.Core.Connections;
using TablePro.Ssh.SignIn;

namespace TablePro.Ssh.Tests;

public sealed class ElastiCacheSignInTests
{
    private sealed class FixedTime(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private static ConnectionProfile Redis(string? cache, string? region = "us-east-1") => new()
    {
        Name = "cache",
        Engine = DatabaseEngine.Redis,
        Host = "master.my-cache.abc123.use1.cache.amazonaws.com",
        Username = "iam_user",
        Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamAccessKey, AwsAccessKeyId = "AKIDEXAMPLE", AwsRegion = region, AwsElastiCacheName = cache },
    };

    [Fact]
    public async Task ARedisProfileGetsAnElastiCacheTokenForItsCache()
    {
        var now = new DateTimeOffset(2026, 10, 29, 9, 0, 0, TimeSpan.Zero);
        var provider = new CloudSignInTokenProvider(new FixedTime(now));

        var token = await provider.GetTokenAsync(Redis("my-cache"), "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", TestContext.Current.CancellationToken);

        Assert.Equal(
            ElastiCacheAuthToken.Generate(new AwsCredentialSet("AKIDEXAMPLE", "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), "my-cache", "us-east-1", "iam_user", now),
            token);
    }

    [Fact]
    public async Task WithoutACacheNameOrRegionTheSignInSaysWhatIsMissing()
    {
        var provider = new CloudSignInTokenProvider();

        var noCache = await Assert.ThrowsAsync<InvalidOperationException>(() => provider.GetTokenAsync(Redis(null), "secret", TestContext.Current.CancellationToken).AsTask());
        Assert.Contains("ElastiCache cache name", noCache.Message, StringComparison.Ordinal);
        var noRegion = await Assert.ThrowsAsync<InvalidOperationException>(() => provider.GetTokenAsync(Redis("my-cache", null), "secret", TestContext.Current.CancellationToken).AsTask());
        Assert.Contains("AWS region", noRegion.Message, StringComparison.Ordinal);
    }
}
