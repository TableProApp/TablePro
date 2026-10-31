using TablePro.Core.Localization;

namespace TablePro.Drivers.LibSql.Localization;

/// <summary>
/// The text only the libSQL driver composes, in <c>src/TablePro.Drivers.LibSql/Resources/&lt;Area&gt;.resx</c>. Phrases the
/// drivers share come from <see cref="CoreStrings"/>' <c>Driver</c> area instead.
/// </summary>
internal static class LibSqlStrings
{
    private static readonly ResourceStrings Text = new(typeof(LibSqlStrings).Assembly, "TablePro.Drivers.LibSql.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
