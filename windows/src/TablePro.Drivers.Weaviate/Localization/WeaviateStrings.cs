using TablePro.Core.Localization;

namespace TablePro.Drivers.Weaviate.Localization;

/// <summary>
/// The text only the Weaviate driver composes, in <c>src/TablePro.Drivers.Weaviate/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class WeaviateStrings
{
    private static readonly ResourceStrings Text = new(typeof(WeaviateStrings).Assembly, "TablePro.Drivers.Weaviate.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
