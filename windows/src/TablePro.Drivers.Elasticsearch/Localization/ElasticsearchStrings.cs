using TablePro.Core.Localization;

namespace TablePro.Drivers.Elasticsearch.Localization;

/// <summary>
/// The text only the Elasticsearch driver composes, in <c>src/TablePro.Drivers.Elasticsearch/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class ElasticsearchStrings
{
    private static readonly ResourceStrings Text = new(typeof(ElasticsearchStrings).Assembly, "TablePro.Drivers.Elasticsearch.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
