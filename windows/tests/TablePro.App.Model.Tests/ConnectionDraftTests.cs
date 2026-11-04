using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ConnectionDraftTests
{
    private static readonly DatabaseEngine Postgres = new("postgres", "PostgreSQL", DataModel.Relational, 5432, [])
    {
        SupportsClientIdentity = true,
    };
    private static readonly DatabaseEngine Sqlite = new("sqlite", "SQLite", DataModel.Relational, null, ["sqlite", "db"]);

    private static string AbsolutePath(string name) =>
        Path.Combine(Path.GetPathRoot(Path.GetTempPath())!, "data", name);

    [Fact]
    public void ANewNetworkConnectionStartsAtLocalhostOnTheEnginesPort()
    {
        var draft = ConnectionDraft.New(Postgres);

        Assert.True(draft.IsNew);
        Assert.False(draft.IsFileEngine);
        Assert.Equal("localhost", draft.Host);
        Assert.Equal("5432", draft.Port);
        Assert.Empty(draft.Validate());
    }

    [Fact]
    public void EachBrokenFieldIsNamed()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.Host = " ";
        draft.Port = "70000";
        draft.UseSsh = true;
        draft.SshPort = "ssh";
        draft.SshAuth = SshAuthMethod.PrivateKey;
        draft.TlsMode = TlsMode.Require;
        draft.ClientCertificate = "client.pem";
        draft.Timeout = "soon";

        var errors = draft.Validate();

        Assert.Equal(
            [
                new FieldError(FormField.Host, FieldProblem.Required),
                new FieldError(FormField.Port, FieldProblem.OutOfRange),
                new FieldError(FormField.SshHost, FieldProblem.Required),
                new FieldError(FormField.SshPort, FieldProblem.NotANumber),
                new FieldError(FormField.SshKey, FieldProblem.Required),
                new FieldError(FormField.ClientKey, FieldProblem.Required),
                new FieldError(FormField.Timeout, FieldProblem.NotANumber),
            ],
            errors);
    }

    [Fact]
    public void AFileEngineNeedsAFullPath()
    {
        var draft = ConnectionDraft.New(Sqlite);
        var empty = draft.Validate();
        draft.Database = "app.sqlite";
        var relative = draft.Validate();
        draft.Database = AbsolutePath("app.sqlite");

        Assert.Equal([new FieldError(FormField.File, FieldProblem.Required)], empty);
        Assert.Equal([new FieldError(FormField.File, FieldProblem.NotAbsolute)], relative);
        Assert.Empty(draft.Validate());
        Assert.Equal("app", draft.ToConnection().Name);
    }

    [Fact]
    public void TheFormRoundTripsASavedConnection()
    {
        var saved = new SavedConnection(
            Guid.NewGuid(), "prod", "postgres", "db.example.com", 6543, "shop", "app",
            new TlsSettings(TlsMode.VerifyFull, CaFile: @"C:\ca.pem"),
            SafeMode.ConfirmWrites,
            Ssh: new SshSettings("bastion", 2222, "ops", [], SshAuthMethod.PrivateKey, @"C:\id_ed25519"),
            QueryTimeoutSeconds: 30,
            Color: "red",
            GroupId: Guid.NewGuid());

        var draft = ConnectionDraft.From(saved, Postgres);
        var back = draft.ToConnection();

        Assert.Equal(saved.Id, back.Id);
        Assert.Equal(saved with { Ssh = null }, back with { Ssh = null });
        Assert.Equal(saved.Ssh!.Host, back.Ssh!.Host);
        Assert.Equal(saved.Ssh.Port, back.Ssh.Port);
        Assert.Equal(saved.Ssh.KeyPath, back.Ssh.KeyPath);
        Assert.Equal(SshAuthMethod.PrivateKey, back.Ssh.Auth);
    }

    [Fact]
    public void StrictAndIntegratedAuthenticationSurviveEditing()
    {
        var engine = new DatabaseEngine("mssql", "SQL Server", DataModel.Relational, 1433, []);
        var saved = new SavedConnection(
            Guid.NewGuid(), "prod", "mssql", "127.0.0.1", 1433, "shop", "saved-user",
            new TlsSettings(TlsMode.Strict, CaFile: @"C:\ca.pem", ServerName: "db.example.com"),
            IntegratedAuth: true);

        var draft = ConnectionDraft.From(saved, engine);
        draft.Password = "hidden-password";
        draft.SshPassword = "ssh-password";
        draft.UseSsh = true;
        draft.SshAuth = SshAuthMethod.Password;
        draft.SshHost = "bastion";

        Assert.Equal(saved, draft.ToConnection() with { Ssh = null });
        Assert.Null(draft.Secrets().DatabasePassword);
        Assert.Equal("ssh-password", draft.Secrets().SshPassword);
    }

    [Fact]
    public void ReturningToPasswordAuthenticationUsesTheEnteredPassword()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.IntegratedAuth = true;
        draft.Password = "entered";
        Assert.Null(draft.Secrets().DatabasePassword);

        draft.IntegratedAuth = false;
        Assert.Equal("entered", draft.Secrets().DatabasePassword);
    }

    [Theory]
    [InlineData(TlsMode.VerifyFull, TlsMode.Require)]
    [InlineData(TlsMode.VerifyFull, TlsMode.Disable)]
    [InlineData(TlsMode.Strict, TlsMode.Require)]
    [InlineData(TlsMode.Strict, TlsMode.Disable)]
    public void LeavingCertificateVerificationOmitsInactiveFieldsAndSwitchingBackRestoresThem(TlsMode original, TlsMode mode)
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.TlsMode = original;
        draft.CaFile = AbsolutePath("ca.pem");
        draft.ServerName = "db.example.com";
        draft.ClientCertificate = AbsolutePath("client.pem");
        draft.ClientKey = AbsolutePath("client.key");
        var verified = draft.ToConnection().Tls;

        draft.TlsMode = mode;
        var inactive = draft.ToConnection().Tls;
        Assert.Null(inactive.CaFile);
        Assert.Null(inactive.ServerName);
        Assert.Equal(mode == TlsMode.Disable ? null : verified.ClientCertificate, inactive.ClientCertificate);
        Assert.Equal(mode == TlsMode.Disable ? null : verified.ClientKey, inactive.ClientKey);

        draft.TlsMode = original;
        Assert.Equal(verified, draft.ToConnection().Tls);
    }

    [Fact]
    public void AnInactiveClientIdentityDoesNotBlockValidation()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.ClientCertificate = AbsolutePath("client.pem");
        Assert.Empty(draft.Validate());
        Assert.Null(draft.ToConnection().Tls.ClientCertificate);

        draft.TlsMode = TlsMode.Require;
        Assert.Equal([new FieldError(FormField.ClientKey, FieldProblem.Required)], draft.Validate());
        draft.SupportsClientIdentity = false;
        Assert.Empty(draft.Validate());
        Assert.Null(draft.ToConnection().Tls.ClientCertificate);
    }

    [Fact]
    public void AnEmptyNameTakesOneFromTheTarget()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.Host = "db.example.com";
        draft.Database = "shop";

        Assert.Equal("shop@db.example.com", draft.ToConnection().Name);
    }

    [Fact]
    public void ANewConnectionStoresItsPasswordEvenEmptyAndAnEditKeepsTheStoredOne()
    {
        var fresh = ConnectionDraft.New(Postgres);
        var edited = ConnectionDraft.From(fresh.ToConnection() with { Id = Guid.NewGuid() }, Postgres);
        var retyped = ConnectionDraft.From(fresh.ToConnection() with { Id = Guid.NewGuid() }, Postgres);
        retyped.Password = "new";

        Assert.Equal(string.Empty, fresh.Secrets().DatabasePassword);
        Assert.Null(edited.Secrets().DatabasePassword);
        Assert.Equal("new", retyped.Secrets().DatabasePassword);
        Assert.Equal(ConnectionSecrets.None, ConnectionDraft.New(Sqlite).Secrets());
    }

    [Fact]
    public void AUrlFillsTheFieldsItNames()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.Name = "kept";

        draft.Apply(new ParsedConnectionUrl("postgres", "db.example.com", null, "app", "secret", "shop", TlsMode.Require), Postgres);

        Assert.Equal("kept", draft.Name);
        Assert.Equal("db.example.com", draft.Host);
        Assert.Equal("5432", draft.Port);
        Assert.Equal("app", draft.UserName);
        Assert.Equal("secret", draft.Password);
        Assert.Equal("shop", draft.Database);
        Assert.Equal(TlsMode.Require, draft.TlsMode);
    }
}
