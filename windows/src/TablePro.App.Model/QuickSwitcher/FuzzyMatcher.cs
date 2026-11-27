using System.Globalization;

namespace TablePro.App.Model.QuickSwitcher;

public sealed record FuzzyMatch(int Score, IReadOnlyList<int> MatchedIndices);

// A query split into grapheme clusters and folded once, so ranking a catalog against it does not redo that work for
// every candidate (mirror of the macOS FuzzyQuery; the macOS ASCII byte fast-path is folded into the one grapheme path
// here since the recurrence is identical, which FuzzyMatcherScoreTests pins).
public sealed class FuzzyQuery
{
    public FuzzyQuery(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        Text = text;
        Tokens = FuzzyMatcher.Graphemes(text);
        Folded = FuzzyMatcher.Fold(Tokens);
    }

    public string Text { get; }

    internal string[] Tokens { get; }

    internal string[] Folded { get; }
}

// Rows the score-only scorer reuses from one candidate to the next, so a ranking pass allocates them once.
public sealed class FuzzyScratch
{
    private int[] _previousMatch = [];
    private int[] _previousBest = [];
    private int[] _currentMatch = [];
    private int[] _currentBest = [];
    private int[] _bonuses = [];

    internal int[] PreviousMatch => _previousMatch;

    internal int[] PreviousBest => _previousBest;

    internal int[] CurrentMatch => _currentMatch;

    internal int[] CurrentBest => _currentBest;

    internal int[] Bonuses => _bonuses;

    internal void Reserve(int count)
    {
        if (_bonuses.Length >= count)
        {
            return;
        }

        // Every cell a candidate reads is written first, so the starting value does not matter.
        _previousMatch = new int[count];
        _previousBest = new int[count];
        _currentMatch = new int[count];
        _currentBest = new int[count];
        _bonuses = new int[count];
    }

    internal void SwapRows()
    {
        (_previousMatch, _currentMatch) = (_currentMatch, _previousMatch);
        (_previousBest, _currentBest) = (_currentBest, _previousBest);
    }
}

// Fuzzy match and ranking score, a port of apple TableProUtilities/UI/FuzzyMatcher.swift.
public static class FuzzyMatcher
{
    private const int WeightMatch = 16;
    private const int WeightConsecutive = 24;
    private const int WeightFirstCharacter = 28;
    private const int WeightSeparatorBoundary = 20;
    private const int WeightCamelBoundary = 18;
    private const int WeightExactCase = 1;
    private const int WeightGapOpen = -3;
    private const int WeightGapExtension = -1;
    private const int WeightLeadingGapExtension = -1;
    private const int WeightLeadingGapFloor = -8;

    private const int MaxScoredCandidateLength = 1_024;
    private const int MaxScoredQueryLength = 64;
    private const int Invalid = int.MinValue / 4;

    private static readonly HashSet<string> Separators = new(StringComparer.Ordinal) { " ", "_", "-", ".", "/", "$" };

    public static bool Matches(string query, string candidate)
    {
        ArgumentNullException.ThrowIfNull(query);
        var trimmed = query.Trim();
        return trimmed.Length == 0 || Match(trimmed, candidate) is not null;
    }

    public static FuzzyMatch? Match(string query, string candidate)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(candidate);
        var queryTokens = Graphemes(query);
        return CharacterMatch(queryTokens, Fold(queryTokens), Graphemes(candidate), withIndices: true);
    }

    // The score Match gives, without the matched indices, from a query folded once and two reused rows: what ranking a
    // whole catalog per keystroke needs.
    public static int? Score(FuzzyQuery query, string candidate, FuzzyScratch scratch)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentNullException.ThrowIfNull(scratch);
        var candidateTokens = Graphemes(candidate);
        var queryLength = query.Folded.Length;
        var candidateLength = candidateTokens.Length;
        if (queryLength == 0 || candidateLength == 0 || queryLength > candidateLength)
        {
            return null;
        }

        if (candidateLength > MaxScoredCandidateLength || queryLength > MaxScoredQueryLength)
        {
            return CharacterMatch(query.Tokens, query.Folded, candidateTokens, withIndices: false)?.Score;
        }

        var foldedCandidate = Fold(candidateTokens);
        var matchedPrefix = 0;
        foreach (var token in foldedCandidate)
        {
            if (matchedPrefix < queryLength && string.Equals(token, query.Folded[matchedPrefix], StringComparison.Ordinal))
            {
                matchedPrefix++;
            }
        }

        if (matchedPrefix != queryLength)
        {
            return null;
        }

        scratch.Reserve(candidateLength);
        for (var index = 0; index < candidateLength; index++)
        {
            scratch.Bonuses[index] = BoundaryBonus(index, candidateTokens);
        }

        for (var queryIndex = 0; queryIndex < queryLength; queryIndex++)
        {
            var foldedQueryToken = query.Folded[queryIndex];
            var queryToken = query.Tokens[queryIndex];
            var runningGapScore = Invalid;
            for (var candidateIndex = 0; candidateIndex < candidateLength; candidateIndex++)
            {
                var matchScore = Invalid;
                if (string.Equals(foldedQueryToken, foldedCandidate[candidateIndex], StringComparison.Ordinal))
                {
                    int baseScore;
                    if (queryIndex == 0)
                    {
                        baseScore = LeadingGapPenalty(candidateIndex) + scratch.Bonuses[candidateIndex];
                    }
                    else if (candidateIndex > 0)
                    {
                        var viaBoundary = scratch.PreviousBest[candidateIndex - 1] + scratch.Bonuses[candidateIndex];
                        var viaConsecutive = scratch.PreviousMatch[candidateIndex - 1] + WeightConsecutive;
                        baseScore = Math.Max(viaBoundary, viaConsecutive);
                    }
                    else
                    {
                        baseScore = Invalid;
                    }

                    if (IsValid(baseScore))
                    {
                        var caseBonus = string.Equals(queryToken, candidateTokens[candidateIndex], StringComparison.Ordinal)
                            ? WeightExactCase
                            : 0;
                        matchScore = baseScore + WeightMatch + caseBonus;
                    }
                }

                scratch.CurrentMatch[candidateIndex] = matchScore;

                if (candidateIndex > 0)
                {
                    var previousMatch = scratch.CurrentMatch[candidateIndex - 1];
                    var opened = IsValid(previousMatch) ? previousMatch + WeightGapOpen : Invalid;
                    var extended = IsValid(runningGapScore) ? runningGapScore + WeightGapExtension : Invalid;
                    runningGapScore = Math.Max(opened, extended);
                }
                else
                {
                    runningGapScore = Invalid;
                }

                scratch.CurrentBest[candidateIndex] = Math.Max(matchScore, runningGapScore);
            }

            scratch.SwapRows();
        }

        var finalScore = scratch.PreviousBest[candidateLength - 1];
        return IsValid(finalScore) ? finalScore : null;
    }

    private static FuzzyMatch? CharacterMatch(string[] queryTokens, string[] foldedQuery, string[] candidateTokens, bool withIndices)
    {
        if (queryTokens.Length == 0 || candidateTokens.Length == 0 || queryTokens.Length > candidateTokens.Length)
        {
            return null;
        }

        if (candidateTokens.Length > MaxScoredCandidateLength || queryTokens.Length > MaxScoredQueryLength)
        {
            return GreedyMatch(queryTokens, foldedQuery, candidateTokens);
        }

        return OptimalMatch(queryTokens, foldedQuery, candidateTokens, withIndices);
    }

    private static FuzzyMatch? OptimalMatch(string[] queryTokens, string[] foldedQuery, string[] candidateTokens, bool withIndices)
    {
        var queryLength = queryTokens.Length;
        var candidateLength = candidateTokens.Length;
        var foldedCandidate = Fold(candidateTokens);
        var bonuses = BoundaryBonuses(candidateTokens);

        var matchScores = new int[queryLength * candidateLength];
        var bestScores = new int[queryLength * candidateLength];

        for (var queryIndex = 0; queryIndex < queryLength; queryIndex++)
        {
            var runningGapScore = Invalid;
            for (var candidateIndex = 0; candidateIndex < candidateLength; candidateIndex++)
            {
                var cell = (queryIndex * candidateLength) + candidateIndex;
                var matchScore = Invalid;

                if (string.Equals(foldedQuery[queryIndex], foldedCandidate[candidateIndex], StringComparison.Ordinal))
                {
                    int baseScore;
                    if (queryIndex == 0)
                    {
                        baseScore = LeadingGapPenalty(candidateIndex) + bonuses[candidateIndex];
                    }
                    else if (candidateIndex > 0)
                    {
                        var diagonal = cell - candidateLength - 1;
                        var viaBoundary = bestScores[diagonal] + bonuses[candidateIndex];
                        var viaConsecutive = matchScores[diagonal] + WeightConsecutive;
                        baseScore = Math.Max(viaBoundary, viaConsecutive);
                    }
                    else
                    {
                        baseScore = Invalid;
                    }

                    if (IsValid(baseScore))
                    {
                        var caseBonus = string.Equals(queryTokens[queryIndex], candidateTokens[candidateIndex], StringComparison.Ordinal)
                            ? WeightExactCase
                            : 0;
                        matchScore = baseScore + WeightMatch + caseBonus;
                    }
                }

                matchScores[cell] = matchScore;

                if (candidateIndex > 0)
                {
                    var previousMatch = matchScores[cell - 1];
                    var opened = IsValid(previousMatch) ? previousMatch + WeightGapOpen : Invalid;
                    var extended = IsValid(runningGapScore) ? runningGapScore + WeightGapExtension : Invalid;
                    runningGapScore = Math.Max(opened, extended);
                }
                else
                {
                    runningGapScore = Invalid;
                }

                bestScores[cell] = Math.Max(matchScore, runningGapScore);
            }
        }

        var finalScore = bestScores[(queryLength * candidateLength) - 1];
        if (!IsValid(finalScore))
        {
            return null;
        }

        if (!withIndices)
        {
            return new FuzzyMatch(finalScore, []);
        }

        return new FuzzyMatch(finalScore, Traceback(queryTokens, candidateTokens, matchScores, bestScores));
    }

    private static int[] Traceback(string[] queryTokens, string[] candidateTokens, int[] matchScores, int[] bestScores)
    {
        var queryLength = queryTokens.Length;
        var candidateLength = candidateTokens.Length;
        var indices = new int[queryLength];
        var queryIndex = queryLength - 1;
        var candidateIndex = candidateLength - 1;
        var matchRequired = false;

        while (queryIndex >= 0 && candidateIndex >= 0)
        {
            var cell = (queryIndex * candidateLength) + candidateIndex;
            while (!matchRequired && candidateIndex > 0 && matchScores[cell] != bestScores[cell])
            {
                candidateIndex--;
                cell--;
            }

            indices[queryIndex] = candidateIndex;
            if (queryIndex > 0 && candidateIndex > 0)
            {
                var caseBonus = string.Equals(queryTokens[queryIndex], candidateTokens[candidateIndex], StringComparison.Ordinal)
                    ? WeightExactCase
                    : 0;
                var diagonal = cell - candidateLength - 1;
                matchRequired = matchScores[cell] == matchScores[diagonal] + WeightConsecutive + WeightMatch + caseBonus;
            }

            queryIndex--;
            candidateIndex--;
        }

        return indices;
    }

    private static FuzzyMatch? GreedyMatch(string[] queryTokens, string[] foldedQuery, string[] candidateTokens)
    {
        var score = 0;
        var indices = new List<int>(queryTokens.Length);
        var queryIndex = 0;
        var lastMatchIndex = -2;

        for (var candidateIndex = 0; candidateIndex < candidateTokens.Length; candidateIndex++)
        {
            if (queryIndex >= queryTokens.Length)
            {
                break;
            }

            if (!string.Equals(Fold(candidateTokens[candidateIndex]), foldedQuery[queryIndex], StringComparison.Ordinal))
            {
                continue;
            }

            var matchScore = WeightMatch + BoundaryBonus(candidateIndex, candidateTokens);
            if (candidateIndex == lastMatchIndex + 1)
            {
                matchScore += WeightConsecutive;
            }

            if (string.Equals(queryTokens[queryIndex], candidateTokens[candidateIndex], StringComparison.Ordinal))
            {
                matchScore += WeightExactCase;
            }

            if (indices.Count == 0)
            {
                score += LeadingGapPenalty(candidateIndex);
            }
            else
            {
                var gap = candidateIndex - lastMatchIndex - 1;
                if (gap > 0)
                {
                    score += WeightGapOpen + (WeightGapExtension * (gap - 1));
                }
            }

            score += matchScore;
            indices.Add(candidateIndex);
            lastMatchIndex = candidateIndex;
            queryIndex++;
        }

        return queryIndex == queryTokens.Length ? new FuzzyMatch(score, [.. indices]) : null;
    }

    private static int[] BoundaryBonuses(string[] candidateTokens)
    {
        var bonuses = new int[candidateTokens.Length];
        for (var index = 0; index < candidateTokens.Length; index++)
        {
            bonuses[index] = BoundaryBonus(index, candidateTokens);
        }

        return bonuses;
    }

    private static int BoundaryBonus(int index, string[] candidateTokens)
    {
        if (index == 0)
        {
            return WeightFirstCharacter;
        }

        var previous = candidateTokens[index - 1];
        if (Separators.Contains(previous))
        {
            return WeightSeparatorBoundary;
        }

        if (IsLowercase(previous) && IsUppercase(candidateTokens[index]))
        {
            return WeightCamelBoundary;
        }

        return 0;
    }

    private static bool IsLowercase(string token) => token.Length == 1 && char.IsLower(token[0]);

    private static bool IsUppercase(string token) => token.Length == 1 && char.IsUpper(token[0]);

    private static int LeadingGapPenalty(int firstMatchIndex) =>
        Math.Max(WeightLeadingGapFloor, WeightLeadingGapExtension * firstMatchIndex);

    private static bool IsValid(int score) => score > Invalid / 2;

    internal static string[] Fold(string[] tokens)
    {
        var folded = new string[tokens.Length];
        for (var index = 0; index < tokens.Length; index++)
        {
            folded[index] = Fold(tokens[index]);
        }

        return folded;
    }

    private static string Fold(string token) => token.ToLowerInvariant();

    // Grapheme clusters, so an emoji or a combining sequence counts as one character, as a Swift Character does.
    internal static string[] Graphemes(string text)
    {
        if (text.Length == 0)
        {
            return [];
        }

        var tokens = new List<string>(text.Length);
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            tokens.Add((string)enumerator.Current);
        }

        return [.. tokens];
    }
}
