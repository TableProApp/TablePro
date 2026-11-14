using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Temporary probe: the roll back prompt after a cancelled close, many times in one process.
public sealed partial class ShellTests
{
    private static void Step(string line)
    {
        File.AppendAllText(Path.Combine(Path.GetTempPath(), "tablepro-probe-test.log"),
            DateTime.Now.ToString("HH:mm:ss.ffffff", System.Globalization.CultureInfo.InvariantCulture) + " TEST " + line + "\n");
    }

    [Fact]
    public void ProbeLoop()
    {
        var passes = int.TryParse(Environment.GetEnvironmentVariable("PROBE_PASSES"), out var count) ? count : 20;
        // The runner can start with the Start menu open, which takes the first keys.
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        var failures = new List<string>();
        for (var pass = 1; pass <= passes; pass++)
        {
            foreach (var theme in new[] { "Light", "Dark" })
            {
                Step($"=== pass {pass} {theme}");
                try
                {
                    ProbeOnce(theme);
                    Step("PASS");
                }
                catch (Exception e)
                {
                    Step("FAIL " + e.Message.Split('\n')[0]);
                    failures.Add($"pass {pass} {theme}: {e.Message.Split('\n')[0]}");
                }
            }
        }

        Assert.True(failures.Count == 0, $"{failures.Count} of {passes * 2} failed:\n" + string.Join("\n", failures));
    }

    private static void ProbeOnce(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        var first = AppSession.SampleDatabase(folder);
        var second = Path.Combine(folder, "second.sqlite");
        File.Copy(first, second);
        var state = new
        {
            connections = new[]
            {
                new { filePath = first, name = "First", engineId = "sqlite",
                    tabs = new[] { new { kind = "Query", title = "Query 1", sql = "BEGIN" } } },
                new { filePath = second, name = "Second", engineId = "sqlite",
                    tabs = new[] { new { kind = "Query", title = "Query 1", sql = "SELECT 2" } } },
            },
            front = 0,
        };
        File.WriteAllText(Path.Combine(folder, "session.json"), JsonSerializer.Serialize(state));
        using var app = AppSession.Relaunch(folder, theme);
        app.Find("SqlEditor");
        Step("ctrl+enter");
        app.Chord(() => app.TryFind("CommitButton") is { IsOffscreen: false }, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Step("select second");
        app.Find("Rail_Second").Patterns.SelectionItem.Pattern.Select();
        Assert.True(Retry.WhileFalse(() => AppSession.EditorText(app.Find("SqlEditor")) == "SELECT 2",
            AppSession.Wait, throwOnTimeout: false).Success);
        Step("alt+f4");
        app.Chord(() => app.TryFind("PrimaryButton") is not null, VirtualKeyShort.ALT, VirtualKeyShort.F4);
        Step("close dialog");
        app.CloseDialog();
        Step("closed dialog");
        Assert.True(app.Find("Rail_First").Patterns.SelectionItem.Pattern.IsSelected.Value);
        Step("select second again");
        app.Find("Rail_Second").Patterns.SelectionItem.Pattern.Select();
        Step("selected second");
        Assert.Equal("SELECT 2", AppSession.EditorText(app.Find("SqlEditor")));
        Step("select first");
        app.Find("Rail_First").Patterns.SelectionItem.Pattern.Select();
        Step("selected first");
        var button = app.Find("RollBackButton");
        Step("found roll back");
        button.AsButton().Invoke();
        Step("invoked roll back");
        app.PressDialogButton();
        Step("pressed dialog button");
    }
}
