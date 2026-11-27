using System.Globalization;

namespace TablePro.App.Model.QuickSwitcher;

// The weights a port of QuickSwitcherRanking.
public static class PaletteRanking
{
    public const int MaxResults = 200;
    public const int RecentLimit = 10;
    public const double SubtitleMatchPenalty = 0.6;
    public const double KeywordMatchWeight = 1.0;
    public const double FrecencyBoost = 0.5;
    public const double OpenTabBoost = 1.2;
    public const double ContainerMatchWeight = 0.5;
    public const double OtherSchemaWeight = 0.97;
}

// The header a group draws; the view words Recent and a kind section and shows a connection's name as is.
public abstract record PaletteGroupHeader
{
    public static PaletteGroupHeader None { get; } = new NoHeader();

    public static PaletteGroupHeader Recent { get; } = new RecentHeader();

    public static PaletteGroupHeader Section(PaletteItemKind kind) => new SectionHeader(kind);

    public sealed record NoHeader : PaletteGroupHeader;

    public sealed record RecentHeader : PaletteGroupHeader;

    public sealed record SectionHeader(PaletteItemKind Kind) : PaletteGroupHeader;
}

public sealed record PaletteGroup(string Id, PaletteGroupHeader Header, IReadOnlyList<PaletteItem> Items);

public static class PaletteKinds
{
    public static IReadOnlyList<PaletteItemKind> DisplayOrder { get; } =
    [
        PaletteItemKind.Table, PaletteItemKind.View, PaletteItemKind.SystemTable, PaletteItemKind.Database,
        PaletteItemKind.Schema, PaletteItemKind.Procedure, PaletteItemKind.Function, PaletteItemKind.Trigger,
        PaletteItemKind.Type, PaletteItemKind.SavedQuery, PaletteItemKind.History, PaletteItemKind.Connection,
        PaletteItemKind.Command,
    ];

    public static int DisplayIndex(this PaletteItemKind kind)
    {
        var index = DisplayOrder is IList<PaletteItemKind> list ? list.IndexOf(kind) : -1;
        return index < 0 ? DisplayOrder.Count : index;
    }

    public static double RankWeight(this PaletteItemKind kind) => kind switch
    {
        PaletteItemKind.Table => 1.0,
        PaletteItemKind.View => 0.98,
        PaletteItemKind.SystemTable => 0.85,
        PaletteItemKind.Database => 0.95,
        PaletteItemKind.Schema => 0.93,
        PaletteItemKind.Procedure => 0.92,
        PaletteItemKind.Function => 0.92,
        PaletteItemKind.Trigger => 0.91,
        PaletteItemKind.Type => 0.91,
        PaletteItemKind.SavedQuery => 0.9,
        PaletteItemKind.History => 0.7,
        PaletteItemKind.Connection => 0.9,
        PaletteItemKind.Command => 0.88,
        _ => 0.5,
    };
}

// A port of QuickSwitcherViewModel+Ranking.swift: the empty-query groups, the filtered results and the fuzzy scorer.
public static class PaletteRanker
{
    private const int CancellationCheckStride = 1_024;

    private sealed record RankedIndex(double Rank, int KindOrder, int Length, int Index);

    // Recent, then a kind section per kind that has rows, for a scope narrower than All; All shows only Recent, since
    // nothing has been typed. Items are already narrowed to the scope's kinds.
    public static IReadOnlyList<PaletteGroup> EmptyQueryGroups(
        IReadOnlyList<PaletteItem> items,
        PaletteScope scope,
        IReadOnlyList<string> recentKeys,
        Guid connectionId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(items);
        ArgumentNullException.ThrowIfNull(recentKeys);
        var recent = RecentItems(items, recentKeys, connectionId, cancellationToken);
        var recentKeySet = recent.Select(item => item.FrecencyKey).ToHashSet(StringComparer.Ordinal);
        bool IsRecent(PaletteItem item) => item.Belongs(connectionId) && recentKeySet.Contains(item.FrecencyKey);

        var result = new List<PaletteGroup>();
        if (recent.Count > 0)
        {
            result.Add(new PaletteGroup("recent", PaletteGroupHeader.Recent, recent));
        }

        if (scope == PaletteScope.All)
        {
            return result;
        }

        var sections = new Dictionary<PaletteItemKind, List<PaletteItem>>();
        for (var index = 0; index < items.Count; index++)
        {
            if (index % CancellationCheckStride == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            var item = items[index];
            if (IsRecent(item))
            {
                continue;
            }

            if (!sections.TryGetValue(item.Kind, out var list))
            {
                sections[item.Kind] = list = [];
            }

            list.Add(item);
        }

        foreach (var kind in PaletteKinds.DisplayOrder)
        {
            if (!sections.TryGetValue(kind, out var list) || list.Count == 0)
            {
                continue;
            }

            list.Sort(SectionOrder);
            if (list.Count > PaletteRanking.MaxResults)
            {
                list.RemoveRange(PaletteRanking.MaxResults, list.Count - PaletteRanking.MaxResults);
            }

            result.Add(new PaletteGroup($"kind-{kind}", PaletteGroupHeader.Section(kind), list));
        }

        return result;
    }

    // One results group ranked by the fuzzy score times the per-kind, frecency, open-tab and schema weights.
    public static IReadOnlyList<PaletteGroup> FilteredGroups(
        IReadOnlyList<PaletteItem> items,
        string query,
        IReadOnlyDictionary<string, double> frecencyScores,
        Guid connectionId,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(items);
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(frecencyScores);
        var qualified = QualifiedSearchQuery.Parse(query);
        var prefersShorterNames = qualified is null || qualified.Name.Length > 0;
        var scorer = new PaletteScorer(query, qualified);
        var scratch = new FuzzyScratch();
        var ranked = new List<RankedIndex>();

        for (var index = 0; index < items.Count; index++)
        {
            if (index % CancellationCheckStride == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            var item = items[index];
            if (scorer.BestScore(item, scratch) is not { } matchScore)
            {
                continue;
            }

            var recalled = item.Belongs(connectionId) && frecencyScores.TryGetValue(item.FrecencyKey, out var score) ? score : 0;
            var frecency = 1 + (recalled * PaletteRanking.FrecencyBoost);
            var openBoost = item.IsOpenInTab ? PaletteRanking.OpenTabBoost : 1;
            var location = item.IsOutsideBrowsedSchema ? PaletteRanking.OtherSchemaWeight : 1;
            ranked.Add(new RankedIndex(
                matchScore * item.Kind.RankWeight() * frecency * openBoost * location,
                item.Kind.DisplayIndex(),
                prefersShorterNames ? item.Name.Length : 0,
                index));
        }

        cancellationToken.ThrowIfCancellationRequested();

        // A stable order on every key, then the cap: the same rows a stable top-MaxResults heap would keep.
        var kept = ranked
            .OrderByDescending(entry => entry.Rank)
            .ThenBy(entry => entry.KindOrder)
            .ThenBy(entry => entry.Length)
            .ThenBy(entry => items[entry.Index].Name, StringComparer.CurrentCulture)
            .ThenBy(entry => entry.Index)
            .Take(PaletteRanking.MaxResults)
            .ToList();

        if (kept.Count == 0)
        {
            return [];
        }

        // Only the rows shown carry highlighted characters, so only they pay for the traceback.
        var results = kept
            .Select(entry => items[entry.Index] with { MatchedIndices = BestMatch(items[entry.Index], query, qualified)?.Indices ?? [] })
            .ToList();
        return [new PaletteGroup("results", PaletteGroupHeader.None, results)];
    }

    // A dotted query read both ways: the better of the path reading and the plain reading.
    public static (double Score, IReadOnlyList<int> Indices)? BestMatch(PaletteItem item, string query, QualifiedSearchQuery? qualified)
    {
        ArgumentNullException.ThrowIfNull(item);
        ArgumentNullException.ThrowIfNull(query);
        var plain = PlainMatch(item, query);
        if (qualified is null || PathMatch(item, qualified) is not { } path)
        {
            return plain;
        }

        return plain is { } plainMatch && plainMatch.Score >= path.Score ? plain : path;
    }

    private static (double Score, IReadOnlyList<int> Indices)? PathMatch(PaletteItem item, QualifiedSearchQuery query)
    {
        if (query.ContainerPairs(item.SearchLocation) is not { } pairs)
        {
            return null;
        }

        var containerScore = 0.0;
        foreach (var (container, candidate) in pairs)
        {
            if (FuzzyMatcher.Match(container, candidate) is not { } match)
            {
                return null;
            }

            containerScore += match.Score;
        }

        var weightedContainers = containerScore * PaletteRanking.ContainerMatchWeight;
        if (query.Name.Length == 0)
        {
            return (weightedContainers, []);
        }

        if (FuzzyMatcher.Match(query.Name, item.Name) is not { } nameMatch)
        {
            return null;
        }

        return (nameMatch.Score + weightedContainers, nameMatch.MatchedIndices);
    }

    private static (double Score, IReadOnlyList<int> Indices)? PlainMatch(PaletteItem item, string query)
    {
        var nameMatch = FuzzyMatcher.Match(query, item.Name);
        double? subtitleScore = null;
        if (!string.IsNullOrEmpty(item.Keyword) && FuzzyMatcher.Match(query, item.Keyword) is { } keywordMatch)
        {
            subtitleScore = keywordMatch.Score * PaletteRanking.KeywordMatchWeight;
        }

        if (item.Subtitle.Length > 0 && FuzzyMatcher.Match(query, item.Subtitle) is { } subtitleMatch)
        {
            var weighted = subtitleMatch.Score * PaletteRanking.SubtitleMatchPenalty;
            subtitleScore = subtitleScore is { } current ? Math.Max(current, weighted) : weighted;
        }

        return (nameMatch, subtitleScore) switch
        {
            ({ } match, { } score) when score > match.Score => (score, []),
            ({ } match, _) => (match.Score, match.MatchedIndices),
            (null, { } score) => (score, []),
            _ => null,
        };
    }

    private static List<PaletteItem> RecentItems(
        IReadOnlyList<PaletteItem> items,
        IReadOnlyList<string> recentKeys,
        Guid connectionId,
        CancellationToken cancellationToken)
    {
        var rank = new Dictionary<string, int>(StringComparer.Ordinal);
        for (var index = 0; index < recentKeys.Count; index++)
        {
            rank.TryAdd(recentKeys[index], index);
        }

        var ranked = new Dictionary<int, PaletteItem>();
        for (var index = 0; index < items.Count; index++)
        {
            if (index % CancellationCheckStride == 0)
            {
                cancellationToken.ThrowIfCancellationRequested();
            }

            var item = items[index];
            if (!item.Belongs(connectionId) || !rank.TryGetValue(item.FrecencyKey, out var position) || ranked.ContainsKey(position))
            {
                continue;
            }

            ranked[position] = item;
        }

        return ranked
            .OrderBy(pair => pair.Key)
            .Take(PaletteRanking.RecentLimit)
            .Select(pair => pair.Value)
            .ToList();
    }

    private static int SectionOrder(PaletteItem left, PaletteItem right)
    {
        if (left.IsOutsideBrowsedSchema != right.IsOutsideBrowsedSchema)
        {
            return left.IsOutsideBrowsedSchema ? 1 : -1;
        }

        return StringComparer.CurrentCulture.Compare(left.Name, right.Name);
    }
}

// The score PaletteRanker.BestMatch gives, from queries folded once per keystroke and without the matched indices.
internal sealed class PaletteScorer
{
    private readonly FuzzyQuery _plain;
    private readonly List<FuzzyQuery> _containers;
    private readonly FuzzyQuery? _name;

    public PaletteScorer(string query, QualifiedSearchQuery? qualified)
    {
        _plain = new FuzzyQuery(query);
        _containers = qualified?.Containers.Select(container => new FuzzyQuery(container)).ToList() ?? [];
        _name = qualified is null ? null : new FuzzyQuery(qualified.Name);
    }

    public double? BestScore(PaletteItem item, FuzzyScratch scratch)
    {
        var plainScore = PlainScore(item, scratch);
        if (_name is null || PathScore(item, _name, scratch) is not { } path)
        {
            return plainScore;
        }

        return plainScore is { } plain && plain >= path ? plain : path;
    }

    private double? PathScore(PaletteItem item, FuzzyQuery name, FuzzyScratch scratch)
    {
        var location = item.SearchLocation;
        if (_containers.Count > location.Count)
        {
            return null;
        }

        var containerScore = 0.0;
        var offset = location.Count - _containers.Count;
        for (var index = 0; index < _containers.Count; index++)
        {
            if (FuzzyMatcher.Score(_containers[index], location[offset + index], scratch) is not { } score)
            {
                return null;
            }

            containerScore += score;
        }

        var weightedContainers = containerScore * PaletteRanking.ContainerMatchWeight;
        if (name.Text.Length == 0)
        {
            return weightedContainers;
        }

        return FuzzyMatcher.Score(name, item.Name, scratch) is { } nameScore ? nameScore + weightedContainers : null;
    }

    private double? PlainScore(PaletteItem item, FuzzyScratch scratch)
    {
        var nameScore = FuzzyMatcher.Score(_plain, item.Name, scratch);
        double? secondaryScore = null;
        if (!string.IsNullOrEmpty(item.Keyword) && FuzzyMatcher.Score(_plain, item.Keyword, scratch) is { } keywordScore)
        {
            secondaryScore = keywordScore * PaletteRanking.KeywordMatchWeight;
        }

        if (item.Subtitle.Length > 0 && FuzzyMatcher.Score(_plain, item.Subtitle, scratch) is { } subtitleScore)
        {
            var weighted = subtitleScore * PaletteRanking.SubtitleMatchPenalty;
            secondaryScore = Math.Max(secondaryScore ?? weighted, weighted);
        }

        return (nameScore, secondaryScore) switch
        {
            ({ } score, { } secondary) when secondary > score => secondary,
            ({ } score, _) => score,
            (null, { } secondary) => secondary,
            _ => null,
        };
    }
}
