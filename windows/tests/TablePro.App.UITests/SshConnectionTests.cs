using System.Diagnostics;
using System.Globalization;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Input;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using TablePro.Testing;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void AnSshConnectionTestsTheFormAndRunsAQuery(string theme)
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows SSH and PostgreSQL fixture.");
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "PostgreSQL over SSH";
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = SshTestEnvironment.DatabasePort.ToString(CultureInfo.InvariantCulture);
        app.Find("UserBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("DatabaseBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Click(app.Find("PasswordInput", form), form);
        Keyboard.Type(SshTestEnvironment.DatabasePassword);

        app.Find("SshSwitch", form).AsToggleButton().Toggle();
        app.Find("SshHostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("SshPortBox", form).AsTextBox().Text = theme == "Light" ? "22220" : "22221";
        app.Find("SshUserBox", form).AsTextBox().Text = SshTestEnvironment.SshUser;
        app.Find("TestButton", form).AsButton().Invoke();

        var details = app.Find("SshHostKeyDetails", form);
        Assert.Contains("SHA256:", details.Name, StringComparison.Ordinal);
        app.Screenshot("27-ssh-host-key", form);
        app.Find("PrimaryButton", form).AsButton().Invoke();
        Assert.Equal("Connected. These settings work.", AppSession.WaitForText(
            app.Find("FormStatus", form), text => text == "Connected. These settings work."));
        app.Screenshot("28-ssh-tested", form);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        app.FindByName("ssh_proof", app.Find("ObjectTree"));
        app.Chord(() => app.TryFind("SqlEditor") is not null, VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_T);
        app.TypeInto(app.Find("SqlEditor"), "SELECT answer FROM ssh_proof");
        app.Chord(
            () => app.Find("QueryStatus").Name.StartsWith("Rows: 1", StringComparison.Ordinal),
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        var results = app.Find("ResultsGrid");
        Assert.Equal("42", app.WaitForCell(results, 0, 0, value => value == "42"));
        app.Screenshot("29-ssh-query");

        try
        {
            var fingerprint = ChangeHostKey("Rotate");
            Assert.StartsWith("SHA256:", fingerprint, StringComparison.Ordinal);
            Assert.True(Retry.WhileFalse(
                () => app.TryFind("HealthBar")?.FindAllDescendants().Any(element =>
                    element.Name.StartsWith("The SSH server identity has changed.", StringComparison.Ordinal)) == true,
                TimeSpan.FromSeconds(60), throwOnTimeout: false).Success);
            var reconnect = app.Find("ReconnectButton");
            Assert.True(Retry.WhileFalse(() => !reconnect.IsOffscreen && reconnect.IsEnabled,
                TimeSpan.FromSeconds(60), throwOnTimeout: false).Success);
            reconnect.AsButton().Invoke();
            Assert.Contains(fingerprint, app.Find("CredentialPromptMessage").Name, StringComparison.Ordinal);
            app.Screenshot("30-ssh-changed-key");
            app.CloseDialog();

            Assert.Equal("SELECT answer FROM ssh_proof", AppSession.EditorText(app.Find("SqlEditor")).Trim());
            Assert.True(Retry.WhileFalse(() => reconnect.IsEnabled, AppSession.Wait, throwOnTimeout: false).Success);
            reconnect.AsButton().Invoke();
            app.Find("CredentialPromptMessage");
            app.PressDialogButton();
            Assert.Contains(fingerprint, app.Find("SshHostKeyDetails").Name, StringComparison.Ordinal);
            app.Screenshot("31-ssh-replacement-key");
            app.PressDialogButton();
            Assert.True(Retry.WhileFalse(() => app.TryFind("ReconnectButton") is null or { IsOffscreen: true },
                AppSession.Wait, throwOnTimeout: false).Success);

            // The same editor tab survives the reconnect; a different value proves the new run replaced its old result.
            app.TypeInto(app.Find("SqlEditor"), "SELECT answer + 1 FROM ssh_proof");
            app.Find("RunButton").AsButton().Invoke();
            Assert.Equal("43", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "43"));
            app.Screenshot("32-ssh-reconnected");
        }
        finally
        {
            try
            {
                app.Close();
            }
            finally
            {
                ChangeHostKey("Restore");
            }
        }
    }

    private static string ChangeHostKey(string action)
    {
        var start = new ProcessStartInfo("pwsh")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-File", SshTestEnvironment.RotateScript, "-Action", action })
        {
            start.ArgumentList.Add(argument);
        }

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Could not start the SSH fixture.");
        if (!process.WaitForExit(60_000))
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("The SSH fixture did not finish.");
        }

        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        Assert.True(process.ExitCode == 0, output + error);
        return output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? string.Empty;
    }
}
