using System.Text.Json;
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
        RecordShortcut(app, settings, "newTab", "ctrl+shift+j",
            VirtualKeyShort.CONTROL, VirtualKeyShort.SHIFT, VirtualKeyShort.KEY_J);
        app.Screenshot("241-keyboard-recorded");

        // Delete removes the binding: the stored value becomes the cleared sentinel.
        RecordShortcut(app, settings, "newTab", string.Empty, VirtualKeyShort.DELETE);

        // Ctrl+W belongs to Close tab, so recording it onto New query tab asks first.
        app.Click(app.Find("shortcut-recorder-newTab"));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
        app.Click(app.FindByName("Reassign"), () => OverrideIs(settings, "newTab", "ctrl+w"));
        app.Screenshot("242-keyboard-reassigned");

        Assert.True(Retry.WhileFalse(() => OverrideIs(settings, "closeTab", string.Empty), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }

    // The settings writer escapes + as +, so the stored value is compared, not the file's text.
    private static bool OverrideIs(string path, string action, string keys)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        using var settings = JsonDocument.Parse(File.ReadAllText(path));
        return settings.RootElement.TryGetProperty("shortcutOverrides", out var overrides)
            && overrides.ValueKind == JsonValueKind.Object
            && overrides.TryGetProperty(action, out var value)
            && value.GetString() == keys;
    }

    private static void RecordShortcut(AppSession app, string settings, string action, string keys,
        params VirtualKeyShort[] chord)
    {
        app.Click(app.Find("shortcut-recorder-" + action));
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(chord);
        Assert.True(Retry.WhileFalse(() => OverrideIs(settings, action, keys), AppSession.Wait,
            throwOnTimeout: false).Success, File.ReadAllText(settings));
    }
}
