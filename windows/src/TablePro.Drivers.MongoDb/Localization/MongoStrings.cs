using TablePro.Core.Localization;

namespace TablePro.Drivers.MongoDb.Localization;

/// <summary>
/// The text only the MongoDB driver composes (shell syntax and planning errors, write results, grid save refusals), in
/// src/TablePro.Drivers.MongoDb/Resources/&lt;Area&gt;.resx. Server messages pass through untouched, and the words mongosh
/// itself prints, such as SyntaxError and "switched to db", stay as mongosh prints them.
/// </summary>
internal static class MongoStrings
{
    private static readonly ResourceStrings Text = new(typeof(MongoStrings).Assembly, "TablePro.Drivers.MongoDb.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
