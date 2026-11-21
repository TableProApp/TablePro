using System.Collections.Concurrent;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

// The SQL editor's completion and Format query, in the same class so they run one at a time with the rest.
public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void CompletionOffersTheCatalogAndTakesTheChosenName(string theme)
    {
        using var app = AppSession.Launch(theme);
        OpenSample(app);
        var editor = app.FindEditor("Query 1");
        var spoken = new ConcurrentQueue<string>();
        using var listener = editor.RegisterNotificationEvent(
            TreeScope.Element,
            (_, _, _, text, _) => spoken.Enqueue(text));

        app.TypeInto("Query 1", "SELECT * FROM Tr");
        app.FindByNamePrefix("Track, ", app.Find("CompletionList"));
        var heard = Retry.WhileFalse(
            () => spoken.Any(text => text.StartsWith("Track, ", StringComparison.Ordinal)),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(heard, "Narrator heard no row: " + string.Join(" | ", spoken));
        app.Screenshot("188-completion-tables");
        app.Chord(() => EditorLines(app) == "SELECT * FROM Track", VirtualKeyShort.RETURN);
        Assert.True(CompletionClosed(app));

        app.TypeInto("Query 1", "SELECT * FROM Track t WHERE t.");
        app.FindByNamePrefix("TrackId, ", app.Find("CompletionList"));
        app.Screenshot("189-completion-columns");
        app.Chord(() => SelectedCompletion(app).StartsWith("Name, ", StringComparison.Ordinal), VirtualKeyShort.DOWN);
        app.Chord(() => EditorLines(app) == "SELECT * FROM Track t WHERE t.Name", VirtualKeyShort.TAB);

        const string Partial = "SELECT * FROM Track t WHERE t.Mi";
        app.TypeInto("Query 1", Partial);
        app.FindByNamePrefix("Milliseconds, ", app.Find("CompletionList"));
        app.Chord(() => CompletionClosed(app), VirtualKeyShort.ESCAPE);
        Assert.Equal(Partial, EditorLines(app));

        app.Chord(
            () => app.TryFind("CompletionList") is { IsOffscreen: false },
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SPACE);
        app.FindByNamePrefix("Milliseconds, ", app.Find("CompletionList"));
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void FormatQueryReflowsTheTextAsOneUndoStep(string theme)
    {
        using var app = AppSession.Launch(theme);
        OpenSample(app);
        const string Typed = "select TrackId, Name from Track where Milliseconds > 1000 order by Name";

        app.TypeInto("Query 1", Typed);
        app.Chord(
            () => EditorLines(app).Contains('\n', StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.KEY_F);

        var formatted = EditorLines(app);
        Assert.StartsWith("select", formatted, StringComparison.Ordinal);
        Assert.Equal(Typed.Where(c => !char.IsWhiteSpace(c)), formatted.Where(c => !char.IsWhiteSpace(c)));
        app.Screenshot("190-format-query");
        app.Chord(() => EditorLines(app) == Typed, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_Z);
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void FormatQueryReflowsTheSelectionAloneFromTheQueryMenu(string theme)
    {
        using var app = AppSession.Launch(theme);
        OpenSample(app);
        const string Kept = "-- keep this line\r";
        const string Selected = "select TrackId, Name from Track";
        app.TypeInto("Query 1", Kept + Selected);
        var editor = app.FindEditor("Query 1");
        app.Chord(
            () => editor.Patterns.Text.Pattern.GetSelection()[0].GetText(-1) == Selected,
            VirtualKeyShort.SHIFT,
            VirtualKeyShort.HOME);

        app.Click(app.Find("QueryMenu"), () => app.TryFindMenuItem("Format query") is { IsEnabled: true });
        app.FindMenuItem("Format query").Patterns.Invoke.Pattern.Invoke();

        var reflowed = Retry.WhileFalse(
            () => EditorLines(app).StartsWith("-- keep this line\nselect\n", StringComparison.Ordinal),
            AppSession.Wait,
            throwOnTimeout: false).Success;
        Assert.True(reflowed, EditorLines(app));
        Assert.Equal(
            Selected.Where(c => !char.IsWhiteSpace(c)),
            EditorLines(app)["-- keep this line\n".Length..].Where(c => !char.IsWhiteSpace(c)));
        app.Screenshot("191-format-selection");
    }

    // The text pattern's line breaks are the document's own, which the tests compare as '\n'.
    private static string EditorLines(AppSession app) =>
        AppSession.EditorText(app.FindEditor("Query 1")).Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd('\n');

    private static string SelectedCompletion(AppSession app) =>
        app.TryFind("CompletionList")?.AsListBox().SelectedItem?.Properties.Name.ValueOrDefault ?? string.Empty;

    private static bool CompletionClosed(AppSession app) =>
        Retry.WhileFalse(
            () => app.TryFind("CompletionList") is null or { IsOffscreen: true },
            TimeSpan.FromSeconds(5),
            throwOnTimeout: false).Success;
}
