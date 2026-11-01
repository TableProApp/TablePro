using TablePro.Core.Updates;

namespace TablePro.Core.Tests.Updates;

public sealed class UpdatePreferencesTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 2, 8, 0, 0, TimeSpan.Zero);

    [Fact]
    public void DefaultsToStableWithAutomaticChecks()
    {
        var defaults = UpdatePreferences.Deserialize(null);

        Assert.Equal(UpdateChannel.Stable, defaults.Channel);
        Assert.True(defaults.AutomaticallyChecks);
        Assert.Null(defaults.LastCheck);
        Assert.Null(defaults.RolloutGroup);
    }

    [Fact]
    public void RoundTripsEveryField()
    {
        var value = new UpdatePreferences
        {
            Channel = UpdateChannel.Beta,
            AutomaticallyChecks = false,
            LastCheck = Now,
            SkippedVersion = "0.3.0-beta.2",
            RolloutGroup = 4,
        };

        var json = value.Serialize();

        Assert.Contains("\"beta\"", json, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(value, UpdatePreferences.Deserialize(json));
        Assert.Equal(AppVersion.Parse("0.3.0-beta.2"), UpdatePreferences.Deserialize(json).Skipped);
    }

    [Theory]
    [InlineData("{ broken")]
    [InlineData("[]")]
    public void ADamagedFileGivesTheDefaults(string json)
    {
        Assert.Equal(new UpdatePreferences(), UpdatePreferences.Deserialize(json));
    }

    [Fact]
    public void ARolloutGroupOutOfRangeIsDrawnAgain()
    {
        Assert.Null(UpdatePreferences.Deserialize("""{ "rolloutGroup": 9 }""").RolloutGroup);
        Assert.Equal(6, UpdatePreferences.Deserialize("""{ "rolloutGroup": 6 }""").RolloutGroup);
    }

    [Fact]
    public void AScheduledCheckIsDueADayAfterTheLast()
    {
        var checkedNow = new UpdatePreferences { LastCheck = Now };

        Assert.True(new UpdatePreferences().IsCheckDue(Now));
        Assert.False(checkedNow.IsCheckDue(Now.AddHours(23)));
        Assert.True(checkedNow.IsCheckDue(Now.AddHours(24)));
        Assert.True(checkedNow.IsCheckDue(Now.AddDays(-2)));
        Assert.False((checkedNow with { AutomaticallyChecks = false }).IsCheckDue(Now.AddDays(5)));
    }
}
