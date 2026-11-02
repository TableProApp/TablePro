using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.UIA3;

namespace TablePro.App.UITests;

// One launch of the app over a data folder of its own. The folder outlives the session when a test relaunches.
internal sealed class AppSession : IDisposable
{
    public static readonly TimeSpan Wait = TimeSpan.FromSeconds(30);

    private readonly UIA3Automation _automation = new();
    private readonly Application _application;

    private AppSession(string dataFolder, string theme)
    {
        DataFolder = dataFolder;
        Theme = theme;
        var path = Environment.GetEnvironmentVariable("TABLEPRO_APP");
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            throw new InvalidOperationException("TABLEPRO_APP must name the built TablePro.exe.");
        }

        var start = new ProcessStartInfo(path) { UseShellExecute = false };
        start.Environment["TABLEPRO_DATA_DIR"] = dataFolder;
        _application = Application.Launch(start);
        Window = _application.GetMainWindow(_automation, Wait)
            ?? throw new InvalidOperationException("The main window did not open.");
        // The runner's screen is small; a maximized window fits it whole for the screenshots.
        Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Maximized);
    }

    public string DataFolder { get; }

    public string Theme { get; }

    public Window Window { get; }

    public static string NewDataFolder(string theme)
    {
        var folder = Directory.CreateTempSubdirectory("tablepro-ui-").FullName;
        File.WriteAllText(Path.Combine(folder, "settings.json"), $$"""{ "theme": "{{theme}}" }""");
        return folder;
    }

    public static AppSession Launch(string theme) => new(NewDataFolder(theme), theme);

    public static AppSession Relaunch(string dataFolder, string theme) => new(dataFolder, theme);

    public static string SampleDatabase(string folder)
    {
        var app = Environment.GetEnvironmentVariable("TABLEPRO_APP")!;
        var source = Path.Combine(Path.GetDirectoryName(app)!, "Assets", "Samples", "Chinook.sqlite");
        var target = Path.Combine(folder, "chinook-copy.sqlite");
        File.Copy(source, target, overwrite: true);
        return target;
    }

    public AutomationElement Find(string automationId, Window? window = null) =>
        Retry.WhileNull(
                () => (window ?? Window).FindFirstDescendant(condition => condition.ByAutomationId(automationId)),
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure($"No element {automationId} appeared.");

    public AutomationElement FindByName(string name, AutomationElement? scope = null) =>
        Retry.WhileNull(
                () => (scope ?? Window).FindFirstDescendant(condition => condition.ByName(name)),
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure($"No element named {name} appeared.");

    public AutomationElement FindByNamePrefix(string prefix, AutomationElement scope) =>
        Retry.WhileNull(
                () => scope.FindAllDescendants().FirstOrDefault(element =>
                    element.Properties.Name.TryGetValue(out var name) && name.StartsWith(prefix, StringComparison.Ordinal)),
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure($"No element named {prefix}... appeared.");

    // A cell's name is its text. Waits until done accepts it, as rows from a new run replace the old ones.
    public string WaitForCell(AutomationElement grid, int row, int column, Func<string, bool> done)
    {
        var text = string.Empty;
        if (!Retry.WhileFalse(
                () =>
                {
                    text = grid.Patterns.Grid.Pattern.GetItem(row, column)?.Name ?? string.Empty;
                    return done(text);
                },
                Wait,
                throwOnTimeout: false).Success)
        {
            throw Failure($"Cell ({row}, {column}) stayed '{text}'.");
        }

        return text;
    }

    public static string Cell(AutomationElement grid, int row, int column) =>
        grid.Patterns.Grid.Pattern.GetItem(row, column)?.Name ?? string.Empty;

    public void SortBy(AutomationElement grid, string column) =>
        FindByName(column, grid).Patterns.Invoke.Pattern.Invoke();

    public AutomationElement? TryFind(string automationId) =>
        Window.FindFirstDescendant(condition => condition.ByAutomationId(automationId));

    // UI Automation lists an owned window under its owner, not under the desktop.
    public Window WaitForWindow(string title) =>
        Retry.WhileNull(() => OpenWindow(title), Wait, throwOnTimeout: false).Result
            ?? throw Failure($"No window {title} opened.");

    public void WaitForClose(string title)
    {
        if (!Retry.WhileTrue(() => OpenWindow(title) is not null, Wait, throwOnTimeout: false).Success)
        {
            throw Failure($"The window {title} stayed open.", screen: true);
        }
    }

    private Window? OpenWindow(string title) =>
        _application.GetAllTopLevelWindows(_automation).FirstOrDefault(window => window.Title == title)
        ?? Window.FindFirstChild(condition => condition.ByControlType(ControlType.Window).And(condition.ByName(title)))
            ?.AsWindow();

    // A failure says what the screen showed and what the app logged before it ended.
    private InvalidOperationException Failure(string message, bool screen = false)
    {
        Screenshot("failure-" + DateTime.UtcNow.ToString("HHmmssfff", System.Globalization.CultureInfo.InvariantCulture), screen: screen);
        var crash = Path.Combine(DataFolder, "crash.log");
        var log = File.Exists(crash) ? Environment.NewLine + File.ReadAllText(crash) : string.Empty;
        var exited = _application.HasExited ? " The app has exited." : string.Empty;
        return new InvalidOperationException(message + exited + log);
    }

    public static string WaitForText(AutomationElement element, Func<string, bool> done)
    {
        var text = string.Empty;
        Retry.WhileFalse(
            () =>
            {
                text = element.Name;
                return done(text);
            },
            Wait,
            throwOnTimeout: false);
        return text;
    }

    // Saved under TABLEPRO_UI_SCREENSHOTS/<theme>/ when the variable is set, for the pull request.
    public void Screenshot(string name, Window? window = null, bool screen = false)
    {
        var root = Environment.GetEnvironmentVariable("TABLEPRO_UI_SCREENSHOTS");
        if (string.IsNullOrEmpty(root))
        {
            return;
        }

        Thread.Sleep(500);
        var folder = Path.Combine(root, Theme.ToLowerInvariant());
        Directory.CreateDirectory(folder);
        if (screen || _application.HasExited)
        {
            Capture.Screen().ToFile(Path.Combine(folder, name + ".png"));
            return;
        }

        Capture.Element(window ?? Window).ToFile(Path.Combine(folder, name + ".png"));
    }

    public void Close()
    {
        Window.Close();
        Retry.WhileFalse(() => _application.HasExited, Wait, throwOnTimeout: false);
    }

    public void Dispose()
    {
        if (!_application.HasExited)
        {
            _application.Close();
            if (!Retry.WhileFalse(() => _application.HasExited, TimeSpan.FromSeconds(5), throwOnTimeout: false).Success)
            {
                _application.Kill();
            }
        }

        _application.Dispose();
        _automation.Dispose();
    }
}
