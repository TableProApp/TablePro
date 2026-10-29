using TablePro.Core.Localization;

namespace TablePro.Drivers.PostgreSql.Localization;

/// <summary>
/// The text only the PostgreSQL driver composes, in <c>src/TablePro.Drivers.PostgreSql/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class PostgreSqlStrings
{
    private static readonly ResourceStrings Text = new(typeof(PostgreSqlStrings).Assembly, "TablePro.Drivers.PostgreSql.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
