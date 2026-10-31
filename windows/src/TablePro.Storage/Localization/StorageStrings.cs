using TablePro.Core.Localization;

namespace TablePro.Storage.Localization;

/// <summary>
/// The text Storage composes, in <c>src/TablePro.Storage/Resources/&lt;Area&gt;.resx</c>: import and export problems,
/// linked-folder and Git errors, licensing and Credential Manager failures. The app shows these messages as they
/// come, so they follow the UI language here rather than in the app.
/// </summary>
internal static class StorageStrings
{
    private static readonly ResourceStrings Text = new(typeof(StorageStrings).Assembly, "TablePro.Storage.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);

    public static string Plural(string key, long count, params ReadOnlySpan<object?> args) => Text.Plural(key, count, args);
}
