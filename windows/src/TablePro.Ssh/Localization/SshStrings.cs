using TablePro.Core.Localization;

namespace TablePro.Ssh.Localization;

/// <summary>
/// The text Ssh composes, in <c>src/TablePro.Ssh/Resources/&lt;Area&gt;.resx</c>: why a tunnel, a proxy or a cloud
/// sign-in failed. The connect dialog shows these messages as they come, with what ssh or the helper printed below
/// them in English, as the program wrote it.
/// </summary>
internal static class SshStrings
{
    private static readonly ResourceStrings Text = new(typeof(SshStrings).Assembly, "TablePro.Ssh.Resources");

    public static string Get(string key) => Text.Get(key);

    public static string Format(string key, params ReadOnlySpan<object?> args) => Text.Format(key, args);
}
