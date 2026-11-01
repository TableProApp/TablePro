using System.Globalization;
using System.Text;
using StackExchange.Redis;

namespace TablePro.Drivers.Redis;

internal enum RedisReplyKind
{
    Null,
    Status,
    Text,
    Integer,
    Double,
    Boolean,
    Error,
    Array,
    Map,
    Set,
}

/// <summary>
/// A server reply detached from the client library, so shaping it into rows is a pure function the tests can feed
/// directly. <see cref="Items"/> holds a map's keys and values alternately, as the wire does.
/// </summary>
internal sealed class RedisReply
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    private RedisReply(RedisReplyKind kind, string? text, IReadOnlyList<RedisReply>? items)
    {
        Kind = kind;
        Text = text;
        Items = items ?? [];
    }

    public static RedisReply Nil { get; } = new(RedisReplyKind.Null, null, null);

    public RedisReplyKind Kind { get; }

    public string? Text { get; }

    public IReadOnlyList<RedisReply> Items { get; }

    public bool IsAggregate => Kind is RedisReplyKind.Array or RedisReplyKind.Map or RedisReplyKind.Set;

    public bool IsNull => Kind == RedisReplyKind.Null;

    public static RedisReply Status(string text) => new(RedisReplyKind.Status, text, null);

    public static RedisReply Bulk(string? text) => text is null ? Nil : new(RedisReplyKind.Text, text, null);

    public static RedisReply Integer(long value) => new(RedisReplyKind.Integer, value.ToString(CultureInfo.InvariantCulture), null);

    public static RedisReply Double(double value) => new(RedisReplyKind.Double, value.ToString("R", CultureInfo.InvariantCulture), null);

    public static RedisReply Boolean(bool value) => new(RedisReplyKind.Boolean, value ? "true" : "false", null);

    public static RedisReply Error(string message) => new(RedisReplyKind.Error, message, null);

    public static RedisReply Array(params RedisReply[] items) => new(RedisReplyKind.Array, null, items);

    public static RedisReply Array(IReadOnlyList<RedisReply> items) => new(RedisReplyKind.Array, null, items);

    public static RedisReply Map(params RedisReply[] keysAndValues) => new(RedisReplyKind.Map, null, keysAndValues);

    public static RedisReply Set(params RedisReply[] items) => new(RedisReplyKind.Set, null, items);

    public static RedisReply Strings(params string[] values) => Array(values.Select(Bulk).ToArray());

    /// <summary>Copies a library result into the neutral model, decoding text as strict UTF-8.</summary>
    public static RedisReply From(RedisResult result)
    {
        if (result.IsNull && result.Resp2Type is not ResultType.Array)
        {
            return Nil;
        }

        switch (result.Resp3Type)
        {
            case ResultType.Array or ResultType.Map or ResultType.Set or ResultType.Push or ResultType.Attribute:
                var children = (RedisResult[]?)result;
                if (children is null)
                {
                    return Nil;
                }

                var items = new RedisReply[children.Length];
                for (var i = 0; i < children.Length; i++)
                {
                    items[i] = From(children[i]);
                }

                var kind = result.Resp3Type switch
                {
                    ResultType.Map => RedisReplyKind.Map,
                    ResultType.Set => RedisReplyKind.Set,
                    _ => RedisReplyKind.Array,
                };
                return new RedisReply(kind, null, items);
            case ResultType.Integer:
                return new RedisReply(RedisReplyKind.Integer, result.ToString(), null);
            case ResultType.Double:
                return new RedisReply(RedisReplyKind.Double, result.ToString(), null);
            case ResultType.Boolean:
                return Boolean((bool)result);
            case ResultType.Error or ResultType.BlobError:
                return Error(result.ToString() ?? string.Empty);
            case ResultType.SimpleString:
                return Status(result.ToString() ?? string.Empty);
            default:
                return Bulk(DecodeText((byte[]?)result));
        }
    }

    /// <summary>
    /// Text as the server stored it, or a redis-cli style quoted string when the bytes are not UTF-8, so binary values
    /// show what they hold instead of replacement characters.
    /// </summary>
    public static string? DecodeText(byte[]? bytes)
    {
        if (bytes is null)
        {
            return null;
        }

        try
        {
            return StrictUtf8.GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            return QuoteBinary(bytes);
        }
    }

    public static string QuoteBinary(ReadOnlySpan<byte> bytes)
    {
        var builder = new StringBuilder(bytes.Length + 2);
        builder.Append('"');
        foreach (var b in bytes)
        {
            switch (b)
            {
                case (byte)'"':
                    builder.Append("\\\"");
                    break;
                case (byte)'\\':
                    builder.Append("\\\\");
                    break;
                case (byte)'\n':
                    builder.Append("\\n");
                    break;
                case (byte)'\r':
                    builder.Append("\\r");
                    break;
                case (byte)'\t':
                    builder.Append("\\t");
                    break;
                case >= 0x20 and < 0x7f:
                    builder.Append((char)b);
                    break;
                default:
                    builder.Append(CultureInfo.InvariantCulture, $"\\x{b:x2}");
                    break;
            }
        }

        builder.Append('"');
        return builder.ToString();
    }

    public override string ToString() => IsAggregate ? RedisJson.Write(this) : Text ?? "(nil)";
}
