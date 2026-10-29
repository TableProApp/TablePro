using TablePro.Core.Localization;

namespace TablePro.Drivers.Beancount.Localization;

/// <summary>
/// The text only the Beancount driver composes (backend setup advice, projection failures), in
/// src/TablePro.Drivers.Beancount/Resources/&lt;Area&gt;.resx. What Python Beancount or rledger print passes through as sent.
/// </summary>
internal static class BeancountStrings
{
    private static readonly ResourceStrings Text = new(typeof(BeancountStrings).Assembly, "TablePro.Drivers.Beancount.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
