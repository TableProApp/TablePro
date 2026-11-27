using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Per-shortcut rebinding (windows/docs/decisions/0028-per-shortcut-rebinding.md), in the same class so it runs one at a time.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void RecordRemoveAndReassignWriteTheCustomShortcuts(string theme)
    {
        using var app = AppSession.Launch(theme);
        var settings = Path.Combine(app.DataFolder, "settings.json");

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        var card = app.Find("ShortcutsCard");
        // The card sits below the fold on the runner's screen, and a click needs a point on screen.
        card.Patterns.ScrollItem.Pattern.ScrollIntoView();
        app.Click(card, () => app.TryFind("KeyboardShortcutsPage") is { IsOffscreen: false });
        app.Screenshot("240-keyboard-shortcuts");

        // Record a free chord onto New query tab.
        RecordShortcut(app, settings, "shortcut-recorder-newTab", "\"newTab\": \"ctrl+shift+j\"",
            VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_J);
        app.Screenshot("241-keyboard-recorded");

        // Delete removes the binding: the stored value becomes the cleared sentinel.
        RecordShortcut(app, settings, "shortcut-recorder-newTab", "\"newTab\": \"\"", VirtualKeyShort.DELETE);

        // Ctrl+W belongs to Close tab, so recording it onto New query tab asks first.
        app.Click(app.Find("shortcut-recorder-newTab"));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Click(app.FindByName("Reassign"), () => SettingsHold(settings, "\"newTab\": \"ctrl+w\""));
        app.Screenshot("242-keyboard-reassigned");

        Assert.True(Retry.WhileFalse(() => SettingsHold(settings, "\"closeTab\": \"\""), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }

    private static bool SettingsHold(string path, string fragment) =>
        File.Exists(path) && File.ReadAllText(path).Contains(fragment, StringComparison.Ordinal);

    private static void RecordShortcut(AppSession app, string settings, string recorder, string fragment,
        params VirtualKeyShort[] keys)
    {
        app.Click(app.Find(recorder));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(keys);
        Assert.True(Retry.WhileFalse(() => SettingsHold(settings, fragment), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }
}
