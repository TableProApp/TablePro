using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    public static TheoryData<string, string> ThemesAndFileEngines => new()
    {
        { "Light", "duckdb" },
        { "Dark", "duckdb" },
        { "Light", "sqlite" },
        { "Dark", "sqlite" },
    };

    [Theory]
    [MemberData(nameof(ThemesAndFileEngines))]
    public void ANewFileNamedInTheSavePickerIsMadeAndConnects(string theme, string engine)
    {
        using var app = AppSession.Launch(theme);
        var file = Path.Combine(app.DataFolder, $"made.{engine}");
        var name = $"New {engine} file";
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find($"Engine_{engine}", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = name;
        app.Click(app.Find("NewFileButton", form), () => SaveDialog(app, form) is not null, form);
        SaveInFileDialog(app, form, file);
        // The path reaches the form after the dialog closes, with a folder typed by its 8.3 name in its long form.
        var fileBox = app.Find("FileBox", form).AsTextBox();
        Assert.True(
            Retry.WhileFalse(() => Path.GetFileName(fileBox.Text) == Path.GetFileName(file), AppSession.Wait, throwOnTimeout: false).Success,
            "The form shows " + fileBox.Text);
        Assert.False(File.Exists(file), "the picker made the file before Connect");
        var status = app.Find("FormStatus", form);
        Assert.Equal("The file is made when you connect", AppSession.WaitForText(status, text => text.Length > 0));
        app.Screenshot($"109-new-{engine}-file-named", form);

        app.Find("ConnectButton", form).AsButton().Invoke();
        // The status is read only while the form is still open, since a closed form's elements are gone.
        if (!Retry.WhileFalse(() => !app.HasWindow("New connection"), AppSession.Wait, throwOnTimeout: false).Success)
        {
            Assert.Fail("The form stayed open: " + AppSession.TextOf(status));
        }

        Assert.True(File.Exists(file));
        Assert.False(app.Find($"Rail_{name}").IsOffscreen);
        app.Find("ObjectTree");
        app.Screenshot($"110-new-{engine}-file-connected");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AnExistingFileNamedForANewOneOpensAsItIsWithoutAReplaceQuestion(string theme)
    {
        using var app = AppSession.Launch(theme);
        var file = AppSession.SampleDatabase(app.DataFolder);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "Kept";
        app.Click(app.Find("NewFileButton", form), () => SaveDialog(app, form) is not null, form);
        SaveInFileDialog(app, form, file);
        Assert.Equal(
            "This file exists, so it opens as it is",
            AppSession.WaitForText(app.Find("FormStatus", form), text => text.Length > 0));
        app.Screenshot("111-new-file-exists", form);

        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        app.FindByName("Album", app.Find("ObjectTree"));
    }

    // The form owns its picker, so UI Automation lists it under the form, the app's window or the desktop.
    private static Window? SaveDialog(AppSession app, Window form) =>
        form.FindFirstChild(condition => condition.ByClassName("#32770"))?.AsWindow() ?? FileDialog(app);

    // The Save dialog's File name box is control 1001, and Enter saves to the path typed there.
    private static void SaveInFileDialog(AppSession app, Window form, string path)
    {
        var dialog = Retry.WhileNull(() => SaveDialog(app, form), AppSession.Wait, throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The Save dialog did not appear.");
        var box = Retry.WhileNull(
                () => dialog.FindFirstDescendant(condition =>
                    condition.ByAutomationId("1001").And(condition.ByControlType(ControlType.Edit))),
                AppSession.Wait,
                throwOnTimeout: false).Result
            ?? throw new InvalidOperationException("The Save dialog has no File name box.");
        // The Save dialog keeps its suggested name when the box's value is set without typing, so the path is typed.
        dialog.SetForeground();
        box.Focus();
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_A);
        Keyboard.Type(path);
        if (!Retry.WhileFalse(() => box.AsTextBox().Text == path, AppSession.Wait, throwOnTimeout: false).Success)
        {
            throw new InvalidOperationException("The Save dialog did not take the path typed.");
        }

        Keyboard.Type(VirtualKeyShort.RETURN);
        if (!Retry.WhileFalse(() => SaveDialog(app, form) is null, AppSession.Wait, throwOnTimeout: false).Success)
        {
            throw new InvalidOperationException("The Save dialog did not take the path.");
        }
    }
}
