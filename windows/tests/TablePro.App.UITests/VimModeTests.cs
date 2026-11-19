using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Vim mode in the query editor (windows/docs/decisions/0017-vim-mode.md), in the same class so it runs one at a time.
public sealed partial class ShellTests
{
    private const string VimScript = "SELECT 1 AS one, 2 AS two;";

    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsOfferVimModeOffByDefault(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var vim = app.Find("VimSwitch");
        Assert.Equal(ToggleState.Off, vim.Patterns.Toggle.Pattern.ToggleState.Value);

        vim.Patterns.Toggle.Pattern.Toggle();
        var saved = Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json"))
                .Contains("\"vimMode\": true", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(saved);
        vim.Focus();
        app.Screenshot("180-settings-vim");
    }

    // Each key goes once and waits for what it does, since a key sent again would be a second Vim command.
    [Theory]
    [MemberData(nameof(Themes))]
    public void VimModeEditsTheQueryAndShowsItsModeOnTheBar(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        File.WriteAllText(Path.Combine(folder, "settings.json"), $$"""{ "theme": "{{theme}}", "vimMode": true }""");
        using var app = AppSession.Relaunch(folder, theme);

        OpenSample(app);
        var editor = app.FindEditor("Query 1");
        editor.Focus();
        Assert.True(Retry.WhileFalse(
            () => editor.Properties.HasKeyboardFocus.ValueOrDefault,
            AppSession.Wait,
            throwOnTimeout: false).Success);
        Assert.Equal("Vim mode: NORMAL", WaitForBadge(app, "NORMAL"));

        VimKeys(app, "i", () => BadgeSays(app, "INSERT"));
        VimKeys(app, VimScript, () => AppSession.EditorText(app.FindEditor("Query 1")) == VimScript);
        VimEscape(app, () => BadgeSays(app, "NORMAL"));

        VimKeys(app, "0", () => CaretOffset(app.FindEditor("Query 1")) == 0);
        VimKeys(app, "2", () => AppSession.TextOf(app.Find("VimKeys")) == "2");
        VimKeys(app, "d", () => AppSession.TextOf(app.Find("VimKeys")) == "2d");
        app.Screenshot("181-vim-pending-keys");
        VimKeys(app, "w", () => AppSession.EditorText(app.FindEditor("Query 1")) == "AS one, 2 AS two;");
        app.Screenshot("182-vim-normal");

        VimKeys(app, "u", () => AppSession.EditorText(app.FindEditor("Query 1")) == VimScript);
        VimKeys(app, "v", () => BadgeSays(app, "VISUAL"));
        VimKeys(app, "e", () => SelectedText(app.FindEditor("Query 1")) == "SELECT");
        app.Screenshot("183-vim-visual");
        VimEscape(app, () => BadgeSays(app, "NORMAL"));

        VimKeys(app, ":", () => BadgeSays(app, ":"));
        VimKeys(app, "w", () => BadgeSays(app, ":w"));
        app.Chord(
            () => AppSession.TextOf(app.Find("QueryStatus")).StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.RETURN);
        Assert.Equal("1", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "1"));
        Assert.True(BadgeSays(app, "NORMAL"));
        Assert.Equal(VimScript, AppSession.EditorText(app.FindEditor("Query 1")));
    }

    private static void VimKeys(AppSession app, string keys, Func<bool> landed)
    {
        app.Front();
        Keyboard.Type(keys);
        Assert.True(
            Retry.WhileFalse(landed, AppSession.Wait, throwOnTimeout: false).Success,
            $"Vim keys {keys} did nothing.");
    }

    private static void VimEscape(AppSession app, Func<bool> landed)
    {
        app.Front();
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        Assert.True(Retry.WhileFalse(landed, AppSession.Wait, throwOnTimeout: false).Success, "Escape did nothing.");
    }

    private static bool BadgeSays(AppSession app, string mode) =>
        AppSession.Holds(() => app.Find("VimMode").Name == "Vim mode: " + mode);

    private static string WaitForBadge(AppSession app, string mode)
    {
        Retry.WhileFalse(() => BadgeSays(app, mode), AppSession.Wait, throwOnTimeout: false);
        return app.Find("VimMode").Name;
    }

    private static string SelectedText(AutomationElement editor) =>
        editor.Patterns.Text.Pattern.GetSelection()[0].GetText(-1);
}
