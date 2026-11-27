using System.Text.Json.Serialization;

namespace TablePro.App.Model.QuickSwitcher;

// Per-connection recent and frecency, a port of apple QuickSwitcherFrecencyStore. Kept in one JSON file beside the app
// settings, device-local and never synced; a path is injected so the tests run anywhere.
public sealed class PaletteFrecencyStore
{
    private const int MaxSamplesPerItem = 10;
    private const int MaxTrackedItems = 100;
    private const double MaxBucketWeight = 100;

    private static readonly (double MaxAge, double Weight)[] RecencyBuckets =
    [
        (4 * 86_400, 100),
        (14 * 86_400, 70),
        (31 * 86_400, 50),
        (90 * 86_400, 30),
    ];

    private const double OlderThanBucketsWeight = 10;

    private readonly string _path;

    public PaletteFrecencyStore(string path)
    {
        ArgumentNullException.ThrowIfNull(path);
        _path = path;
    }

    public void RecordAccess(Guid connectionId, string itemId, DateTimeOffset? at = null)
    {
        ArgumentException.ThrowIfNullOrEmpty(itemId);
        var when = (at ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        var file = Load();
        if (!file.Connections.TryGetValue(Key(connectionId), out var accesses))
        {
            file.Connections[Key(connectionId)] = accesses = new Dictionary<string, List<double>>(StringComparer.Ordinal);
        }

        if (!accesses.TryGetValue(itemId, out var samples))
        {
            accesses[itemId] = samples = [];
        }

        samples.Add(when);
        if (samples.Count > MaxSamplesPerItem)
        {
            samples.RemoveRange(0, samples.Count - MaxSamplesPerItem);
        }

        if (accesses.Count > MaxTrackedItems)
        {
            Prune(accesses);
        }

        Save(file);
    }

    public IReadOnlyDictionary<string, double> Scores(Guid connectionId, DateTimeOffset? now = null)
    {
        var reference = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds() / 1000.0;
        var accesses = Load().Connections.GetValueOrDefault(Key(connectionId));
        if (accesses is null)
        {
            return new Dictionary<string, double>(StringComparer.Ordinal);
        }

        var scores = new Dictionary<string, double>(StringComparer.Ordinal);
        foreach (var (itemId, samples) in accesses)
        {
            scores[itemId] = Score(samples, reference);
        }

        return scores;
    }

    public IReadOnlyList<string> RecentItemIds(Guid connectionId)
    {
        var accesses = Load().Connections.GetValueOrDefault(Key(connectionId));
        if (accesses is null)
        {
            return [];
        }

        return accesses
            .Where(pair => pair.Value.Count > 0)
            .OrderByDescending(pair => pair.Value.Max())
            .Select(pair => pair.Key)
            .ToList();
    }

    public void ClearHistory(Guid connectionId)
    {
        var file = Load();
        if (file.Connections.Remove(Key(connectionId)))
        {
            Save(file);
        }
    }

    private static double Score(List<double> samples, double reference)
    {
        var total = 0.0;
        foreach (var sample in samples)
        {
            var age = reference - sample;
            var weight = OlderThanBucketsWeight;
            foreach (var bucket in RecencyBuckets)
            {
                if (age <= bucket.MaxAge)
                {
                    weight = bucket.Weight;
                    break;
                }
            }

            total += weight;
        }

        return Math.Min(1, total / (MaxSamplesPerItem * MaxBucketWeight));
    }

    private static void Prune(Dictionary<string, List<double>> accesses)
    {
        var kept = accesses
            .OrderByDescending(pair => pair.Value.Count > 0 ? pair.Value.Max() : 0)
            .Take(MaxTrackedItems)
            .ToList();
        accesses.Clear();
        foreach (var (itemId, samples) in kept)
        {
            accesses[itemId] = samples;
        }
    }

    private static string Key(Guid connectionId) => connectionId.ToString();

    private FrecencyFile Load() => JsonFile.Read(_path, FrecencyJson.Default.FrecencyFile) ?? new FrecencyFile();

    private void Save(FrecencyFile file) => JsonFile.Write(_path, file, FrecencyJson.Default.FrecencyFile);
}

internal sealed record FrecencyFile
{
    public Dictionary<string, Dictionary<string, List<double>>> Connections { get; init; } =
        new(StringComparer.Ordinal);
}

[JsonSourceGenerationOptions(WriteIndented = false, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase)]
[JsonSerializable(typeof(FrecencyFile))]
internal sealed partial class FrecencyJson : JsonSerializerContext;
