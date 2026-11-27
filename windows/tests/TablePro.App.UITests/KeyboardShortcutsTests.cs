using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Per-shortcut rebinding of windows/docs/decisions/0028: record a chord, remove it, and reassign one a command already
// holds. The customs land in settings.json, which is what drives the menu accelerators.
public sealed class KeyboardShortcutsTests
{
    public static TheoryData<string> Themes => ["Light", "Dark"];

    [Theory]
    [MemberData(nameof(Themes))]
    public void RecordRemoveAndReassignWriteTheCustomShortcuts(string theme)
    {
        using var app = AppSession.Launch(theme);
        var settings = Path.Combine(app.DataFolder, "settings.json");

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        app.Click(app.Find("ShortcutsCard"), () => app.TryFind("KeyboardShortcutsPage") is { IsOffscreen: false });
        app.Screenshot("240-keyboard-shortcuts");

        // Record a free chord onto New query tab.
        Record(app, settings, "shortcut-recorder-newTab", "\"newTab\": \"ctrl+shift+j\"",
            VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_J);
        app.Screenshot("241-keyboard-recorded");

        // Delete removes the binding: the stored value becomes the cleared sentinel.
        Record(app, settings, "shortcut-recorder-newTab", "\"newTab\": \"\"", VirtualKeyShort.DELETE);

        // Ctrl+W belongs to Close tab, so recording it onto New query tab asks first.
        app.Click(app.Find("shortcut-recorder-newTab"));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Click(app.FindByName("Reassign"), () => Saved(settings, "\"newTab\": \"ctrl+w\""));
        app.Screenshot("242-keyboard-reassigned");

        Assert.True(Retry.WhileFalse(() => Saved(settings, "\"closeTab\": \"\""), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }

    private static bool Saved(string path, string fragment) =>
        File.Exists(path) && File.ReadAllText(path).Contains(fragment, StringComparison.Ordinal);

    private static void Record(AppSession app, string settings, string recorder, string fragment,
        params VirtualKeyShort[] keys)
    {
        app.Click(app.Find(recorder));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(keys);
        Assert.True(Retry.WhileFalse(() => Saved(settings, fragment), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }
}
