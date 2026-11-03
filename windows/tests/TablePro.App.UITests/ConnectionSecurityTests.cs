using FlaUI.Core.AutomationElements;
using FlaUI.Core.Tools;

namespace TablePro.App.UITests;

public sealed partial class ShellTests
{
    [Theory]
    [MemberData(nameof(Themes))]
    public void SqlServerStrictAndWindowsAuthenticationAreSavedAndRestored(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_mssql", form), () => app.TryFind("HostBox", form) is not null, form);
        app.Find("NameBox", form).AsTextBox().Text = "Strict SQL Server";
        var auth = app.Find("AuthBox", form).AsComboBox();
        auth.Select("Windows authentication");
        Assert.True(Retry.WhileFalse(
            () => (app.TryFind("UserBox", form) is null or { IsOffscreen: true })
                && (app.TryFind("PasswordInput", form) is null or { IsOffscreen: true }),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("31-sql-server-authentication", form);

        var tls = app.Find("TlsModeBox", form).AsComboBox();
        tls.Focus();
        tls.Select("Strict (TDS 8.0), verify the certificate and host");
        app.Click(app.Find("TlsExpander", form), () => app.TryFind("CaFileBox", form) is { IsOffscreen: false }, form);
        app.Find("ServerNameBox", form).AsTextBox().Text = "db.example.com";
        app.Find("ServerNameBox", form).Focus();
        app.Screenshot("32-sql-server-strict", form);
        app.Find("SaveButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        var row = app.FindByNamePrefix("Strict SQL Server,", app.Find("ConnectionTree"));
        app.Front();
        row.RightClick();
        app.FindMenuItem("Edit...").Patterns.Invoke.Pattern.Invoke();
        var edit = app.WaitForWindow("Edit connection");
        Assert.Equal("Windows authentication", app.Find("AuthBox", edit).AsComboBox().SelectedItem.Text);
        Assert.Equal("Strict (TDS 8.0), verify the certificate and host", app.Find("TlsModeBox", edit).AsComboBox().SelectedItem.Text);
        app.Click(app.Find("TlsExpander", edit), () => app.TryFind("CaFileBox", edit) is { IsOffscreen: false }, edit);
        Assert.Equal("db.example.com", app.Find("ServerNameBox", edit).AsTextBox().Text);
        app.Find("CancelButton", edit).AsButton().Invoke();
    }

    [Theory]
    [MemberData(nameof(Themes))]
    public void PostgresDoesNotOfferSqlServerStrictEncryption(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        var tls = app.Find("TlsModeBox", form).AsComboBox();
        tls.Focus();
        tls.Expand();
        Assert.DoesNotContain(tls.Items, item => item.Text.StartsWith("Strict", StringComparison.Ordinal));
        tls.Collapse();
        app.Find("CancelButton", form).AsButton().Invoke();
    }
}
