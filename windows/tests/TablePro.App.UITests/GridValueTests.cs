using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    // A 160 by 80 PNG of four colored bands.
    private const string Picture =
        "89504E470D0A1A0A0000000D49484452000000A0000000500802000000113FE963000000D54944415478DAEDD1310D00200C00B049181A30"
        + "C981317C2002176082644F933A68C4D825726689D37A89BBA24408162C58B060C182050B162C58B060C182050B162C58B060C182050B162C"
        + "58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B0"
        + "60C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C182050B162C58B060C1"
        + "82050B162C58B060C182050B162C58B060C182050B162CF89707A4833176794B97350000000049454E44AE426082";

    [Theory]
    [MemberData(nameof(Themes))]
    public void AQueryResultsMenuOpensAValueAsJsonAnImageOrItsHex(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        app.TypeInto("Query 1", $"SELECT '{{\"album\":\"Let There Be Rock\",\"tracks\":[15,16]}}' AS doc, X'{Picture}' AS cover");
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: ", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var grid = app.Find("ResultsGrid");
        app.WaitForCell(grid, 0, 0, value => value.StartsWith("{\"album\"", StringComparison.Ordinal));

        app.RightClick(CellOf(grid, 0, 0), () => app.TryFindMenuItem("View value...") is not null);
        Assert.NotNull(app.TryFindMenuItem("Export results..."));
        Assert.NotNull(app.TryFindMenuItem("Share result..."));
        app.Screenshot("80-results-grid-menu");
        app.Click(app.FindMenuItem("View value..."), () => app.TryFind("ValueViewer") is not null);
        var text = AppSession.WaitForText(
            app.Find("ValueViewerText"), value => value.Contains("\"tracks\": [", StringComparison.Ordinal));
        Assert.Contains("\"album\": \"Let There Be Rock\"", text, StringComparison.Ordinal);
        app.Screenshot("81-value-viewer-json");
        app.CloseDialog();
        Assert.True(Retry.WhileTrue(() => app.TryFind("ValueViewer") is not null, AppSession.Wait, throwOnTimeout: false).Success);

        app.RightClick(CellOf(grid, 0, 1), () => app.TryFindMenuItem("View value...") is not null);
        app.Click(app.FindMenuItem("View value..."), () => app.TryFind("ValueViewerImage") is { IsOffscreen: false });
        app.Screenshot("82-value-viewer-image");
        app.Click(app.Find("ValueViewerHexItem"), () => app.TryFind("ValueViewerText") is { IsOffscreen: false });
        Assert.StartsWith(
            "0x89504e47",
            AppSession.WaitForText(app.Find("ValueViewerText"), value => value.StartsWith("0x", StringComparison.Ordinal)),
            StringComparison.Ordinal);
        app.Screenshot("83-value-viewer-hex");
        app.CloseDialog();
    }
}
