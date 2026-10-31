using Amazon.DynamoDBv2.Model;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// Remembered ExclusiveStartKeys, so the next page continues the scan instead of reading every item before it again.
/// A key is kept with the count of matching items before it, per scan.
/// </summary>
public sealed class DynamoResumePoints(int maxScans = 16, int maxPointsPerScan = 256)
{
    private readonly Lock _lock = new();
    private readonly LinkedList<(string Key, SortedList<int, Dictionary<string, AttributeValue>> Points)> _scans = new();

    public void Record(string scan, int matchedBefore, Dictionary<string, AttributeValue> startKey)
    {
        lock (_lock)
        {
            var points = Touch(scan, create: true)!;
            if (points.Count >= maxPointsPerScan && !points.ContainsKey(matchedBefore))
            {
                points.RemoveAt(points.Count - 1);
            }

            points[matchedBefore] = startKey;
        }
    }

    /// <summary>The furthest point at or before <paramref name="offset"/>, or the start of the table.</summary>
    public (int MatchedBefore, Dictionary<string, AttributeValue>? StartKey) Find(string scan, int offset)
    {
        lock (_lock)
        {
            var points = Touch(scan, create: false);
            if (points is not null)
            {
                for (var i = points.Count - 1; i >= 0; i--)
                {
                    if (points.Keys[i] <= offset)
                    {
                        return (points.Keys[i], points.Values[i]);
                    }
                }
            }

            return (0, null);
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _scans.Clear();
        }
    }

    private SortedList<int, Dictionary<string, AttributeValue>>? Touch(string scan, bool create)
    {
        for (var node = _scans.First; node is not null; node = node.Next)
        {
            if (node.Value.Key == scan)
            {
                _scans.Remove(node);
                _scans.AddFirst(node);
                return node.Value.Points;
            }
        }

        if (!create)
        {
            return null;
        }

        if (_scans.Count >= maxScans)
        {
            _scans.RemoveLast();
        }

        var points = new SortedList<int, Dictionary<string, AttributeValue>>();
        _scans.AddFirst((scan, points));
        return points;
    }
}
