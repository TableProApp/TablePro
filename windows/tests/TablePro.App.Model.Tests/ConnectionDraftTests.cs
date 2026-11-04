using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ConnectionDraftTests
{
    private static readonly DatabaseEngine Postgres = new("postgres", "PostgreSQL", DataModel.Relational, 5432, []);
    private static readonly DatabaseEngine Sqlite = new("sqlite", "SQLite", DataModel.Relational, null, ["sqlite", "db"]);

    private static string AbsolutePath(string name) =>
        Path.Combine(Path.GetPathRoot(Path.GetTempPath())!, "data", name);

    [Fact]
    public void EditingKeepsTheSshJumpRouteAndSavedKeyPassphrase()
    {
        var saved = new SavedConnection(
            Guid.NewGuid(), "Server", "postgres", "db", 5432, "app", "user", TlsSettings.Disabled,
            Ssh: new SshSettings("bastion", 22, "ops", ["jump1", "jump2"],
                SshAuthMethod.PrivateKey, @"C:\id_ed25519", KeyHasPassphrase: true));
        var draft = ConnectionDraft.From(saved, Postgres);
        draft.Name = "Renamed";

        var ssh = Assert.IsType<SshSettings>(draft.ToConnection().Ssh);

        Assert.Equal(saved.Ssh!.JumpHosts, ssh.JumpHosts);
        Assert.True(ssh.KeyHasPassphrase);
        draft.SshKeyPath = @"C:\another_key";
        Assert.False(draft.ToConnection().Ssh!.KeyHasPassphrase);
    }

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
