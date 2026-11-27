using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Model.Tests.QuickSwitcher;

// A port of apple FuzzyMatcherTests, so the Windows palette ranks the same way the macOS quick switcher does.
public sealed class FuzzyMatcherTests
{
    private static int Score(string query, string candidate) => FuzzyMatcher.Match(query, candidate)?.Score ?? 0;

    [Fact]
    public void EmptyQueryReturnsNull()
    {
        Assert.Null(FuzzyMatcher.Match(string.Empty, "users"));
        Assert.Null(FuzzyMatcher.Match(string.Empty, string.Empty));
    }

    [Fact]
    public void EmptyCandidateReturnsNull() => Assert.Null(FuzzyMatcher.Match("abc", string.Empty));

    [Fact]
    public void NonMatchingQueryReturnsNull() => Assert.Null(FuzzyMatcher.Match("xyz", "users"));

    [Fact]
    public void PartialMatchReturnsNull() => Assert.Null(FuzzyMatcher.Match("uzx", "users"));

    [Fact]
    public void QueryLongerThanCandidateReturnsNull() => Assert.Null(FuzzyMatcher.Match("userstable", "users"));

    [Fact]
    public void ExactMatchScoresHigherThanSubstring() => Assert.True(Score("users", "users") > Score("users", "all_users_table"));

    [Fact]
    public void ConsecutiveMatchesScoreHigherThanScattered() => Assert.True(Score("use", "users") > Score("use", "u_s_e"));

    [Fact]
    public void WordBoundaryMatchScoresHigher() => Assert.True(Score("ut", "user_table") > Score("ut", "butter"));

    [Fact]
    public void EarlierMatchPositionScoresHigher() => Assert.True(Score("a", "abc") > Score("a", "xxa"));

    [Fact]
    public void PrefixBeatsInfixOfTheSameLength() => Assert.True(Score("user", "user_roles") > Score("user", "power_user"));

    [Fact]
    public void MatchingIsCaseInsensitive()
    {
        Assert.True(Score("users", "USERS") > 0);
        Assert.True(Score("USERS", "users") > 0);
    }

    [Fact]
    public void ExactCaseScoresHigherThanCrossCase() => Assert.True(Score("Users", "Users") > Score("users", "Users"));

    [Fact]
    public void UnderscoreAbbreviationMatchesWithBoundaryAlignedIndices()
    {
        var match = FuzzyMatcher.Match("uid", "user_id");
        Assert.Equal([0, 5, 6], match!.MatchedIndices);
    }

    [Fact]
    public void CamelCaseAbbreviationPicksBoundaryAlignment()
    {
        var match = FuzzyMatcher.Match("lll", "SVisualLoggerLogsList");
        Assert.Equal([7, 13, 17], match!.MatchedIndices);
    }

    [Fact]
    public void ConsecutiveSubstringReportsContiguousIndices()
    {
        var match = FuzzyMatcher.Match("use", "users");
        Assert.Equal([0, 1, 2], match!.MatchedIndices);
    }

    [Fact]
    public void DollarSignActsAsAWordBoundary() => Assert.True(Score("bp", "v$buffer_pool") > Score("bp", "albpx"));

    [Fact]
    public void SingleCharacterQueryMatches()
    {
        Assert.True(Score("u", "users") > 0);
        Assert.Null(FuzzyMatcher.Match("z", "users"));
    }

    [Fact]
    public void SameInputProducesTheSameResult()
    {
        var first = FuzzyMatcher.Match("ust", "user_settings_table");
        var second = FuzzyMatcher.Match("ust", "user_settings_table");
        Assert.Equal(first!.Score, second!.Score);
        Assert.Equal(first.MatchedIndices, second.MatchedIndices);
    }

    [Fact]
    public void EmojiInQueryBlocksMatchingWhenItCannotMatch() => Assert.Null(FuzzyMatcher.Match("\U0001F389u", "users"));

    [Fact]
    public void EmojiInCandidateHandledAsOneCharacter()
    {
        var match = FuzzyMatcher.Match("ab", "a\U0001F389b");
        Assert.Equal([0, 2], match!.MatchedIndices);
    }

    [Fact]
    public void PureEmojiQueryReturnsNull() => Assert.Null(FuzzyMatcher.Match("\U0001F389\U0001F525", "users"));

    [Fact]
    public void VeryLongCandidatesFallBackToGreedyWithIndices()
    {
        var candidate = string.Concat(Enumerable.Repeat("abcdefghij", 1_000));
        var match = FuzzyMatcher.Match("aej", candidate);
        Assert.NotNull(match);
        Assert.Equal([0, 4, 9], match.MatchedIndices);
    }

    [Fact]
    public void VeryLongQueriesFallBackToGreedy()
    {
        var query = string.Concat(Enumerable.Repeat("ab", 40));
        var candidate = string.Concat(Enumerable.Repeat("ab", 50));
        var match = FuzzyMatcher.Match(query, candidate);
        Assert.NotNull(match);
        Assert.Equal(80, match.MatchedIndices.Count);
    }

    [Fact]
    public void MatchesTrimsAndTreatsAnEmptyQueryAsEverything()
    {
        Assert.True(FuzzyMatcher.Matches("   ", "users"));
        Assert.True(FuzzyMatcher.Matches("us", "users"));
        Assert.False(FuzzyMatcher.Matches("zzz", "users"));
    }
}

// The score-only path must give the same score as Match over a corpus, as the macOS FuzzyMatcherScoreTests pin.
public sealed class FuzzyMatcherScoreTests
{
    private static readonly string LongCandidate = string.Concat(Enumerable.Repeat("ab_", 341)) + "cd";
    private static readonly string LongQuery = new('a', 65);

    private static readonly string[] Queries =
    [
        "u", "us", "USR", "ut", "uT", "a_b", "user", "users", "o", "ord", "ab", "cd", "b.c", "a b", "-", "$", "/",
        "é", "é", "caf", "café", "\U0001F642", "\r\n", "\r", "\n", "K", "K", "i", "İ", "ß", "SS",
        LongQuery, "xyz", " ",
    ];

    private static readonly string[] Candidates =
    [
        "users", "user_table", "UserTable", "all_users", "butter", "u_s_e_r", "orders", "order_items",
        "a b-c.d/e$f_g", "camelCaseName", "ABC", "aBc", "x", string.Empty,
        "café", "café", "emoji\U0001F642name", "line\r\nbreak", "line\nbreak", "cr\ronly",
        "Kelvin", "Kelvin", "İstanbul", "straße", "STRASSE",
        LongCandidate, new string('a', 70), new string('a', 1_024),
    ];

    [Fact]
    public void ScoreEqualsMatchScoreOverACorpus()
    {
        var scratch = new FuzzyScratch();
        foreach (var query in Queries)
        {
            var folded = new FuzzyQuery(query);
            foreach (var candidate in Candidates)
            {
                var expected = FuzzyMatcher.Match(query, candidate)?.Score;
                var actual = FuzzyMatcher.Score(folded, candidate, scratch);
                Assert.True(expected == actual, $"query {query} candidate {candidate}: {expected} != {actual}");
            }
        }
    }

    [Fact]
    public void ALongCandidateAfterAShortOneDoesNotReadTheShortOnesRows()
    {
        var scratch = new FuzzyScratch();
        var query = new FuzzyQuery("ab");
        foreach (var candidate in new[] { "ab", string.Concat(Enumerable.Repeat("xab", 200)), "b_a_b", "ab" })
        {
            Assert.Equal(FuzzyMatcher.Match("ab", candidate)?.Score, FuzzyMatcher.Score(query, candidate, scratch));
        }
    }
}
