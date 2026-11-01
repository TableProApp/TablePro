using TablePro.Core.Search;

namespace TablePro.Core.Tests.Search;

public sealed class FuzzyMatcherTests
{
    [Theory]
    [InlineData("", "users")]
    [InlineData("abc", "")]
    [InlineData("xyz", "users")]
    [InlineData("uzx", "users")]
    [InlineData("userstable", "users")]
    [InlineData("z", "users")]
    [InlineData("🎉u", "users")]
    public void NoMatch(string query, string candidate) => Assert.False(FuzzyMatcher.TryMatch(query, candidate, out _));

    [Theory]
    [InlineData("users", "users", "all_users_table")]
    [InlineData("use", "users", "u_s_e")]
    [InlineData("ut", "user_table", "butter")]
    [InlineData("a", "abc", "xxa")]
    [InlineData("user", "user_roles", "power_user")]
    [InlineData("bp", "v$buffer_pool", "albpx")]
    public void RanksBetterCandidateHigher(string query, string better, string worse) =>
        Assert.True(Score(query, better) > Score(query, worse));

    [Fact]
    public void IgnoresCaseButPrefersExactCase()
    {
        Assert.True(Score("users", "USERS") > 0);
        Assert.True(Score("USERS", "users") > 0);
        Assert.True(Score("Users", "Users") > Score("users", "Users"));
    }

    [Theory]
    [InlineData("uid", "user_id", new[] { 0, 5, 6 })]
    [InlineData("lll", "SVisualLoggerLogsList", new[] { 7, 13, 17 })]
    [InlineData("use", "users", new[] { 0, 1, 2 })]
    [InlineData("ab", "a🎉b", new[] { 0, 3 })]
    public void ReportsBoundaryAlignedIndices(string query, string candidate, int[] expected)
    {
        Assert.True(FuzzyMatcher.TryMatch(query, candidate, out var match));
        Assert.Equal(expected, match.Indices);
    }

    [Fact]
    public void IsDeterministic()
    {
        FuzzyMatcher.TryMatch("ust", "user_settings_table", out var first);
        FuzzyMatcher.TryMatch("ust", "user_settings_table", out var second);
        Assert.Equal(first.Score, second.Score);
        Assert.Equal(first.Indices, second.Indices);
    }

    [Fact]
    public void LongInputsFallBackToGreedyMatching()
    {
        Assert.True(FuzzyMatcher.TryMatch("aej", string.Concat(Enumerable.Repeat("abcdefghij", 1000)), out var longCandidate));
        Assert.Equal([0, 4, 9], longCandidate.Indices);

        Assert.True(FuzzyMatcher.TryMatch(string.Concat(Enumerable.Repeat("ab", 40)), string.Concat(Enumerable.Repeat("ab", 50)), out var longQuery));
        Assert.Equal(80, longQuery.Indices.Length);
    }

    [Fact]
    public void EmptyQueryMatchesEverything() => Assert.True(FuzzyMatcher.Matches("  ", "users"));

    private static int Score(string query, string candidate) =>
        FuzzyMatcher.TryMatch(query, candidate, out var match) ? match.Score : int.MinValue;
}
