using TablePro.Core.Localization;

namespace TablePro.Ai.Localization;

/// <summary>
/// The text the assistant shows the user, in <c>src/TablePro.Ai/Resources/&lt;Area&gt;.resx</c>: provider failures and
/// access refusals. Prompts are not here: they go to the model, which reads English best, so they stay in code.
/// </summary>
internal static class AiStrings
{
    private static readonly ResourceStrings Text = new(typeof(AiStrings).Assembly, "TablePro.Ai.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
