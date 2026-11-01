using System.Globalization;
using System.Text.Json;

namespace TablePro.Mcp.Tools;

/// <summary>
/// A tool's arguments. Unknown names are refused rather than ignored, so a misspelt argument fails instead of being
/// dropped and changing what the call means.
/// </summary>
internal readonly struct McpArguments
{
    private readonly JsonElement _root;

    public McpArguments(JsonElement root, params ReadOnlySpan<string> allowed)
    {
        if (root.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null)
        {
            _root = default;
            return;
        }

        if (root.ValueKind != JsonValueKind.Object)
        {
            throw McpToolException.Invalid("arguments must be an object");
        }

        foreach (var property in root.EnumerateObject())
        {
            var known = false;
            foreach (var name in allowed)
            {
                if (property.NameEquals(name))
                {
                    known = true;
                    break;
                }
            }

            if (!known)
            {
                throw McpToolException.Invalid($"unknown argument {property.Name}");
            }
        }

        _root = root;
    }

    public string RequiredString(string name) =>
        OptionalString(name) is { Length: > 0 } value ? value : throw McpToolException.Invalid($"{name} is required");

    public string? OptionalString(string name)
    {
        if (!TryGet(name, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : throw McpToolException.Invalid($"{name} must be a string");
    }

    public int Int(string name, int defaultValue, int min, int max)
    {
        if (!TryGet(name, out var value))
        {
            return defaultValue;
        }

        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var number))
        {
            throw McpToolException.Invalid($"{name} must be a whole number");
        }

        return number < min || number > max
            ? throw McpToolException.Invalid(string.Create(CultureInfo.InvariantCulture, $"{name} must be {min} to {max}, not {number}"))
            : (int)number;
    }

    public IEnumerable<JsonElement> Array(string name)
    {
        if (!TryGet(name, out var value))
        {
            return [];
        }

        return value.ValueKind == JsonValueKind.Array
            ? value.EnumerateArray()
            : throw McpToolException.Invalid($"{name} must be an array");
    }

    private bool TryGet(string name, out JsonElement value)
    {
        value = default;
        return _root.ValueKind == JsonValueKind.Object
            && _root.TryGetProperty(name, out value)
            && value.ValueKind != JsonValueKind.Null;
    }
}
