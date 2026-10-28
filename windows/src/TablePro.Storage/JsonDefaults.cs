using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;

namespace TablePro.Storage;

/// <summary>
/// The source generator sets init-only properties the way it fills constructor parameters, so a property missing
/// from the file arrives as <c>default</c> rather than its initializer (a new bool that should be true reads false).
/// Overlaying the stored JSON onto a serialized default object first puts every initializer back, which keeps
/// files written by older builds, or edited by hand, loading with the defaults the code declares.
/// </summary>
internal static class JsonDefaults
{
    /// <summary>Returns <paramref name="stored"/> laid over <paramref name="template"/>; nested objects merge the same way.</summary>
    public static JsonObject Overlay<T>(JsonObject stored, T template, JsonTypeInfo<T> typeInfo)
    {
        if (JsonSerializer.SerializeToNode(template, typeInfo) is not JsonObject merged)
        {
            return stored;
        }

        Overlay(merged, stored);
        return merged;
    }

    /// <summary>Applies <see cref="Overlay{T}(JsonObject, T, JsonTypeInfo{T})"/> to each object in the array <paramref name="property"/>.</summary>
    public static void OverlayEach<T>(JsonObject document, string property, Func<T> template, JsonTypeInfo<T> typeInfo)
    {
        if (document[property] is not JsonArray array)
        {
            return;
        }

        for (var i = 0; i < array.Count; i++)
        {
            if (array[i] is JsonObject item)
            {
                array[i] = Overlay(item.DeepClone().AsObject(), template(), typeInfo);
            }
        }
    }

    private static void Overlay(JsonObject target, JsonObject source)
    {
        foreach (var (name, value) in source)
        {
            if (value is JsonObject sourceChild && target[name] is JsonObject targetChild)
            {
                Overlay(targetChild, sourceChild);
            }
            else
            {
                target[name] = value?.DeepClone();
            }
        }
    }
}
