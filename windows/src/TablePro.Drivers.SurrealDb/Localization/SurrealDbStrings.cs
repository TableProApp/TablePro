using TablePro.Core.Localization;

namespace TablePro.Drivers.SurrealDb.Localization;

/// <summary>
/// The text only the SurrealDB driver composes, in <c>src/TablePro.Drivers.SurrealDb/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class SurrealDbStrings
{
    private static readonly ResourceStrings Text = new(typeof(SurrealDbStrings).Assembly, "TablePro.Drivers.SurrealDb.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
