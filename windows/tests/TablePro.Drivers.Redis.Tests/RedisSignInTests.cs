using TablePro.Core.Connections;
using TablePro.Core.Drivers;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisSignInTests
{
    private static ConnectionProfile ElastiCache(SslMode ssl = SslMode.Disabled) => new()
    {
        Name = "cache",
        Engine = DatabaseEngine.Redis,
        Host = "master.my-cache.abc123.use1.cache.amazonaws.com",
        Username = "iam-user",
        SslMode = ssl,
        Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamAccessKey, AwsAccessKeyId = "AKID", AwsRegion = "us-east-1", AwsElastiCacheName = "my-cache" },
    };

    [Fact]
    public async Task TheTokenTakesThePasswordsPlaceAndTheSecretKeyNeverReachesTheServer()
    {
        var signIn = new RedisSignInPassword(_ => ValueTask.FromResult("token-1"));
        await signIn.RefreshAsync(TestContext.Current.CancellationToken);

        var options = RedisConnectionOptions.Plan(ConnectionRequest.Direct(ElastiCache(), "secret-access-key"), signIn).Data;

        Assert.Equal("token-1", options.Password);
        Assert.Equal("iam-user", options.User);
        Assert.DoesNotContain("secret-access-key", options.ToString(includePassword: true), StringComparison.Ordinal);
    }

    [Fact]
    public async Task EachConnectionReadsTheNewestToken()
    {
        var minted = 0;
        var signIn = new RedisSignInPassword(_ => ValueTask.FromResult("token-" + ++minted));
        var options = RedisConnectionOptions.Plan(ConnectionRequest.Direct(ElastiCache(), "secret"), signIn).Data;

        await signIn.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal("token-1", options.Password);
        await signIn.RefreshAsync(TestContext.Current.CancellationToken);
        Assert.Equal("token-2", options.Password);
    }

    [Fact]
    public void AnIamSignInTurnsTlsOn()
    {
        var signIn = new RedisSignInPassword(_ => ValueTask.FromResult("t"));

        Assert.True(RedisConnectionOptions.Plan(ConnectionRequest.Direct(ElastiCache(SslMode.Disabled), "s"), signIn).Data.Ssl);
        Assert.False(RedisConnectionOptions.Plan(ConnectionRequest.Direct(ElastiCache() with { Auth = null }, "pw")).Data.Ssl);
    }

    [Fact]
    public void APasswordSignInSendsThePassword()
    {
        var options = RedisConnectionOptions.Plan(ConnectionRequest.Direct(ElastiCache() with { Auth = null }, "pw")).Data;

        Assert.Equal("pw", options.Password);
    }

    [Fact]
    public async Task DisposingStopsTheRefresh()
    {
        var signIn = new RedisSignInPassword(_ => ValueTask.FromResult("t"));

        await signIn.DisposeAsync();
    }
}
