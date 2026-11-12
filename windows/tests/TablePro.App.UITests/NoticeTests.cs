using System.Globalization;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;
using FlaUI.Core.WindowsAPI;
using TablePro.Testing;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void APostgresNoticeShowsUnderMessages(string theme)
    {
        Assert.SkipUnless(SshTestEnvironment.Available, "Requires the Windows PostgreSQL fixture.");
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "PostgreSQL notices";
        app.Find("HostBox", form).AsTextBox().Text = "127.0.0.1";
        app.Find("PortBox", form).AsTextBox().Text = SshTestEnvironment.DatabasePort.ToString(CultureInfo.InvariantCulture);
        app.Find("UserBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("DatabaseBox", form).AsTextBox().Text = "tablepro_ssh";
        app.Find("PasswordInput", form).Patterns.Value.Pattern.SetValue(SshTestEnvironment.DatabasePassword);
        app.Find("ConnectButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");
        app.FindByName("ssh_proof", app.Find("ObjectTree"));

        // No rows, so the run opens on what it printed.
        app.TypeInto("Query 1", "DO $$ BEGIN RAISE NOTICE 'hello from TablePro'; END $$");
        app.Chord(MessagesShown, VirtualKeyShort.CONTROL, VirtualKeyShort.ENTER);
        Assert.Contains("NOTICE: hello from TablePro", WaitForMessages("hello from TablePro"), StringComparison.Ordinal);
        app.Screenshot("37-postgres-messages");

        // Rows open on the grid, and Messages holds what the script printed before them.
        app.TypeInto("Query 1", "DO $$ BEGIN RAISE NOTICE 'before the rows'; END $$; SELECT answer FROM ssh_proof");
        app.Chord(
            () => app.Find("QueryStatus").Properties.Name.ValueOrDefault?.StartsWith("Rows: 1", StringComparison.Ordinal) == true,
            VirtualKeyShort.CONTROL,
            VirtualKeyShort.ENTER);
        Assert.Equal("42", app.WaitForCell(app.Find("ResultsGrid"), 0, 0, value => value == "42"));
        Assert.False(MessagesShown());
        app.Click(app.Find("MessagesViewItem"), MessagesShown);
        Assert.Contains("NOTICE: before the rows", WaitForMessages("before the rows"), StringComparison.Ordinal);
        app.Screenshot("38-postgres-messages-beside-rows");

        bool MessagesShown() => app.TryFind("ResultsMessages") is { IsOffscreen: false };

        string WaitForMessages(string expected)
        {
            var text = string.Empty;
            Retry.WhileFalse(
                () => (text = app.Find("ResultsMessages").AsTextBox().Text).Contains(expected, StringComparison.Ordinal),
                AppSession.Wait,
                throwOnTimeout: false);
            return text;
        }
    }
}
