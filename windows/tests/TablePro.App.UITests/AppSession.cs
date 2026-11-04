using System.Diagnostics;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;

namespace TablePro.App.UITests;

// The data folder outlives the session, so a test can relaunch the app over it.
internal sealed class AppSession : IDisposable
{
    public static readonly TimeSpan Wait = TimeSpan.FromSeconds(30);

    private readonly UIA3Automation _automation = new();
    private readonly Application _application;

    private AppSession(string dataFolder, string theme, bool maximize = true)
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
        if (maximize)
        {
            Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Maximized);
        }
    }

    public string DataFolder { get; }

    public string Theme { get; }

    public Window Window { get; }

    // rowLimit sets how many rows a page holds, so a small table has later pages.
    public static string NewDataFolder(string theme, int? rowLimit = null)
    {
        var folder = Directory.CreateTempSubdirectory("tablepro-ui-").FullName;
        var limit = rowLimit is { } rows ? $$""", "rowLimit": {{rows}}""" : string.Empty;
        File.WriteAllText(Path.Combine(folder, "settings.json"), $$"""{ "theme": "{{theme}}"{{limit}} }""");
        return folder;
    }

    public static AppSession Launch(string theme) => new(NewDataFolder(theme), theme);

    public static AppSession Relaunch(string dataFolder, string theme, bool maximize = true) =>
        new(dataFolder, theme, maximize);

    public static string LibraryFile(string folder) =>
        Directory.EnumerateFiles(folder, "connections.json", SearchOption.AllDirectories).First();

    // Steps past the drag threshold, as a person's drag does.
    public void Drag(AutomationElement from, AutomationElement to)
    {
        Front();
        Drag(from.GetClickablePoint(), to.GetClickablePoint());
    }

    // The Arm64 runner's own windows take keys and drags now and then, so each goes again until it lands.
    public void Drag(Func<AutomationElement> from, Func<AutomationElement> to, Func<bool> landed) =>
        Again(() => Drag(from(), to()), landed, "The drag");

    public void Chord(Func<bool> landed, params VirtualKeyShort[] keys) =>
        Again(() => Keyboard.TypeSimultaneously(keys), landed, string.Join("+", keys));

    public void TypeInto(string title, string text) =>
        Again(
            () =>
            {
                var editor = FindEditor(title);
                editor.Focus();
                if (!Retry.WhileFalse(
                        () => editor.Properties.HasKeyboardFocus.ValueOrDefault,
                        Wait,
                        throwOnTimeout: false).Success)
                {
                    throw Failure($"The {title} editor did not take keyboard focus.", screen: true);
                }

                Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
                Keyboard.Type(text);
            },
            () => EditorText(FindEditor(title)).TrimEnd('\r', '\n') == text,
            $"Typing {text}");

    public AutomationElement FindEditor(string title) =>
        Retry.WhileNull(
                () =>
                {
                    // A tab header appears before its selected editor has finished layout.
                    var editor = Window.FindFirstDescendant(condition =>
                        condition.ByAutomationId("SqlEditor").And(condition.ByName($"SQL editor, {title}")));
                    if (editor is null || !editor.IsEnabled || editor.IsOffscreen)
                    {
                        return null;
                    }

                    var bounds = editor.BoundingRectangle;
                    return bounds.Width > 0 && bounds.Height > 0 ? editor : null;
                },
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure($"The {title} editor did not become ready.", screen: true);

    private void Again(Action act, Func<bool> landed, string what)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            Front();
            act();
            if (Retry.WhileFalse(landed, TimeSpan.FromSeconds(5), throwOnTimeout: false).Success)
            {
                return;
            }
        }

        throw Failure($"{what} did nothing.", screen: true);
    }

    // WinUI does not see FlaUI's SetCursorPos as a pointer moving with the button down, so this uses SendInput.
    public static void Drag(System.Drawing.Point start, System.Drawing.Point end)
    {
        PointerInput.Move(start);
        Thread.Sleep(100);
        PointerInput.Button(down: true);
        Thread.Sleep(200);
        for (var step = 1; step <= 20; step++)
        {
            PointerInput.Move(new System.Drawing.Point(
                start.X + ((end.X - start.X) * step / 20),
                start.Y + ((end.Y - start.Y) * step / 20)));
            Thread.Sleep(40);
        }

        Thread.Sleep(300);
        PointerInput.Button(down: false);
        Thread.Sleep(300);
    }

    // TreeViewItem's check box is raw to UI Automation, so a row in selection mode checks through its selection.
    public void Check(AutomationElement row, bool isChecked = true)
    {
        Front();
        if (row.FindFirstDescendant(condition => condition.ByControlType(ControlType.CheckBox)) is { } box)
        {
            if (box.AsCheckBox().IsChecked != isChecked)
            {
                box.Click();
            }

            return;
        }

        if (row.Patterns.SelectionItem.PatternOrDefault is { } selection)
        {
            if (isChecked)
            {
                selection.AddToSelection();
            }
            else
            {
                selection.RemoveFromSelection();
            }

            return;
        }

        row.Click();
    }

    // The ContentDialog template names its primary button PrimaryButton.
    public void PressDialogButton()
    {
        var button = Retry.WhileNull(
                () => Window.FindFirstDescendant(condition => condition.ByAutomationId("PrimaryButton")),
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure("No dialog opened.", screen: true);
        button.AsButton().Invoke();
    }

    public void CloseDialog()
    {
        var button = Retry.WhileNull(
                () => Window.FindFirstDescendant(condition => condition.ByAutomationId("CloseButton")),
                Wait,
                throwOnTimeout: false).Result
            ?? throw Failure("No dialog opened.", screen: true);
        button.AsButton().Invoke();
    }

    // A menu flyout's item, which UI Automation lists under the window that opened it.
    public AutomationElement FindMenuItem(string name) =>
        Retry.WhileNull(() => TryFindMenuItem(name), Wait, throwOnTimeout: false).Result
            ?? throw Failure($"No menu item {name} appeared.", screen: true);

    // A click did not always open a submenu on the runner, and a pointer gliding to its item opens its neighbours'.
    public AutomationElement OpenSubmenu(string name, string child)
    {
        var item = FindMenuItem(name);
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (item.Patterns.ExpandCollapse.PatternOrDefault is { } submenu)
            {
                submenu.Expand();
            }
            else
            {
                Click(item);
            }

            var found = Retry.WhileNull(() => TryFindMenuItem(child), TimeSpan.FromSeconds(5), throwOnTimeout: false).Result;
            if (found is not null)
            {
                return found;
            }
        }

        throw Failure($"No menu item {child} appeared.", screen: true);
    }

    private AutomationElement? TryFindMenuItem(string name) =>
        Window.FindFirstDescendant(condition => condition.ByControlType(ControlType.MenuItem).And(condition.ByName(name)));

    public static string EditorText(AutomationElement editor) =>
        editor.Patterns.Text.Pattern.DocumentRange.GetText(-1);

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

    // Mouse and keys reach the foreground window, and the Arm64 runner opens windows of its own over the app.
    public void Front(Window? window = null) => (window ?? Window).SetForeground();

    public void Click(AutomationElement element, Window? window = null)
    {
        Front(window);
        element.Click();
    }

    // A window the runner opens for a moment can take a click, so it goes again until the app shows it landed.
    public void Click(AutomationElement element, Func<bool> landed, Window? window = null)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            Click(element, window);
            if (Retry.WhileFalse(landed, TimeSpan.FromSeconds(5), throwOnTimeout: false).Success)
            {
                return;
            }
        }

        throw Failure($"Clicking {element.Properties.AutomationId.ValueOrDefault} did nothing.", screen: true);
    }

    public bool HasWindow(string title) => OpenWindow(title) is not null;

    // Waits, since rows from a new run replace the old ones.
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

    // A header is found again each time: a new run's data can hand its element to another column.
    public static string WaitForItemStatus(Func<AutomationElement> header, string expected)
    {
        var status = string.Empty;
        Retry.WhileFalse(
            () =>
            {
                status = header().Properties.ItemStatus.ValueOrDefault ?? string.Empty;
                return status == expected;
            },
            Wait,
            throwOnTimeout: false);
        return status;
    }

    public static double WaitForWidth(Func<AutomationElement> element, double expected)
    {
        var width = 0.0;
        Retry.WhileFalse(
            () =>
            {
                width = element().BoundingRectangle.Width;
                return Math.Abs(width - expected) < 1;
            },
            Wait,
            throwOnTimeout: false);
        return width;
    }

    public static string Cell(AutomationElement grid, int row, int column) =>
        grid.Patterns.Grid.Pattern.GetItem(row, column)?.Name ?? string.Empty;

    public void SortBy(AutomationElement grid, string column) =>
        FindByName(column, grid).Patterns.Invoke.Pattern.Invoke();

    public AutomationElement? TryFind(string automationId, Window? window = null) =>
        (window ?? Window).FindFirstDescendant(condition => condition.ByAutomationId(automationId));

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
