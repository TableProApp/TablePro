using System.Buffers;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Unicode;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.Kafka.Localization;

namespace TablePro.Drivers.Kafka;

/// <summary>One message as read from a partition. A null value is a tombstone, which an empty value is not.</summary>
internal sealed record KafkaRecord(int Partition, long Offset, long TimestampMs, byte[]? Key, byte[]? Value, IReadOnlyList<KeyValuePair<string, byte[]?>> Headers);

/// <summary>The offsets to read from one partition, end exclusive.</summary>
internal readonly record struct PartitionRange(int Partition, long Start, long End)
{
    public long Count => Math.Max(0, End - Start);
}

/// <summary>How messages become grid rows, and which offsets a page needs. Pure: it touches no broker.</summary>
internal static class KafkaRows
{
    public const string PartitionColumn = "partition";
    public const string OffsetColumn = "offset";
    public const string TimestampColumn = "timestamp";
    public const string KeyColumn = "key";
    public const string ValueColumn = "value";
    public const string HeadersColumn = "headers";

    // The coordinates first, then the payload, as Kafka UIs (kafbat, Redpanda Console, AKHQ) lay messages out.
    // Built on each read, so the comments are worded in the language of the moment: a list cached on first use could
    // keep the English an MCP request reads.
    public static IReadOnlyList<ColumnInfo> Columns =>
    [
        new(PartitionColumn, "INTEGER", false, null, true, false, 0),
        new(OffsetColumn, "BIGINT", false, null, true, false, 1),
        new(TimestampColumn, "TIMESTAMP", true, null, false, false, 2, KafkaStrings.Get("Kafka/TimestampComment")),
        new(KeyColumn, "TEXT", true, null, false, false, 3),
        new(ValueColumn, "TEXT", true, null, false, false, 4, KafkaStrings.Get("Kafka/ValueComment")),
        new(HeadersColumn, "JSON", true, null, false, false, 5),
    ];

    public static IReadOnlyList<string> ColumnNames { get; } = Columns.Select(c => c.Name).ToArray();

    // The headers cell is read by people, not embedded in HTML, so only what JSON itself requires is escaped.
    private static readonly JsonWriterOptions HeaderWriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>
    /// Maps messages to rows. A payload has no declared type, so the key and value columns are text only when every
    /// payload on the page is UTF-8; one binary payload makes the column bytes, the less lossy of the two mistakes.
    /// </summary>
    public static ResultSet ToResultSet(IReadOnlyList<KafkaRecord> records, bool isTruncated = false)
    {
        var keysAreText = records.All(r => IsText(r.Key));
        var valuesAreText = records.All(r => IsText(r.Value));
        var columns = new ResultColumn[]
        {
            new(PartitionColumn, "INTEGER", typeof(int)),
            new(OffsetColumn, "BIGINT", typeof(long)),
            new(TimestampColumn, "TIMESTAMP", typeof(DateTimeOffset)),
            new(KeyColumn, keysAreText ? "TEXT" : "BLOB", keysAreText ? typeof(string) : typeof(byte[])),
            new(ValueColumn, valuesAreText ? "TEXT" : "BLOB", valuesAreText ? typeof(string) : typeof(byte[])),
            new(HeadersColumn, "JSON", typeof(string)),
        };

        var rows = new List<object?[]>(records.Count);
        foreach (var record in records)
        {
            rows.Add(
            [
                record.Partition,
                record.Offset,
                Timestamp(record.TimestampMs),
                Payload(record.Key, keysAreText),
                Payload(record.Value, valuesAreText),
                HeadersJson(record.Headers),
            ]);
        }

        return new ResultSet(columns, rows, isTruncated);
    }

    /// <summary>Kafka times are milliseconds since the epoch in UTC; zero or below means the producer set none.</summary>
    public static DateTimeOffset? Timestamp(long milliseconds) =>
        milliseconds > 0 ? DateTimeOffset.FromUnixTimeMilliseconds(milliseconds) : null;

    /// <summary>Headers as one JSON object; a header value that is not UTF-8 is written as hex.</summary>
    public static string? HeadersJson(IReadOnlyList<KeyValuePair<string, byte[]?>> headers)
    {
        if (headers.Count == 0)
        {
            return null;
        }

        var buffer = new ArrayBufferWriter<byte>(64);
        using (var writer = new Utf8JsonWriter(buffer, HeaderWriterOptions))
        {
            writer.WriteStartObject();
            foreach (var (key, value) in headers)
            {
                if (value is null)
                {
                    writer.WriteNull(key);
                }
                else
                {
                    writer.WriteString(key, Utf8.IsValid(value) ? Encoding.UTF8.GetString(value) : Convert.ToHexString(value));
                }
            }

            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>
    /// Orders a read of several partitions as one list. Kafka orders messages only within a partition, so time first
    /// matches what a person debugging expects, and (partition, offset) breaks ties so paging never repeats or skips.
    /// </summary>
    public static List<KafkaRecord> Merge(IEnumerable<KafkaRecord> records)
    {
        var list = records.ToList();
        list.Sort(static (a, b) =>
        {
            var byTime = a.TimestampMs.CompareTo(b.TimestampMs);
            if (byTime != 0)
            {
                return byTime;
            }

            var byPartition = a.Partition.CompareTo(b.Partition);
            return byPartition != 0 ? byPartition : a.Offset.CompareTo(b.Offset);
        });
        return list;
    }

    /// <summary>
    /// The page of a merged read. A backward read stepped each partition back from its end, so its newest messages
    /// sit at the end of the merged list and the page is taken from there.
    /// </summary>
    public static List<KafkaRecord> Page(List<KafkaRecord> ordered, int skip, int limit, bool readsBackward)
    {
        if (limit <= 0)
        {
            return [];
        }

        skip = Math.Max(0, skip);
        if (!readsBackward)
        {
            return ordered.Skip(skip).Take(limit).ToList();
        }

        var end = Math.Max(0, ordered.Count - skip);
        var start = Math.Max(0, end - limit);
        return ordered.GetRange(start, end - start);
    }

    /// <summary>
    /// The offsets each partition must give up for a page. Every partition may hold the whole page, so each reads up
    /// to <c>skip + limit</c> messages from its start (or back from its end) and the merge decides which are shown.
    /// </summary>
    public static List<PartitionRange> Plan(
        KafkaStart start,
        int skip,
        int limit,
        IReadOnlyDictionary<int, (long Low, long High)> watermarks,
        IReadOnlyDictionary<int, long>? timeOffsets = null)
    {
        var need = (long)Math.Max(0, skip) + Math.Max(0, limit);
        var ranges = new List<PartitionRange>(watermarks.Count);
        foreach (var (partition, (low, high)) in watermarks.OrderBy(w => w.Key))
        {
            long from;
            long to;
            switch (start.Kind)
            {
                case KafkaStartKind.Newest:
                    to = high;
                    from = Math.Max(low, high - need);
                    break;
                case KafkaStartKind.Tail:
                    if (start.Offsets?.TryGetValue(partition, out var end) != true)
                    {
                        continue;
                    }

                    to = Math.Clamp(end, low, high);
                    from = Math.Max(low, to - need);
                    break;
                case KafkaStartKind.Offset:
                    from = Math.Clamp(start.Value, low, high);
                    to = Math.Min(high, from + need);
                    break;
                case KafkaStartKind.Timestamp:
                    // A partition with nothing at or after the time has no offset for it and contributes nothing.
                    from = timeOffsets?.TryGetValue(partition, out var at) == true && at >= 0 ? Math.Clamp(at, low, high) : high;
                    to = Math.Min(high, from + need);
                    break;
                case KafkaStartKind.Anchor:
                    if (start.Offsets?.TryGetValue(partition, out var anchor) != true)
                    {
                        continue;
                    }

                    from = Math.Clamp(anchor, low, high);
                    to = Math.Min(high, from + need);
                    break;
                default:
                    from = low;
                    to = Math.Min(high, low + need);
                    break;
            }

            if (to > from)
            {
                ranges.Add(new PartitionRange(partition, from, to));
            }
        }

        return ranges;
    }

    private static bool IsText(byte[]? bytes) => bytes is null || Utf8.IsValid(bytes);

    private static object? Payload(byte[]? bytes, bool asText) => bytes is null ? null : asText ? Encoding.UTF8.GetString(bytes) : bytes;
}
