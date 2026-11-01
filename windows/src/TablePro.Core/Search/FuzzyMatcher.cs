using System.Buffers;
using System.Collections.Immutable;
using System.Runtime.InteropServices;

namespace TablePro.Core.Search;

/// <summary>A query matched in order against a candidate, with the candidate positions each query character took.</summary>
public readonly record struct FuzzyMatch(int Score, ImmutableArray<int> Indices);

/// <summary>
/// Subsequence matching scored like the macOS quick switcher: matches at the start, after a separator or at a
/// camel-case hump score higher, runs score higher than scattered letters, and gaps cost a little. The best
/// alignment is found by dynamic programming; very long inputs fall back to a greedy left-to-right match.
/// </summary>
public static class FuzzyMatcher
{
    private const int Match = 16;
    private const int Consecutive = 24;
    private const int FirstCharacter = 28;
    private const int SeparatorBoundary = 20;
    private const int CamelBoundary = 18;
    private const int ExactCase = 1;
    private const int GapOpen = -3;
    private const int GapExtension = -1;
    private const int LeadingGapExtension = -1;
    private const int LeadingGapFloor = -8;
    private const int MaxScoredCandidateLength = 1024;
    private const int MaxScoredQueryLength = 64;
    private const int Invalid = int.MinValue / 4;
    private const int StackCells = 512;

    /// <summary>True when every character of the trimmed query appears in order in the candidate; an empty query matches all.</summary>
    public static bool Matches(ReadOnlySpan<char> query, ReadOnlySpan<char> candidate)
    {
        var trimmed = query.Trim(' ');
        return trimmed.IsEmpty || TryMatch(trimmed, candidate, out _);
    }

    public static bool TryMatch(ReadOnlySpan<char> query, ReadOnlySpan<char> candidate, out FuzzyMatch match)
    {
        match = default;
        if (query.IsEmpty || candidate.IsEmpty || query.Length > candidate.Length)
        {
            return false;
        }

        return candidate.Length > MaxScoredCandidateLength || query.Length > MaxScoredQueryLength
            ? Greedy(query, candidate, out match)
            : Optimal(query, candidate, out match);
    }

    private static bool Optimal(ReadOnlySpan<char> query, ReadOnlySpan<char> candidate, out FuzzyMatch match)
    {
        var n = candidate.Length;
        var cells = query.Length * n;
        int[]? rented = null;
        var buffer = cells * 2 <= StackCells ? stackalloc int[cells * 2] : (rented = ArrayPool<int>.Shared.Rent(cells * 2)).AsSpan(0, cells * 2);
        try
        {
            var matchScores = buffer[..cells];
            var bestScores = buffer[cells..];
            for (var q = 0; q < query.Length; q++)
            {
                var foldedQuery = char.ToLowerInvariant(query[q]);
                var runningGap = Invalid;
                for (var c = 0; c < n; c++)
                {
                    var cell = q * n + c;
                    var score = Invalid;
                    if (foldedQuery == char.ToLowerInvariant(candidate[c]))
                    {
                        int start;
                        if (q == 0)
                        {
                            start = LeadingGapPenalty(c) + BoundaryBonus(candidate, c);
                        }
                        else if (c > 0)
                        {
                            var diagonal = cell - n - 1;
                            start = Math.Max(bestScores[diagonal] + BoundaryBonus(candidate, c), matchScores[diagonal] + Consecutive);
                        }
                        else
                        {
                            start = Invalid;
                        }

                        if (IsValid(start))
                        {
                            score = start + Match + (query[q] == candidate[c] ? ExactCase : 0);
                        }
                    }

                    matchScores[cell] = score;
                    if (c > 0)
                    {
                        var previous = matchScores[cell - 1];
                        var opened = IsValid(previous) ? previous + GapOpen : Invalid;
                        var extended = IsValid(runningGap) ? runningGap + GapExtension : Invalid;
                        runningGap = Math.Max(opened, extended);
                    }
                    else
                    {
                        runningGap = Invalid;
                    }

                    bestScores[cell] = Math.Max(score, runningGap);
                }
            }

            var final = bestScores[cells - 1];
            if (!IsValid(final))
            {
                match = default;
                return false;
            }

            match = new FuzzyMatch(final, Traceback(query, candidate, matchScores, bestScores));
            return true;
        }
        finally
        {
            if (rented is not null)
            {
                ArrayPool<int>.Shared.Return(rented);
            }
        }
    }

    private static ImmutableArray<int> Traceback(ReadOnlySpan<char> query, ReadOnlySpan<char> candidate, ReadOnlySpan<int> matchScores, ReadOnlySpan<int> bestScores)
    {
        var n = candidate.Length;
        var indices = new int[query.Length];
        var q = query.Length - 1;
        var c = n - 1;
        var matchRequired = false;
        while (q >= 0 && c >= 0)
        {
            var cell = q * n + c;
            while (!matchRequired && c > 0 && matchScores[cell] != bestScores[cell])
            {
                c--;
                cell--;
            }

            indices[q] = c;
            if (q > 0 && c > 0)
            {
                var caseBonus = query[q] == candidate[c] ? ExactCase : 0;
                matchRequired = matchScores[cell] == matchScores[cell - n - 1] + Consecutive + Match + caseBonus;
            }

            q--;
            c--;
        }

        return ImmutableCollectionsMarshal.AsImmutableArray(indices);
    }

    private static bool Greedy(ReadOnlySpan<char> query, ReadOnlySpan<char> candidate, out FuzzyMatch match)
    {
        var indices = new int[query.Length];
        var score = 0;
        var q = 0;
        var last = -2;
        for (var c = 0; c < candidate.Length && q < query.Length; c++)
        {
            if (char.ToLowerInvariant(candidate[c]) != char.ToLowerInvariant(query[q]))
            {
                continue;
            }

            var gain = Match + BoundaryBonus(candidate, c) + (c == last + 1 ? Consecutive : 0) + (query[q] == candidate[c] ? ExactCase : 0);
            if (q == 0)
            {
                score += LeadingGapPenalty(c);
            }
            else if (c - last - 1 is var gap and > 0)
            {
                score += GapOpen + GapExtension * (gap - 1);
            }

            score += gain;
            indices[q++] = c;
            last = c;
        }

        match = q == query.Length ? new FuzzyMatch(score, ImmutableCollectionsMarshal.AsImmutableArray(indices)) : default;
        return q == query.Length;
    }

    private static int BoundaryBonus(ReadOnlySpan<char> candidate, int index)
    {
        if (index == 0)
        {
            return FirstCharacter;
        }

        var previous = candidate[index - 1];
        if (previous is ' ' or '_' or '-' or '.' or '/' or '$')
        {
            return SeparatorBoundary;
        }

        return char.IsLower(previous) && char.IsUpper(candidate[index]) ? CamelBoundary : 0;
    }

    private static int LeadingGapPenalty(int firstMatch) => Math.Max(LeadingGapFloor, LeadingGapExtension * firstMatch);

    private static bool IsValid(int score) => score > Invalid / 2;
}
