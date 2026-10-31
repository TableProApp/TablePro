using TablePro.Core.Connections;

namespace TablePro.Core.Tests.Connections;

public sealed class EngineBadgeTests
{
    [Fact]
    public void EveryEngineHasItsOwnTwoCharacterBadge()
    {
        var badges = Enum.GetValues<DatabaseEngine>().Select(EngineBadge.For).ToList();

        Assert.All(badges, badge =>
        {
            Assert.Equal(2, badge.Length);
            Assert.DoesNotContain('?', badge);
        });
        Assert.Equal(badges.Count, badges.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }

    [Theory]
    [InlineData(DatabaseEngine.Redis, "Rd")]
    [InlineData(DatabaseEngine.Elasticsearch, "Es")]
    [InlineData(DatabaseEngine.Snowflake, "Sf")]
    [InlineData(DatabaseEngine.PostgreSql, "Pg")]
    public void EnginesThatShowedAPlaceholderNowHaveLetters(DatabaseEngine engine, string expected) =>
        Assert.Equal(expected, EngineBadge.For(engine));
}
