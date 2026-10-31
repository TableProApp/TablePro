using System.Globalization;
using System.Text;
using System.Text.Json;
using Confluent.Kafka;
using TablePro.Core.Editing;
using TablePro.Drivers.Kafka.Localization;

namespace TablePro.Drivers.Kafka;

/// <summary>A message to produce, with the partition it was pinned to, if any.</summary>
internal sealed record KafkaOutgoing(int? Partition, Message<byte[]?, byte[]?> Message);

/// <summary>
/// Grid saves on a topic. A topic is an append-only log: a new row is a message to produce, while an edited or deleted
/// row would rewrite history Kafka does not let anyone rewrite.
/// </summary>
internal static class KafkaWrites
{
    public static string AppendOnly => KafkaStrings.Get("Kafka/AppendOnly");

    /// <summary>Checks every change before anything is produced, so a refused edit never leaves half a save behind.</summary>
    public static List<KafkaOutgoing> Prepare(IReadOnlyList<RowChange> changes)
    {
        var messages = new List<KafkaOutgoing>(changes.Count);
        foreach (var change in changes)
        {
            messages.Add(change is RowInsert insert ? ToMessage(insert.Values) : throw new NotSupportedException(AppendOnly));
        }

        return messages;
    }

    public static KafkaOutgoing ToMessage(IReadOnlyDictionary<string, object?> values)
    {
        var message = new Message<byte[]?, byte[]?>();
        int? partition = null;
        foreach (var (column, value) in values)
        {
            switch (column.ToLowerInvariant())
            {
                case KafkaRows.KeyColumn:
                    message.Key = Bytes(value);
                    break;
                case KafkaRows.ValueColumn:
                    message.Value = Bytes(value);
                    break;
                case KafkaRows.HeadersColumn:
                    message.Headers = Headers(value);
                    break;
                case KafkaRows.PartitionColumn:
                    partition = value is null ? null : Convert.ToInt32(value, CultureInfo.InvariantCulture);
                    break;
                case KafkaRows.TimestampColumn:
                    if (Time(value) is { } time)
                    {
                        message.Timestamp = new Timestamp(time);
                    }

                    break;
                case KafkaRows.OffsetColumn:
                    if (value is not null)
                    {
                        throw new NotSupportedException(KafkaStrings.Get("Kafka/OffsetAssigned"));
                    }

                    break;
                default:
                    throw new NotSupportedException(KafkaStrings.Format("Kafka/NoSuchColumn", column));
            }
        }

        return new KafkaOutgoing(partition, message);
    }

    public static byte[]? Bytes(object? value) => value switch
    {
        null => null,
        byte[] bytes => bytes,
        string text => Encoding.UTF8.GetBytes(text),
        IFormattable formattable => Encoding.UTF8.GetBytes(formattable.ToString(null, CultureInfo.InvariantCulture)),
        _ => Encoding.UTF8.GetBytes(value.ToString() ?? string.Empty),
    };

    /// <summary>Headers from the JSON object the grid shows, such as <c>{"trace":"abc"}</c>.</summary>
    public static Headers? Headers(object? value)
    {
        var text = value as string ?? (value is byte[] bytes ? Encoding.UTF8.GetString(bytes) : null);
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(text);
        }
        catch (JsonException ex)
        {
            throw new FormatException(KafkaStrings.Get("Kafka/HeadersJson"), ex);
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new FormatException(KafkaStrings.Get("Kafka/HeadersJson"));
            }

            var headers = new Headers();
            foreach (var property in document.RootElement.EnumerateObject())
            {
                headers.Add(property.Name, property.Value.ValueKind switch
                {
                    JsonValueKind.Null => null,
                    JsonValueKind.String => Encoding.UTF8.GetBytes(property.Value.GetString()!),
                    _ => Encoding.UTF8.GetBytes(property.Value.GetRawText()),
                });
            }

            return headers;
        }
    }

    private static DateTimeOffset? Time(object? value) => value switch
    {
        null => null,
        DateTimeOffset offset => offset,
        DateTime dateTime => new DateTimeOffset(dateTime.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(dateTime, DateTimeKind.Utc) : dateTime),
        long milliseconds => DateTimeOffset.FromUnixTimeMilliseconds(milliseconds),
        string text when long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var milliseconds) => DateTimeOffset.FromUnixTimeMilliseconds(milliseconds),
        string text when DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed) => parsed,
        string text when string.IsNullOrWhiteSpace(text) => null,
        _ => throw new FormatException(KafkaStrings.Format("Kafka/NotATime", value)),
    };
}
