using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Storage.Connections;

namespace TablePro.Storage.Tests;

public sealed class ConnectionStoreTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public async Task SavedProfilesLoadBackWithEveryField()
    {
        var profile = SampleProfile();
        using (var store = new ConnectionStore(_temp.Paths))
        {
            await store.UpsertAsync(profile, Token);
        }

        using var reloaded = new ConnectionStore(_temp.Paths);
        await reloaded.LoadAsync(Token);

        var loaded = Assert.Single(reloaded.Connections);
        Assert.Equal(profile.Id, loaded.Id);
        Assert.Equal(profile.Name, loaded.Name);
        Assert.Equal(profile.Engine, loaded.Engine);
        Assert.Equal(profile.Host, loaded.Host);
        Assert.Equal(profile.Port, loaded.Port);
        Assert.Equal(profile.Database, loaded.Database);
        Assert.Equal(profile.Username, loaded.Username);
        Assert.Equal(profile.SslMode, loaded.SslMode);
        Assert.Equal(profile.SafeMode, loaded.SafeMode);
        Assert.Equal(profile.Color, loaded.Color);
        Assert.Equal(profile.ConnectTimeoutSeconds, loaded.ConnectTimeoutSeconds);
        Assert.Equal(profile.LastConnectedAt, loaded.LastConnectedAt);
        Assert.Equal(profile.Ssh, loaded.Ssh);
        Assert.Equal(profile.ExternalAccess, loaded.ExternalAccess);
        Assert.Equal(profile.AiPolicy, loaded.AiPolicy);
        Assert.Equal(profile.StartupCommands, loaded.StartupCommands);
        Assert.Equal(profile.AdditionalOptions, loaded.AdditionalOptions);
    }

    [Fact]
    public async Task FileUsesCamelCaseStringEnumsAndOmitsDerivedValues()
    {
        using var store = new ConnectionStore(_temp.Paths);
        await store.UpsertAsync(SampleProfile(), Token);

        var json = await File.ReadAllTextAsync(_temp.Paths.ConnectionsFile, Token);
        using var document = JsonDocument.Parse(json);
        var connection = document.RootElement.GetProperty("connections")[0];
        Assert.Equal("PostgreSql", connection.GetProperty("engine").GetString());
        Assert.Equal("Alert", connection.GetProperty("safeMode").GetString());
        Assert.False(connection.TryGetProperty("descriptor", out _));
        Assert.False(connection.TryGetProperty("subtitle", out _));
        Assert.False(connection.TryGetProperty("effectivePort", out _));
        Assert.False(connection.TryGetProperty("isReadOnly", out _));
        Assert.False(connection.TryGetProperty("password", out _));
    }

    [Fact]
    public async Task FieldsMissingFromTheFileTakeTheirDeclaredDefaults()
    {
        await File.WriteAllTextAsync(_temp.Paths.ConnectionsFile, """
            {
              "connections": [
                { "name": "Minimal", "engine": "MySql", "ssh": { "enabled": true, "host": "jump" } }
              ],
              "groups": [ { "name": "Loose" } ]
            }
            """, Token);
        using var store = new ConnectionStore(_temp.Paths);

        await store.LoadAsync(Token);

        var profile = Assert.Single(store.Connections);
        Assert.Equal("localhost", profile.Host);
        Assert.Equal(3306, profile.EffectivePort);
        Assert.Equal(15, profile.ConnectTimeoutSeconds);
        Assert.True(profile.SavePassword);
        Assert.Equal(SslMode.Preferred, profile.SslMode);
        Assert.Equal(ExternalAccessLevel.ReadOnly, profile.ExternalAccess);
        Assert.NotNull(profile.AdditionalOptions);
        Assert.NotEqual(Guid.Empty, profile.Id);
        Assert.Equal(22, profile.Ssh!.Port);
        Assert.Equal(SshAuthMethod.Agent, profile.Ssh.AuthMethod);
        Assert.NotEqual(Guid.Empty, Assert.Single(store.Groups).Id);
    }

    [Fact]
    public async Task WritesLeaveNoTemporaryFilesBehind()
    {
        using var store = new ConnectionStore(_temp.Paths);
        for (var i = 0; i < 20; i++)
        {
            await store.UpsertAsync(SampleProfile() with { Name = $"db {i}" }, Token);
        }

        Assert.Equal(20, store.Connections.Count);
        Assert.Empty(Directory.GetFiles(_temp.Path, "*.tmp"));
    }

    [Fact]
    public async Task ConcurrentUpsertsAllLand()
    {
        using var store = new ConnectionStore(_temp.Paths);
        await Task.WhenAll(Enumerable.Range(0, 25).Select(i => store.UpsertAsync(SampleProfile() with { Name = $"db {i}" }, Token)));

        using var reloaded = new ConnectionStore(_temp.Paths);
        await reloaded.LoadAsync(Token);
        Assert.Equal(25, reloaded.Connections.Count);
    }

    [Fact]
    public async Task CorruptFileIsMovedAsideAndTheStoreStartsEmpty()
    {
        await File.WriteAllTextAsync(_temp.Paths.ConnectionsFile, "{ not json", Token);
        using var store = new ConnectionStore(_temp.Paths);

        await store.LoadAsync(Token);

        Assert.Empty(store.Connections);
        Assert.Single(Directory.GetFiles(_temp.Path, "connections.json.corrupt-*"));
    }

    [Fact]
    public async Task ChangedFiresAfterEachSave()
    {
        using var store = new ConnectionStore(_temp.Paths);
        var count = 0;
        store.Changed += (_, _) => Interlocked.Increment(ref count);

        var profile = SampleProfile();
        await store.UpsertAsync(profile, Token);
        await store.MarkConnectedAsync(profile.Id, cancellationToken: Token);
        await store.DeleteAsync(profile.Id, Token);
        await store.DeleteAsync(profile.Id, Token);

        Assert.Equal(3, count);
    }

    [Fact]
    public async Task DuplicatePlacesACopyAfterTheOriginalWithANewId()
    {
        using var store = new ConnectionStore(_temp.Paths);
        var first = SampleProfile() with { Name = "Prod" };
        var second = SampleProfile() with { Name = "Staging" };
        await store.UpsertAsync(first, Token);
        await store.UpsertAsync(second, Token);

        var copy = await store.DuplicateAsync(first.Id, Token);
        var secondCopy = await store.DuplicateAsync(first.Id, Token);

        Assert.NotNull(copy);
        Assert.NotEqual(first.Id, copy.Id);
        Assert.Null(copy.LastConnectedAt);
        Assert.Equal("Prod copy", copy.Name);
        Assert.Equal("Prod copy 2", secondCopy!.Name);
        Assert.Equal(["Prod", "Prod copy 2", "Prod copy", "Staging"], store.Connections.Select(c => c.Name));
    }

    [Fact]
    public async Task MarkConnectedAndOrdering()
    {
        using var store = new ConnectionStore(_temp.Paths);
        var a = SampleProfile() with { Name = "b-alpha", LastConnectedAt = null };
        var b = SampleProfile() with { Name = "a-beta", LastConnectedAt = null };
        await store.UpsertAsync(a, Token);
        await store.UpsertAsync(b, Token);

        var when = new DateTimeOffset(2026, 10, 1, 8, 0, 0, TimeSpan.Zero);
        await store.MarkConnectedAsync(a.Id, when, Token);
        await store.MoveAsync(b.Id, 0, Token);

        Assert.Equal(when, store.Find(a.Id)!.LastConnectedAt);
        Assert.Equal(["a-beta", "b-alpha"], store.GetOrdered(ConnectionSortOrder.Manual).Select(c => c.Name));
        Assert.Equal(["b-alpha", "a-beta"], store.GetOrdered(ConnectionSortOrder.LastConnected).Select(c => c.Name));
        Assert.Equal(["a-beta", "b-alpha"], store.GetOrdered(ConnectionSortOrder.Name).Select(c => c.Name));
    }

    [Fact]
    public async Task DeletingAGroupMovesItsContentsToTheParent()
    {
        using var store = new ConnectionStore(_temp.Paths);
        var parent = new ConnectionGroup { Name = "Work" };
        var child = new ConnectionGroup { Name = "Billing", ParentId = parent.Id };
        var grandchild = new ConnectionGroup { Name = "Archive", ParentId = child.Id };
        await store.UpsertGroupAsync(parent, Token);
        await store.UpsertGroupAsync(child, Token);
        await store.UpsertGroupAsync(grandchild, Token);
        var profile = SampleProfile() with { Group = child.Key };
        await store.UpsertAsync(profile, Token);

        Assert.Equal(child, store.GroupOf(profile));
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.UpsertGroupAsync(parent with { ParentId = grandchild.Id }, Token));

        Assert.True(await store.DeleteGroupAsync(child.Id, Token));

        Assert.Equal(parent.Key, store.Find(profile.Id)!.Group);
        Assert.Equal(parent.Id, store.FindGroup(grandchild.Id)!.ParentId);
        Assert.Null(store.FindGroup(child.Id));
    }

    [Fact]
    public async Task ExportThenImportRecreatesConnectionsUnderNewIds()
    {
        var exportPath = _temp.File("export.json");
        var group = new ConnectionGroup { Name = "Production", Color = ConnectionColor.Red };
        var profile = SampleProfile() with { Group = group.Key };
        var sqlite = new ConnectionProfile { Name = "Local file", Engine = DatabaseEngine.Sqlite, FilePath = @"C:\data\app.db" };
        using (var source = new ConnectionStore(_temp.File("source.json")))
        {
            await source.UpsertGroupAsync(group, Token);
            await source.UpsertAsync(profile, Token);
            await source.UpsertAsync(sqlite, Token);
            await source.ExportAsync(exportPath, cancellationToken: Token);
        }

        var json = await File.ReadAllTextAsync(exportPath, Token);
        Assert.DoesNotContain("password", json, StringComparison.OrdinalIgnoreCase);
        using (var document = JsonDocument.Parse(json))
        {
            Assert.Equal(1, document.RootElement.GetProperty("formatVersion").GetInt32());
            Assert.Matches(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", document.RootElement.GetProperty("exportedAt").GetString());
            var first = document.RootElement.GetProperty("connections")[0];
            Assert.Equal("PostgreSQL", first.GetProperty("type").GetString());
            Assert.Equal("Production", first.GetProperty("groupName").GetString());
            Assert.Equal("Private Key", first.GetProperty("sshConfig").GetProperty("authMethod").GetString());
        }

        using var target = new ConnectionStore(_temp.File("target.json"));
        var result = await target.ImportAsync(exportPath, Token);

        Assert.Empty(result.Skipped);
        Assert.Equal(2, result.Imported.Count);
        var createdGroup = Assert.Single(result.CreatedGroups);
        Assert.Equal("Production", createdGroup.Name);
        Assert.Equal(ConnectionColor.Red, createdGroup.Color);

        var imported = target.Connections.Single(c => c.Name == profile.Name);
        Assert.NotEqual(profile.Id, imported.Id);
        Assert.Equal(createdGroup.Key, imported.Group);
        Assert.Equal(profile.Host, imported.Host);
        Assert.Equal(profile.Port, imported.Port);
        Assert.Equal(profile.Database, imported.Database);
        Assert.Equal(profile.SafeMode, imported.SafeMode);
        Assert.Equal(profile.SslMode, imported.SslMode);
        Assert.Equal(profile.AiPolicy, imported.AiPolicy);
        Assert.Equal(profile.Ssh, imported.Ssh);

        var importedFile = target.Connections.Single(c => c.Engine == DatabaseEngine.Sqlite);
        Assert.Equal(sqlite.FilePath, importedFile.FilePath);
    }

    [Fact]
    public async Task ImportReadsAMacExportAndSkipsWhatWindowsCannotOpen()
    {
        var path = _temp.File("mac.json");
        await File.WriteAllTextAsync(path, """
            {
              "appVersion" : "0.83.0",
              "connections" : [
                {
                  "name" : "Orders",
                  "host" : "sql.internal",
                  "port" : 1433,
                  "database" : "orders",
                  "username" : "app",
                  "type" : "SQL Server",
                  "groupName" : "Team",
                  "safeModeLevel" : "confirmWrites",
                  "aiPolicy" : "never",
                  "sslConfig" : { "mode" : "Verify CA" },
                  "additionalFields" : { "preConnectScript" : "rm -rf /", "applicationName" : "TablePro", "awsProfile" : "x" },
                  "sshConfig" : {
                    "enabled" : true, "host" : "bastion", "port" : 2222, "username" : "ops", "authMethod" : "SSH Agent",
                    "privateKeyPath" : "", "agentSocketPath" : "",
                    "jumpHosts" : [ { "host" : "edge", "port" : 22, "username" : "me", "authMethod" : "SSH Agent", "privateKeyPath" : "" } ]
                  }
                },
                { "name" : "Cache", "host" : "redis", "port" : 6379, "database" : "", "username" : "", "type" : "Redis" }
              ],
              "exportedAt" : "2026-10-01T10:00:00Z",
              "formatVersion" : 1,
              "groups" : [ { "name" : "Team", "color" : "Blue" } ]
            }
            """, Token);
        using var store = new ConnectionStore(_temp.Paths);
        var existing = new ConnectionGroup { Name = "team" };
        await store.UpsertGroupAsync(existing, Token);

        var result = await store.ImportAsync(path, Token);

        var skipped = Assert.Single(result.Skipped);
        Assert.Equal("Cache", skipped.Name);
        Assert.Empty(result.CreatedGroups);
        var orders = Assert.Single(result.Imported);
        Assert.Equal(DatabaseEngine.SqlServer, orders.Engine);
        Assert.Equal(existing.Key, orders.Group);
        Assert.Equal(SafeModeLevel.Alert, orders.SafeMode);
        Assert.Equal(AiPolicy.Never, orders.AiPolicy);
        Assert.Equal(SslMode.VerifyCa, orders.SslMode);
        Assert.Equal(new Dictionary<string, string> { ["applicationName"] = "TablePro" }, orders.AdditionalOptions);
        Assert.Equal("bastion", orders.Ssh!.Host);
        Assert.Equal(2222, orders.Ssh.Port);
        Assert.Equal(SshAuthMethod.Agent, orders.Ssh.AuthMethod);
        Assert.Equal("me@edge", orders.Ssh.JumpHosts);
    }

    [Fact]
    public async Task ImportRejectsANewerFormat()
    {
        var path = _temp.File("future.json");
        await File.WriteAllTextAsync(path, """{ "formatVersion": 2, "appVersion": "9", "exportedAt": "2026-10-01T10:00:00Z", "connections": [] }""", Token);
        using var store = new ConnectionStore(_temp.Paths);

        await Assert.ThrowsAsync<InvalidDataException>(() => store.ImportAsync(path, Token));
    }

    [Theory]
    [InlineData("bastion", null, "bastion", null)]
    [InlineData("me@bastion:2222", "me", "bastion", 2222)]
    [InlineData("[fe80::1]:2200", null, "fe80::1", 2200)]
    [InlineData("ops@[::1]", "ops", "::1", null)]
    public void JumpHostSpecsParse(string text, string? user, string host, int? port)
    {
        var spec = Assert.Single(JumpHostSpec.Parse(text));
        Assert.Equal(new JumpHostSpec(user, host, port), spec);
    }

    private static ConnectionProfile SampleProfile() => new()
    {
        Name = "Production",
        Engine = DatabaseEngine.PostgreSql,
        Host = "db.example.com",
        Port = 6432,
        Database = "app",
        Username = "reader",
        SslMode = SslMode.Required,
        SafeMode = SafeModeLevel.Alert,
        Color = ConnectionColor.Green,
        ConnectTimeoutSeconds = 20,
        LastConnectedAt = new DateTimeOffset(2026, 9, 30, 12, 34, 56, TimeSpan.FromHours(2)),
        Ssh = new SshTunnelSettings
        {
            Enabled = true,
            Host = "bastion.example.com",
            Port = 2222,
            Username = "ops",
            AuthMethod = SshAuthMethod.PrivateKey,
            PrivateKeyPath = @"C:\Users\me\.ssh\id_ed25519",
        },
        ExternalAccess = ExternalAccessLevel.ReadWrite,
        AiPolicy = AiPolicy.Allow,
        StartupCommands = "SET search_path TO app",
        AdditionalOptions = new Dictionary<string, string> { ["Application Name"] = "TablePro" },
    };
}
