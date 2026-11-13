using TablePro.Interop;

namespace TablePro.App.Model.Tests;

public sealed class ConnectionDraftTests
{
    private static readonly DatabaseEngine Postgres = new("postgres", "PostgreSQL", DataModel.Relational, 5432, [])
    {
        SupportsClientIdentity = true,
        SupportedTlsModes = [TlsMode.Disable, TlsMode.Prefer, TlsMode.Require, TlsMode.VerifyFull],
        DefaultTlsMode = TlsMode.Prefer,
        ServerNameOverride = ServerNameOverride.AnyRoute,
    };
    private static readonly DatabaseEngine MySql = new("mysql", "MySQL", DataModel.Relational, 3306, [])
    {
        SupportedTlsModes = [TlsMode.Disable, TlsMode.Prefer, TlsMode.Require, TlsMode.VerifyFull],
        DefaultTlsMode = TlsMode.Prefer,
        ServerNameOverride = ServerNameOverride.SshForwardOnly,
    };
    private static readonly DatabaseEngine ClickHouse = new("clickhouse", "ClickHouse", DataModel.Relational, 8123, [])
    {
        SupportedTlsModes = [TlsMode.Disable, TlsMode.Require, TlsMode.VerifyFull],
        DefaultTlsMode = TlsMode.Disable,
        TlsPorts = [443, 8443],
    };
    private static readonly DatabaseEngine Sqlite = new("sqlite", "SQLite", DataModel.Relational, null, ["sqlite", "db"]);

    private static string AbsolutePath(string name) =>
        Path.Combine(Path.GetPathRoot(Path.GetTempPath())!, "data", name);

    [Fact]
    public void ARenameLeavesAConnectUnderWayAndAnythingItReadsStartsItOver()
    {
        var before = new SavedConnection(
            Guid.NewGuid(), "shop", "postgres", "db.example.com", 5432, "shop", "app", TlsSettings.Disabled,
            Ssh: new SshSettings("bastion", 22, "me", ["jump"], SshAuthMethod.Agent));
        var renamed = before with
        {
            Name = "shop (prod)",
            Color = "red",
            GroupId = Guid.NewGuid(),
            LastOpened = DateTimeOffset.UnixEpoch,
            Tags = [Guid.NewGuid()],
            Ssh = before.Ssh! with { JumpHosts = ["jump"] },
            MaskingRules = [new MaskingRule(null, "*.email", MaskTarget.Column, MaskStyle.Email)],
        };

        Assert.False(ConnectionDraft.ChangesConnect(before, renamed));
        Assert.True(ConnectionDraft.ChangesConnect(before, before with { SafeMode = SafeMode.ReadOnly }));
        Assert.True(ConnectionDraft.ChangesConnect(before, before with { Host = "db2.example.com" }));
        Assert.True(ConnectionDraft.ChangesConnect(before, before with { Tls = new TlsSettings(TlsMode.Require) }));
        Assert.True(ConnectionDraft.ChangesConnect(before, before with { QueryTimeoutSeconds = 30 }));
        var otherJump = before with { Ssh = before.Ssh! with { JumpHosts = ["other"] } };
        Assert.True(ConnectionDraft.ChangesConnect(before, otherJump));
        Assert.True(ConnectionDraft.ChangesConnect(before, before with { Ssh = null }));
    }

    [Fact]
    public void MaskingRulesSaveInOrderTrimmedWithTheirIdsAndABlankPatternDropped()
    {
        var known = Guid.NewGuid();
        var saved = new SavedConnection(
            Guid.NewGuid(), "app", "sqlite", string.Empty, 0, AbsolutePath("app.sqlite"), string.Empty, TlsSettings.Disabled)
        {
            MaskingRules =
            [
                new MaskingRule(known, "users.email", MaskTarget.Column, MaskStyle.Email),
                new MaskingRule(Guid.NewGuid(), "uuid", MaskTarget.Type, MaskStyle.Hash),
            ],
        };
        var draft = ConnectionDraft.From(saved, Sqlite);

        draft.MaskingRules.RemoveAt(1);
        draft.MaskingRules.Add(new MaskingRuleDraft { Pattern = "  *.ssn \n", Style = MaskStyle.LastFour });
        draft.MaskingRules.Add(new MaskingRuleDraft { Pattern = "   " });
        var rules = draft.ToConnection().MaskingRules;

        Assert.Equal(
            [
                new MaskingRule(known, "users.email", MaskTarget.Column, MaskStyle.Email),
                new MaskingRule(null, "*.ssn", MaskTarget.Column, MaskStyle.LastFour),
            ],
            rules);
        Assert.Equal(MaskTarget.Column, new MaskingRuleDraft().Target);
        Assert.Equal(MaskStyle.Full, new MaskingRuleDraft().Style);
    }

    [Fact]
    public void ANetworkConnectionSavesItsMaskingRulesToo()
    {
        var draft = ConnectionDraft.New(Postgres);
        draft.MaskingRules.Add(new MaskingRuleDraft { Pattern = "*.email", Style = MaskStyle.Email });

        var rule = Assert.Single(draft.ToConnection().MaskingRules);

        Assert.Equal(new MaskingRule(null, "*.email", MaskTarget.Column, MaskStyle.Email), rule);
    }

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
        var engine = new DatabaseEngine("mssql", "SQL Server", DataModel.Relational, 1433, [])
        {
            ServerNameOverride = ServerNameOverride.AnyRoute,
        };
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
        draft.TlsMode = TlsMode.Disable;
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
    public void ANewConnectionStartsOnTheEnginesTlsDefault()
    {
        Assert.Equal(TlsMode.Prefer, ConnectionDraft.New(Postgres).TlsMode);
        Assert.Equal(TlsMode.Disable, ConnectionDraft.New(ClickHouse).TlsMode);
        Assert.False(ConnectionDraft.New(Postgres).TlsModeChosen);
    }

    [Fact]
    public void TheModeFollowsATlsPortUntilTheUserPicksOne()
    {
        var draft = ConnectionDraft.New(ClickHouse);

        draft.Port = "8443";
        draft.FollowTlsDefault(ClickHouse);
        Assert.Equal(TlsMode.VerifyFull, draft.TlsMode);

        draft.Port = "8123";
        draft.FollowTlsDefault(ClickHouse);
        Assert.Equal(TlsMode.Disable, draft.TlsMode);

        draft.TlsMode = TlsMode.Require;
        draft.TlsModeChosen = true;
        draft.Port = "8443";
        draft.FollowTlsDefault(ClickHouse);
        Assert.Equal(TlsMode.Require, draft.TlsMode);
    }

    [Fact]
    public void ASavedModeStaysWhenThePortMoves()
    {
        var saved = new SavedConnection(
            Guid.NewGuid(), "Cloud", "clickhouse", "abc.clickhouse.cloud", 8443, "", "default",
            new TlsSettings(TlsMode.VerifyFull));
        var draft = ConnectionDraft.From(saved, ClickHouse);

        draft.Port = "8444";
        draft.FollowTlsDefault(ClickHouse);

        Assert.Equal(TlsMode.VerifyFull, draft.TlsMode);
    }

    [Fact]
    public void AUrlThatNamesNoModeStartsOnTheDefaultForItsPort()
    {
        var draft = ConnectionDraft.New(ClickHouse);

        draft.Apply(new ParsedConnectionUrl("clickhouse", "abc.clickhouse.cloud", 8443, "default", null, "", null), ClickHouse);

        Assert.Equal(TlsMode.VerifyFull, draft.TlsMode);
    }

    [Fact]
    public void AServerNameIsKeptOnlyWhereTheEngineCanCheckIt()
    {
        var draft = ConnectionDraft.New(MySql);
        draft.TlsMode = TlsMode.VerifyFull;
        draft.ServerName = "db.internal";

        Assert.False(draft.ShowsServerName);
        Assert.Null(draft.ToConnection().Tls.ServerName);

        draft.UseSsh = true;
        draft.SshHost = "bastion";
        Assert.True(draft.ShowsServerName);
        Assert.Equal("db.internal", draft.ToConnection().Tls.ServerName);
    }

    [Fact]
    public void AUrlModeTheEngineLacksLeavesItsDefault()
    {
        var draft = ConnectionDraft.New(ClickHouse);

        draft.Apply(new ParsedConnectionUrl("clickhouse", "db.example.com", 8123, "default", null, "", TlsMode.Prefer), ClickHouse);

        Assert.Equal(TlsMode.Disable, draft.TlsMode);
        Assert.False(draft.TlsModeChosen);
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

    [Fact]
    public void AUrlCarriesItsCertificateSettings()
    {
        var draft = ConnectionDraft.New(Postgres);

        draft.Apply(
            new ParsedConnectionUrl("postgres", "db.example.com", null, "app", null, "shop", TlsMode.VerifyFull, CaFile: @"C:\certs\rds.pem", ServerName: "db.internal"),
            Postgres);

        Assert.Equal(TlsMode.VerifyFull, draft.TlsMode);
        Assert.Equal(@"C:\certs\rds.pem", draft.CaFile);
        Assert.Equal("db.internal", draft.ServerName);
        Assert.Equal(string.Empty, draft.ClientCertificate);
    }
}
