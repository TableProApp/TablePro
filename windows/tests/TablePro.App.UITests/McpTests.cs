using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

// The tablepro command beside the app, run as a script runs it, against the app's own MCP server on 127.0.0.1.
public sealed partial class ShellTests
{
    private const string GenreUpdate = "UPDATE Genre SET Name = 'Rock music' WHERE GenreId = 1";

    private sealed record Ran(int Exit, string Out, string Err);

    private static AppSession LaunchWithMcp(string theme)
    {
        var folder = AppSession.NewDataFolder(theme);
        File.WriteAllText(
            Path.Combine(folder, "settings.json"),
            JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["theme"] = theme,
                ["mcpServerEnabled"] = true,
                ["mcpServerPort"] = FreePort(),
            }));
        return AppSession.Relaunch(folder, theme);
    }

    private static int FreePort()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        return ((IPEndPoint)listener.LocalEndpoint).Port;
    }

    // Its standard input is a pipe closed at once, so it never opens a connection itself, as a script's would not.
    private static Process StartCommand(AppSession app, params string[] arguments)
    {
        var program = Path.Combine(
            Path.GetDirectoryName(Environment.GetEnvironmentVariable("TABLEPRO_APP"))!,
            "tablepro-cli.exe");
        var start = new ProcessStartInfo(program)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }

        start.Environment["TABLEPRO_DATA_DIR"] = app.DataFolder;
        var process = Process.Start(start) ?? throw new InvalidOperationException("tablepro-cli.exe did not start.");
        process.StandardInput.Close();
        return process;
    }

    private static Ran Finish(Process process)
    {
        using (process)
        {
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(AppSession.Wait))
            {
                process.Kill();
                throw new TimeoutException("tablepro-cli.exe did not finish.");
            }

            return new Ran(
                process.ExitCode,
                output.Result.Replace("\r", string.Empty, StringComparison.Ordinal),
                errors.Result.Replace("\r", string.Empty, StringComparison.Ordinal));
        }
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void TheCommandReadsAConnectionTheAppHasOpenThroughItsMcpServer(string theme)
    {
        using var app = LaunchWithMcp(theme);

        var version = Finish(StartCommand(app, "--version"));
        var completion = Finish(StartCommand(app, "completion", "powershell"));
        app.Click(app.Find("SampleCard"), () => app.TryFind("Rail_Chinook (Sample)") is not null);
        app.FindByName("Track", app.Find("ObjectTree"));
        var counted = Finish(StartCommand(app, "query", "-c", "Chinook (Sample)", "SELECT count(*) AS n FROM Track"));
        var status = Finish(StartCommand(app, "status", "--format", "json"));
        var refused = Finish(StartCommand(app, "query", "-c", "Chinook (Sample)", GenreUpdate));

        Assert.Equal(0, version.Exit);
        Assert.Matches(@"^tablepro \d+\.\d+\.\d+\n$", version.Out);
        Assert.DoesNotContain("0.0.0", version.Out, StringComparison.Ordinal);
        Assert.Contains("Register-ArgumentCompleter -Native -CommandName 'tablepro'", completion.Out, StringComparison.Ordinal);
        Assert.True(counted.Exit == 0, counted.Err);
        Assert.Equal("n\n3503\n", counted.Out);
        Assert.True(status.Exit == 0, status.Err);
        Assert.Contains("\"ready\":true", status.Out, StringComparison.Ordinal);
        // A new connection is Read only to clients, so a write is refused without a question.
        Assert.Equal(3, refused.Exit);

        // With a connection open the rail holds Settings; the File menu reaches it from anywhere.
        app.Click(app.Find("FileMenu"), () => app.TryFindMenuItem("Settings") is not null);
        app.FindMenuItem("Settings").Patterns.Invoke.Pattern.Invoke();
        app.Find("SettingsPage");
        // The section sits near the page's end, and the expander's items are realized only once it is in view.
        app.Find("SettingsPage").Patterns.Scroll.Pattern.SetScrollPercent(-1, 100);
        var clients = app.Find("McpClientsExpander").FindFirstDescendant(condition =>
            condition.ByControlType(ControlType.Button).And(condition.ByName("Clients")));
        Assert.NotNull(clients);
        clients.Patterns.ExpandCollapse.Pattern.Expand();
        app.FindByName("Command Line", app.Find("McpClientsExpander"));
        app.Screenshot("150-settings-mcp");
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void AWriteFromTheCommandWaitsForTheQuestionInItsWindow(string theme)
    {
        using var app = LaunchWithMcp(theme);
        var database = AppSession.SampleDatabase(app.DataFolder);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_sqlite", form), () => app.TryFind("FileBox", form) is not null, form);
        app.Find("FileBox", form).AsTextBox().Text = database;
        app.Find("NameBox", form).AsTextBox().Text = "Writable";
        app.Click(app.Find("OptionsExpander", form), () => app.TryFind("ExternalAccessBox", form) is { IsOffscreen: false }, form);
        var access = app.Find("ExternalAccessBox", form).AsComboBox();
        Assert.Equal("Read only", access.SelectedItem?.Text);
        access.Select("Read and write");
        access.Collapse();
        app.Screenshot("151-connection-external-clients", form);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        app.FindByName("Album", app.Find("ObjectTree"));

        var declining = StartCommand(app, "query", "-c", "Writable", GenreUpdate);
        Assert.Equal(GenreUpdate, AppSession.TextOf(app.Find("ClientWriteStatement")));
        app.Screenshot("152-mcp-write-question");
        app.CloseDialog();
        var declined = Finish(declining);
        Assert.True(
            Retry.WhileFalse(() => app.TryFind("ClientWriteStatement") is null, AppSession.Wait, throwOnTimeout: false).Success,
            "The question stayed open after Cancel.");
        var approving = StartCommand(app, "query", "-c", "Writable", GenreUpdate);
        app.Find("ClientWriteStatement");
        app.PressDialogButton("Run");
        var approved = Finish(approving);

        Assert.Equal(3, declined.Exit);
        Assert.True(approved.Exit == 0, approved.Err);
        Assert.Equal("1 row affected.\n", approved.Err);
    }
}
