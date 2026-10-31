namespace TablePro.Core.Search;

/// <summary>
/// How often and how lately each item was opened, scored the way the macOS quick switcher ranks recent picks: the last
/// ten openings of an item each weigh by age bucket, so an item opened often this week outranks one opened once a year ago.
/// </summary>
public sealed class Frecency
{
    private const int MaxSamplesPerItem = 10;
    private const int MaxTrackedItems = 100;
    private const double MaxBucketWeight = 100;
    private const double OlderWeight = 10;

    private static readonly (TimeSpan MaxAge, double Weight)[] Buckets =
    [
        (TimeSpan.FromDays(4), 100),
        (TimeSpan.FromDays(14), 70),
        (TimeSpan.FromDays(31), 50),
        (TimeSpan.FromDays(90), 30),
    ];

    private readonly Dictionary<string, List<DateTimeOffset>> _accesses = new(StringComparer.Ordinal);

    public bool IsEmpty => _accesses.Count == 0;

    public void Load(IReadOnlyDictionary<string, IReadOnlyList<DateTimeOffset>>? accesses)
    {
        _accesses.Clear();
        if (accesses is null)
        {
            return;
        }

        foreach (var (id, samples) in accesses)
        {
            if (samples is { Count: > 0 })
            {
                _accesses[id] = samples.OrderBy(s => s).TakeLast(MaxSamplesPerItem).ToList();
            }
        }

        Prune();
    }

    public void Record(string id, DateTimeOffset at)
    {
        if (!_accesses.TryGetValue(id, out var samples))
        {
            samples = [];
            _accesses[id] = samples;
        }

        samples.Add(at);
        if (samples.Count > MaxSamplesPerItem)
        {
            samples.RemoveRange(0, samples.Count - MaxSamplesPerItem);
        }

        Prune();
    }

    /// <summary>A score from 0 for never opened to 1 for opened ten times in the last four days.</summary>
    public double Score(string id, DateTimeOffset now)
    {
        if (!_accesses.TryGetValue(id, out var samples))
        {
            return 0;
        }

        var total = 0.0;
        foreach (var sample in samples)
        {
            var age = now - sample;
            var weight = OlderWeight;
            foreach (var (maxAge, bucketWeight) in Buckets)
            {
                if (age <= maxAge)
                {
                    weight = bucketWeight;
                    break;
                }
            }

            total += weight;
        }

        return Math.Min(1, total / (MaxSamplesPerItem * MaxBucketWeight));
    }

    /// <summary>Item ids, most recently opened first.</summary>
    public IReadOnlyList<string> RecentIds() =>
        _accesses.OrderByDescending(pair => pair.Value[^1]).Select(pair => pair.Key).ToArray();

    public IReadOnlyDictionary<string, IReadOnlyList<DateTimeOffset>> Snapshot() =>
        _accesses.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<DateTimeOffset>)pair.Value.ToArray(), StringComparer.Ordinal);

    // The items opened longest ago go first, so the store stays small however many objects a server has.
    private void Prune()
    {
        if (_accesses.Count <= MaxTrackedItems)
        {
            return;
        }

        foreach (var id in _accesses.OrderBy(pair => pair.Value[^1]).Take(_accesses.Count - MaxTrackedItems).Select(pair => pair.Key).ToArray())
        {
            _accesses.Remove(id);
        }
    }
}
