using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
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
        auth.Collapse();
        Assert.True(Retry.WhileFalse(
            () => (app.TryFind("UserBox", form) is null or { IsOffscreen: true })
                && (app.TryFind("PasswordInput", form) is null or { IsOffscreen: true }),
            AppSession.Wait,
            throwOnTimeout: false).Success);
        app.Screenshot("31-sql-server-authentication", form);

        var tls = app.Find("TlsModeBox", form).AsComboBox();
        tls.Focus();
        tls.Select("Strict (TDS 8.0), verify the certificate and host");
        tls.Collapse();
        ExpandTlsSettings(app, form);
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
        Assert.Equal("Windows authentication", app.Find("AuthBox", edit).AsComboBox().SelectedItem?.Text);
        Assert.Equal("Strict (TDS 8.0), verify the certificate and host", app.Find("TlsModeBox", edit).AsComboBox().SelectedItem?.Text);
        ExpandTlsSettings(app, edit);
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

    [Theory]
    [MemberData(nameof(Themes))]
    public void ANewConnectionStartsOnTheEnginesOwnEncryptionDefault(string theme)
    {
        using var app = AppSession.Launch(theme);
        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        var form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_postgres", form), () => app.TryFind("HostBox", form) is not null, form);
        Assert.Equal("Preferred, any certificate", app.Find("TlsModeBox", form).AsComboBox().SelectedItem?.Text);
        // Prefer checks no certificate, so the CA file row stays hidden and the client certificate shows.
        ExpandTlsSettings(app, form, "ClientCertificateBox");
        app.Screenshot("33-postgres-encryption-default", form);
        app.Find("CancelButton", form).AsButton().Invoke();
        app.WaitForClose("New connection");

        app.Click(app.Find("NewConnectionCard"), () => app.HasWindow("New connection"));
        form = app.WaitForWindow("New connection");
        app.Click(app.Find("Engine_mssql", form), () => app.TryFind("HostBox", form) is not null, form);
        Assert.Equal(
            "Required, verify the certificate and host",
            app.Find("TlsModeBox", form).AsComboBox().SelectedItem?.Text);
        app.Find("CancelButton", form).AsButton().Invoke();
    }

    private static void ExpandTlsSettings(AppSession app, Window form, string shownField = "CaFileBox")
    {
        // The toolkit's outer peer is a group; its native Expander owns expansion.
        var expander = app.Find("TlsExpander", form).FindFirstDescendant(condition =>
            condition.ByControlType(ControlType.Button).And(condition.ByName("SSL/TLS")));
        Assert.NotNull(expander);
        var expansion = expander.Patterns.ExpandCollapse.PatternOrDefault;
        Assert.NotNull(expansion);
        expansion.Expand();
        Assert.True(Retry.WhileFalse(
            () => app.TryFind(shownField, form) is { IsOffscreen: false },
            AppSession.Wait,
            throwOnTimeout: false).Success);
    }
}
