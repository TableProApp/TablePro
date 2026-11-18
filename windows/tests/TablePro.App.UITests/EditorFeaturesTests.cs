using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// Word wrap, folding, the statement band and color schemes, in the same class so they run one at a time with the rest.
public sealed partial class ShellTests
{
    // A line break is typed as '\r' (AppSession.TypeInto); the first statement spans five lines, the second one.
    private const string FoldableScript =
        "SELECT TrackId,\rName,\rComposer\rFROM Track\rWHERE TrackId < 5;\rSELECT 1 AS one;";

    private const string Brackets = "SELECT (1 + 2) AS a;\rSELECT 3 AS b;";

    // 400 characters on one line.
    private static readonly string LongLine = "SELECT " + string.Concat(Enumerable.Repeat("1 + ", 98)) + "1";

    [Theory]
    [MemberData(nameof(Themes))]
    public void SettingsOfferWordWrapTheStatementBandFoldingAndColorSchemes(string theme)
    {
        using var app = AppSession.Launch(theme);

        app.Find("SettingsButton").AsButton().Invoke();
        app.Find("SettingsPage");
        Assert.Equal(ToggleState.Off, app.Find("WordWrapSwitch").Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Equal(ToggleState.On, app.Find("StatementSwitch").Patterns.Toggle.Pattern.ToggleState.Value);
        Assert.Equal(ToggleState.On, app.Find("FoldingSwitch").Patterns.Toggle.Pattern.ToggleState.Value);
        var light = app.Find("LightSchemeBox").AsComboBox();
        light.Focus();
        light.Expand();
        var listed = light.Items.Select(item => item.Name).ToArray();
        var selected = light.SelectedItem?.Name;
        light.Collapse();
        Assert.Equal("Default", listed.FirstOrDefault());
        Assert.Contains("GitHub Light", listed);
        Assert.DoesNotContain("Dracula", listed);
        Assert.Equal("Default", selected);
        app.Find("DarkSchemeBox").Focus();
        app.Screenshot("133-settings-editor");

        app.Find("WordWrapSwitch").Patterns.Toggle.Pattern.Toggle();
        app.Find("DarkSchemeBox").AsComboBox().Select("Dracula");

        var saved = Retry.WhileFalse(
            () => File.ReadAllText(Path.Combine(app.DataFolder, "settings.json")) is var json
                && json.Contains("\"wordWrap\": true", StringComparison.Ordinal)
                && json.Contains("\"editorDarkScheme\": \"tablepro.dracula\"", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(saved);
    }

    // The text pattern gives one rectangle per screen row, so a wrapped line gives several.
    [Theory]
    [MemberData(nameof(Themes))]
    public void WordWrapBreaksALongLineOverSeveralRows(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        File.WriteAllText(Path.Combine(folder, "settings.json"), $$"""{ "theme": "{{theme}}", "wordWrap": true }""");
        using var app = AppSession.Relaunch(folder, theme);

        OpenSample(app);
        app.TypeInto("Query 1", LongLine);

        var editor = app.FindEditor("Query 1");
        var wrapped = Retry.WhileFalse(
            () => editor.Patterns.Text.Pattern.DocumentRange.GetBoundingRectangles().Length > 1,
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(wrapped);
        app.Screenshot("134-word-wrap");
    }

    // The visible ranges split where folded lines are hidden.
    [Theory]
    [MemberData(nameof(Themes))]
    public void FoldAllHidesAStatementsLinesAndUnfoldAllShowsThemAgain(string theme)
    {
        using var app = AppSession.Launch(theme);

        OpenSample(app);
        app.TypeInto("Query 1", FoldableScript);
        var editor = app.FindEditor("Query 1");
        Assert.Equal(1, VisibleRuns(editor));

        app.RightClick(editor, () => app.TryFindMenuItem("Fold All") is not null);
        app.FindMenuItem("Fold All").Patterns.Invoke.Pattern.Invoke();
        Assert.True(Retry.WhileFalse(() => VisibleRuns(editor) == 2, AppSession.Wait, throwOnTimeout: false).Success);
        app.Screenshot("135-folded");

        app.RightClick(editor, () => app.TryFindMenuItem("Unfold All") is not null);
        app.FindMenuItem("Unfold All").Patterns.Invoke.Pattern.Invoke();
        Assert.True(Retry.WhileFalse(() => VisibleRuns(editor) == 1, AppSession.Wait, throwOnTimeout: false).Success);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheStatementAtTheCaretAndTheBracketsBesideItAreMarked(string theme)
    {
        using var app = AppSession.Launch(theme);

        OpenSample(app);
        app.TypeInto("Query 1", Brackets);
        var editor = app.FindEditor("Query 1");
        app.Chord(() => CaretOffset(editor) == 0, VirtualKeyShort.CONTROL, VirtualKeyShort.HOME);
        var afterCloser = Brackets.IndexOf(')', StringComparison.Ordinal) + 1;
        for (var offset = 1; offset <= afterCloser; offset++)
        {
            var target = offset;
            app.Chord(() => CaretOffset(editor) == target, VirtualKeyShort.RIGHT);
        }

        app.Screenshot("136-statement-and-brackets");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AColorSchemeFromSettingsColorsTheEditor(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        File.WriteAllText(
            Path.Combine(folder, "settings.json"),
            $$"""
            {
              "theme": "{{theme}}",
              "editorLightScheme": "tablepro.github-light",
              "editorDarkScheme": "tablepro.dracula"
            }
            """);
        using var app = AppSession.Relaunch(folder, theme);

        OpenSample(app);
        app.TypeInto("Query 1", "SELECT 'TablePro' AS name, 42 AS answer; -- the scheme's colors");
        app.Screenshot("137-color-scheme");
    }

    private static void OpenSample(AppSession app)
    {
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
    }

    private static int VisibleRuns(AutomationElement editor) =>
        editor.Patterns.Text.Pattern.GetVisibleRanges().Length;

    // The length of the text before the caret, which the selection's start is while nothing is selected.
    private static int CaretOffset(AutomationElement editor)
    {
        var text = editor.Patterns.Text.Pattern;
        var caret = text.GetSelection()[0];
        var before = text.DocumentRange;
        before.MoveEndpointByRange(TextPatternRangeEndpoint.End, caret, TextPatternRangeEndpoint.Start);
        return before.GetText(-1).Length;
    }
}
