using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using TablePro.Drivers.DynamoDb.Localization;

namespace TablePro.Drivers.DynamoDb;

/// <summary>One page of a table read with Scan, and what the user should know about how it was read.</summary>
public sealed record DynamoScanPage(List<Dictionary<string, AttributeValue>> Items, bool HasMore, IReadOnlyList<string> Notices);

/// <summary>
/// Reads a table page with Scan. DynamoDB has no OFFSET: a page past the first continues from a remembered
/// ExclusiveStartKey where one is known, and otherwise skips the items before it, up to a limit.
/// </summary>
public static class DynamoScanReader
{
    /// <summary>A far page is reached by reading the items before it; past this many it is refused.</summary>
    public const int MaxSkippedItems = 100_000;

    /// <summary>A filtered page stops after reading this many items, so a rare match cannot scan a whole table.</summary>
    public const int MaxScannedItems = 200_000;

    private const int MaxPageSize = 1000;

    public static async Task<DynamoScanPage> ReadAsync(
        IDynamoDbApi api,
        string table,
        IReadOnlyList<string> keyNames,
        DynamoFilterPlan plan,
        int offset,
        int limit,
        DynamoResumePoints resumePoints,
        CancellationToken cancellationToken)
    {
        var notices = new List<string>(plan.Notices);
        var items = new List<Dictionary<string, AttributeValue>>();
        if (plan.MatchesNothing)
        {
            notices.Add(DynamoDbStrings.Get("DynamoDb/NumberKeyMismatch"));
            return new DynamoScanPage(items, false, notices);
        }

        var resumeKey = plan.ResumeKey;
        var (matched, startKey) = resumePoints.Find(resumeKey, offset);
        var toSkip = offset - matched;
        if (toSkip > MaxSkippedItems)
        {
            notices.Add(DynamoDbStrings.Format("DynamoDb/NoOffset", offset, toSkip));
            return new DynamoScanPage(items, true, notices);
        }

        var filtered = plan.Expression is not null || plan.ClientFilter is not null;
        var pageSize = filtered ? MaxPageSize : Math.Clamp(toSkip + limit + 1, 25, MaxPageSize);
        var scanned = 0;
        var more = false;

        while (true)
        {
            var response = await api.ScanAsync(
                new ScanRequest
                {
                    TableName = table,
                    Limit = pageSize,
                    ExclusiveStartKey = startKey,
                    FilterExpression = plan.Expression,
                    ExpressionAttributeNames = plan.Names.Count > 0 ? new Dictionary<string, string>(plan.Names) : null,
                    ExpressionAttributeValues = plan.Values.Count > 0 ? new Dictionary<string, AttributeValue>(plan.Values) : null,
                    ReturnConsumedCapacity = ReturnConsumedCapacity.NONE,
                },
                cancellationToken);
            scanned += response.ScannedCount ?? response.Items?.Count ?? 0;

            var stoppedMidPage = false;
            Dictionary<string, AttributeValue>? previous = null;
            foreach (var item in response.Items ?? [])
            {
                if (plan.ClientFilter?.Matches(item) == false)
                {
                    previous = item;
                    continue;
                }

                if (toSkip > 0)
                {
                    toSkip--;
                    matched++;
                    previous = item;
                    continue;
                }

                if (items.Count == limit)
                {
                    more = true;
                    stoppedMidPage = true;
                    break;
                }

                items.Add(item);
                matched++;
                previous = item;
            }

            if (stoppedMidPage)
            {
                // A scan's ExclusiveStartKey is the key of the last item read, so the next page can start right after
                // the last item shown even though DynamoDB's own page went on.
                if (previous is not null && KeyOf(previous, keyNames) is { } resume)
                {
                    resumePoints.Record(resumeKey, matched, resume);
                }

                break;
            }

            startKey = response.LastEvaluatedKey is { Count: > 0 } last ? last : null;
            if (startKey is null)
            {
                break;
            }

            resumePoints.Record(resumeKey, matched, startKey);
            if (filtered && scanned >= MaxScannedItems)
            {
                more = true;
                notices.Add(DynamoDbStrings.Format("DynamoDb/StoppedAfterScanning", scanned));
                break;
            }

            if (items.Count == limit && !filtered)
            {
                more = true;
                break;
            }
        }

        return new DynamoScanPage(items, more, notices);
    }

    private static Dictionary<string, AttributeValue>? KeyOf(Dictionary<string, AttributeValue> item, IReadOnlyList<string> keyNames)
    {
        if (keyNames.Count == 0)
        {
            return null;
        }

        var key = new Dictionary<string, AttributeValue>(keyNames.Count, StringComparer.Ordinal);
        foreach (var name in keyNames)
        {
            if (!item.TryGetValue(name, out var value))
            {
                return null;
            }

            key[name] = value;
        }

        return key;
    }
}
