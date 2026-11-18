using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    // Two connections as Navicat exports them, without their passwords.
    private const string NavicatExport = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Connections Ver="1.5">
          <Connection ConnectionName="Orders" ProjectUUID="" ConnType="MYSQL" ServiceProvider="Default"
            Host="orders.example.com" Port="3306" Database="orders" DatabaseFileName="" UserName="app" Password=""
            SavePassword="false" SSL="false" SSH="false" HTTP="false"/>
          <Connection ConnectionName="Analytics" ProjectUUID="" ConnType="POSTGRESQL" ServiceProvider="Default"
            Host="analytics.example.com" Port="5432" Database="warehouse" DatabaseFileName="" UserName="analyst"
            Password="" SavePassword="false" SSL="false" SSH="false" HTTP="false"/>
        </Connections>
        """;

    [Theory]
    [MemberData(nameof(Themes))]
    public void ANavicatExportImportsItsConnectionsIntoTheLibrary(string theme)
    {
        using var app = AppSession.Launch(theme);
        var file = Path.Combine(app.DataFolder, "connections.ncx");
        File.WriteAllText(file, NavicatExport);

        app.Click(app.Find("ImportButton"), () => app.TryFind("ImportFromAppMenuItem") is not null);
        app.Click(app.Find("ImportFromAppMenuItem"), () => app.TryFind("ImportAppSource_Navicat") is not null);
        var navicat = app.Find("ImportAppSource_Navicat");
        app.Click(navicat, () => navicat.AsRadioButton().IsChecked);
        Assert.True(app.Find("ImportAppPasswords").AsCheckBox().IsChecked);
        Assert.False(app.Find("ImportAppQueries").IsEnabled);

        // A click, not UIA's Invoke, which would wait on the picker Continue opens.
        app.Click(app.Find("PrimaryButton"));
        OpenInFileDialog(app, file);

        var orders = app.Find("ImportAppRow_row-0");
        var analytics = app.Find("ImportAppRow_row-1");
        Assert.Equal("Orders", orders.Name);
        Assert.Equal("Analytics", analytics.Name);
        Assert.True(orders.AsCheckBox().IsChecked);
        Assert.True(analytics.AsCheckBox().IsChecked);
        Assert.Equal(
            "2 of 2 connections selected",
            AppSession.WaitForText(app.Find("ImportAppSummary"), text => text == "2 of 2 connections selected"));
        app.Screenshot("112-import-from-app-review");

        app.PressDialogButton("Import");
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("ImportAppSummary") is null,
            AppSession.Wait,
            throwOnTimeout: false).Success);

        var tree = app.Find("ConnectionTree");
        app.FindByNamePrefix("Orders,", tree);
        app.FindByNamePrefix("Analytics,", tree);
        Assert.True(Retry.WhileFalse(
            () => app.TryFind("HomeMessageBar")?.FindAllDescendants().Any(element =>
                element.Properties.Name.ValueOrDefault == "Imported 2 connections.") == true,
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("113-import-from-app-done");
    }
}
