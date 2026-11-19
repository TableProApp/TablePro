using System.Globalization;
using System.Text.Json;

namespace TablePro.App.Model;

// A root per row and a node's children made only as it opens, so large documents cost a line each until opened.
public sealed class JsonTree : IDisposable
{
    private static readonly JsonDocumentOptions Options = new() { MaxDepth = 1_000, AllowDuplicateProperties = true };

    private readonly JsonDocument _document;

    private JsonTree(JsonDocument document)
    {
        _document = document;
        var root = document.RootElement;
        Roots = root.ValueKind == JsonValueKind.Array
            ? JsonTreeNode.ChildrenOf(root)
            : [new JsonTreeNode(string.Empty, root)];
    }

    // Valid until the tree is disposed.
    public IReadOnlyList<JsonTreeNode> Roots { get; }

    // Throws JsonException for text that is not one JSON value.
    public static JsonTree Parse(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        var document = JsonDocument.Parse(json, Options);
        try
        {
            return new JsonTree(document);
        }
        catch
        {
            document.Dispose();
            throw;
        }
    }

    public void Dispose() => _document.Dispose();
}

public sealed class JsonTreeNode
{
    // A tree row is one line, so it shows a long value's start.
    public const int MaximumValueCharacters = 500;

    private readonly JsonElement _element;

    internal JsonTreeNode(string key, JsonElement element)
    {
        Key = key;
        _element = element;
        Kind = element.ValueKind;
        ChildCount = Kind switch
        {
            JsonValueKind.Object => element.GetPropertyCount(),
            JsonValueKind.Array => element.GetArrayLength(),
            _ => 0,
        };
        Value = Kind is JsonValueKind.Object or JsonValueKind.Array ? string.Empty : Cut(element.GetRawText());
    }

    // A member's name, or an item's place as [0].
    public string Key { get; }

    public JsonValueKind Kind { get; }

    public int ChildCount { get; }

    // As the JSON text writes it, a string in its quotes; empty for an object or an array.
    public string Value { get; }

    // The row's line: an object or an array says how many members it holds, as {3} or [3].
    public string Text => Kind switch
    {
        JsonValueKind.Object => string.Create(CultureInfo.InvariantCulture, $"{Key}: {{{ChildCount}}}"),
        JsonValueKind.Array => string.Create(CultureInfo.InvariantCulture, $"{Key}: [{ChildCount}]"),
        _ => $"{Key}: {Value}",
    };

    // Made again on each call; a view keeps what it made.
    public IReadOnlyList<JsonTreeNode> Children() => ChildrenOf(_element);

    internal static IReadOnlyList<JsonTreeNode> ChildrenOf(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object =>
            [.. element.EnumerateObject().Select(member => new JsonTreeNode(member.Name, member.Value))],
        JsonValueKind.Array => [.. element.EnumerateArray().Select((item, index) =>
            new JsonTreeNode(string.Create(CultureInfo.InvariantCulture, $"[{index}]"), item))],
        _ => [],
    };

    private static string Cut(string text) =>
        text.Length <= MaximumValueCharacters
            ? text
            : string.Concat(
                text.AsSpan(0, char.IsHighSurrogate(text[MaximumValueCharacters - 1])
                    ? MaximumValueCharacters - 1
                    : MaximumValueCharacters),
                "…");
}
