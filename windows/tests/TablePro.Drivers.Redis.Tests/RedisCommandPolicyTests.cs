using System.Globalization;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Redis.Tests;

public sealed class RedisCommandPolicyTests
{
    private static string? Refusal(string command, bool readOnly = false) =>
        RedisCommandPolicy.Refusal(command, CommandWords.Read(command), readOnly);

    [Theory]
    [InlineData("GET user:1")]
    [InlineData("HGETALL h")]
    [InlineData("SCAN 0 MATCH a* COUNT 100")]
    [InlineData("INFO keyspace")]
    [InlineData("CONFIG GET maxmemory")]
    [InlineData("CLIENT LIST")]
    [InlineData("XREAD COUNT 10 STREAMS s 0")]
    [InlineData("JSON.GET doc $")]
    public void ReadsRunOnReadOnlyConnections(string command) => Assert.Null(Refusal(command, readOnly: true));

    [Theory]
    [InlineData("SET a 1")]
    [InlineData("del a")]
    [InlineData("HSET h f v")]
    [InlineData("FLUSHDB")]
    [InlineData("CONFIG SET maxmemory 1gb")]
    [InlineData("CLIENT KILL ID 3")]
    [InlineData("EVAL \"return 1\" 0")]
    [InlineData("SOMEMODULE.WRITE x")]
    public void WritesAreRefusedOnReadOnlyConnections(string command)
    {
        var refusal = Refusal(command, readOnly: true);

        Assert.NotNull(refusal);
        Assert.Contains("read-only", refusal, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("SET a 1")]
    [InlineData("FLUSHDB")]
    [InlineData("SOMEMODULE.WRITE x")]
    public void WritesRunWhenNotReadOnly(string command) => Assert.Null(Refusal(command));

    [Theory]
    [InlineData("SUBSCRIBE news")]
    [InlineData("psubscribe news.*")]
    [InlineData("MONITOR")]
    [InlineData("BLPOP queue 0")]
    [InlineData("BZPOPMIN z 5")]
    [InlineData("WAIT 1 0")]
    [InlineData("XREAD BLOCK 0 STREAMS s $")]
    [InlineData("XREADGROUP GROUP g c BLOCK 100 STREAMS s >")]
    [InlineData("AUTH user pass")]
    [InlineData("HELLO 3")]
    [InlineData("QUIT")]
    [InlineData("WATCH k")]
    [InlineData("CLIENT REPLY OFF")]
    public void CommandsThatWouldStallTheSharedConnectionAreRefused(string command) => Assert.NotNull(Refusal(command));

    [Fact]
    public void AStreamKeyNamedBlockIsNotTheBlockOption() => Assert.Null(Refusal("XREAD COUNT 1 STREAMS BLOCK 0"));

    [Fact]
    public void EmptyCommandIsRefused() => Assert.NotNull(Refusal("   "));

    [Theory]
    [InlineData("GET a", false)]
    [InlineData("SET a 1", true)]
    [InlineData("SELECT 2", false)]
    [InlineData("UNKNOWNCMD", true)]
    public void ClassifiesWrites(string command, bool write) => Assert.Equal(write, RedisCommandPolicy.IsWrite(command));

    [Fact]
    public void ARefusalFollowsTheUiLanguage()
    {
        var saved = CultureInfo.CurrentUICulture;
        try
        {
            CultureInfo.CurrentUICulture = CultureInfo.GetCultureInfo("fr");

            Assert.Equal("Cette connexion est en lecture seule, SET n\x2019a donc pas été envoyé.", Refusal("set a 1", readOnly: true));
        }
        finally
        {
            CultureInfo.CurrentUICulture = saved;
        }
    }
}
