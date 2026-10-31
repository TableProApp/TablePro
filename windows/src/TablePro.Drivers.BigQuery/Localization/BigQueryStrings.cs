using TablePro.Core.Localization;

namespace TablePro.Drivers.BigQuery.Localization;

/// <summary>
/// The text only the BigQuery driver composes, in <c>src/TablePro.Drivers.BigQuery/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class BigQueryStrings
{
    private static readonly ResourceStrings Text = new(typeof(BigQueryStrings).Assembly, "TablePro.Drivers.BigQuery.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
