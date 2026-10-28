using System.Text.Json;

namespace TablePro.Core.Import;

/// <summary>
/// Reads rows to import from JSON: an array of objects, or one object per line (NDJSON), as the macOS app's JSON
/// import plugin accepts. Nested objects and arrays become their JSON text; numbers keep integer or decimal form.
/// </summary>
public static class JsonRowReader
{
    public static async IAsyncEnumerable<IReadOnlyDictionary<string, object?>> ReadAsync(Stream stream, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken)
    {
        // The first significant byte decides the format; reading bytes and rewinding keeps the stream whole for the parser.
        var start = stream.Position;
        int first;
        do
        {
            first = stream.ReadByte();
        }
        while (first is ' ' or '\t' or '\r' or '\n' or 0xEF or 0xBB or 0xBF);
        stream.Position = start;

        if (first == '[')
        {
            // An array streams element by element instead of loading the whole document.
            await foreach (var element in JsonSerializer.DeserializeAsyncEnumerable(stream, JsonContext.Default.JsonElement, cancellationToken))
            {
                if (element.ValueKind == JsonValueKind.Object)
                {
                    yield return ToRow(element);
                }
            }

            yield break;
        }

        using var reader = new StreamReader(stream, leaveOpen: true);
        while (await reader.ReadLineAsync(cancellationToken) is { } line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            using var document = JsonDocument.Parse(line);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
            {
                yield return ToRow(document.RootElement);
            }
        }
    }

    public static IReadOnlyDictionary<string, object?> ToRow(JsonElement element)
    {
        var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in element.EnumerateObject())
        {
            row[property.Name] = property.Value.ValueKind switch
            {
                JsonValueKind.String => property.Value.GetString(),
                JsonValueKind.Number when property.Value.TryGetInt64(out var integer) => integer,
                JsonValueKind.Number => property.Value.GetDecimal(),
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.Null or JsonValueKind.Undefined => null,
                _ => property.Value.GetRawText(),
            };
        }

        return row;
    }
}

[System.Text.Json.Serialization.JsonSerializable(typeof(JsonElement))]
internal sealed partial class JsonContext : System.Text.Json.Serialization.JsonSerializerContext;
