using System.Text;
using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Storage.Connections;

namespace TablePro.Storage.Tests;

/// <summary>The macOS format 2 bundle, its encrypted envelope, and the new profile fields in connections.json.</summary>
public sealed class ConnectionBundleFormat2Tests : IDisposable
{
    private const string MacFormat2 = """
        {
          "appVersion" : "0.84.0",
          "connections" : [
            {
              "ref" : "c-orders", "name" : "Orders", "host" : "sql.internal", "port" : 1433, "database" : "orders",
              "username" : "", "type" : "SQL Server", "groupRef" : "g-eu", "credentialProfileRef" : "p-app",
              "additionalFields" : { "mssqlAuthMethod" : "entra", "entraTenantId" : "contoso.onmicrosoft.com", "entraClientId" : "abc", "mssqlSchema" : "dbo" },
              "tagNames" : [ "prod" ]
            },
            {
              "ref" : "c-k8s", "name" : "Cluster", "host" : "postgres.default.svc", "port" : 5432, "database" : "app",
              "username" : "app", "type" : "PostgreSQL",
              "tunnelCommand" : { "method" : "kubectl", "kubernetesResource" : "service/postgres", "kubernetesNamespace" : "prod" }
            },
            { "ref" : "c-fire", "name" : "Firestore", "host" : "", "port" : 0, "database" : "", "username" : "", "type" : "Firestore" }
          ],
          "credentialProfiles" : [ { "ref" : "p-app", "name" : "App login", "username" : "svc_orders", "passwordMode" : "stored" } ],
          "exportedAt" : "2026-10-01T10:00:00Z",
          "formatVersion" : 2,
          "groups" : [
            { "ref" : "g-prod", "name" : "Production", "color" : "Red" },
            { "ref" : "g-eu", "name" : "Europe", "parentRef" : "g-prod" }
          ],
          "queryFolders" : [ { "ref" : "f-1", "name" : "Reports", "connectionRef" : "c-orders" } ],
          "savedQueries" : [ { "ref" : "q-1", "name" : "Open orders", "sql" : "SELECT 1", "keyword" : "oo", "folderRef" : "f-1", "connectionRef" : "c-orders" } ],
          "tags" : [ { "name" : "prod", "color" : "Red" } ]
        }
        """;

    private readonly TempDirectory _temp = new();

    private static CancellationToken Token => TestContext.Current.CancellationToken;

    public void Dispose() => _temp.Dispose();

    [Fact]
    public async Task ImportsAMacFormat2BundleWithNestedGroupsAndSavedQueries()
    {
        var path = _temp.File("mac2.tablepro");
        await File.WriteAllTextAsync(path, MacFormat2, Token);
        using var store = new ConnectionStore(_temp.Paths);
        var existing = new ConnectionGroup { Name = "production" };
        await store.UpsertGroupAsync(existing, Token);

        var result = await store.ImportAsync(path, Token);

        Assert.Equal("Firestore", Assert.Single(result.Skipped).Name);
        Assert.Equal(2, result.Imported.Count);

        // "Production" joins the existing top-level group; "Europe" is created inside it.
        var europe = Assert.Single(result.CreatedGroups);
        Assert.Equal("Europe", europe.Name);
        Assert.Equal(existing.Id, europe.ParentId);

        var orders = result.Imported.Single(p => p.Name == "Orders");
        Assert.Equal(europe.Key, orders.Group);
        Assert.Equal("svc_orders", orders.Username);
        Assert.Equal(SignInMethod.EntraId, orders.Auth!.Method);
        Assert.Equal(EntraAuthMode.DeviceCode, orders.Auth.EntraMode);
        Assert.Equal("contoso.onmicrosoft.com", orders.Auth.EntraTenantId);
        Assert.Equal("abc", orders.Auth.EntraClientId);
        Assert.Empty(orders.AdditionalOptions);

        var cluster = result.Imported.Single(p => p.Name == "Cluster");
        Assert.NotNull(cluster.TunnelCommand);
        Assert.False(cluster.TunnelCommand.Enabled);
        Assert.Equal(TunnelCommandMethod.Kubectl, cluster.TunnelCommand.Method);
        Assert.Equal("service/postgres", cluster.TunnelCommand.KubernetesResource);
        Assert.Equal(["Cluster"], result.TunnelCommandsToReview);

        var query = Assert.Single(result.SavedQueries);
        Assert.Equal("Open orders", query.Name);
        Assert.Equal(["Reports"], query.FolderPath);
        Assert.Equal(orders.Id, query.ConnectionId);
        Assert.Equal("oo", query.Keyword);
    }

    [Theory]
    [InlineData("""{ "ref" : "", "name" : "x", "host" : "h", "port" : 1, "database" : "", "username" : "", "type" : "MySQL" }""", "empty reference")]
    [InlineData("""{ "ref" : "c", "name" : "x", "host" : "h", "port" : 1, "database" : "", "username" : "", "type" : "MySQL", "groupRef" : "missing" }""", "not in the file")]
    public async Task RefusesAFormat2BundleWithBrokenRefs(string connection, string expected)
    {
        var path = _temp.File("broken.json");
        await File.WriteAllTextAsync(path, $$"""{ "formatVersion" : 2, "appVersion" : "1", "exportedAt" : "2026-10-01T10:00:00Z", "connections" : [ {{connection}} ] }""", Token);
        using var store = new ConnectionStore(_temp.Paths);

        var error = await Assert.ThrowsAsync<InvalidDataException>(() => store.ImportAsync(path, Token));

        Assert.Contains(expected, error.Message, StringComparison.Ordinal);
        Assert.Empty(store.Connections);
    }

    [Fact]
    public async Task RefusesAGroupCycle()
    {
        var path = _temp.File("cycle.json");
        await File.WriteAllTextAsync(path, """
            { "formatVersion" : 2, "appVersion" : "1", "exportedAt" : "2026-10-01T10:00:00Z", "connections" : [],
              "groups" : [ { "ref" : "a", "name" : "A", "parentRef" : "b" }, { "ref" : "b", "name" : "B", "parentRef" : "a" } ] }
            """, Token);
        using var store = new ConnectionStore(_temp.Paths);

        var error = await Assert.ThrowsAsync<InvalidDataException>(() => store.ImportAsync(path, Token));

        Assert.Contains("inside itself", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task NestedGroupsExportAsFormat2AndComeBackNested()
    {
        var parent = new ConnectionGroup { Name = "Production", Color = ConnectionColor.Red };
        var child = new ConnectionGroup { Name = "Europe", ParentId = parent.Id };
        var profile = new ConnectionProfile { Name = "Orders", Engine = DatabaseEngine.MySql, Host = "db", Group = child.Key };
        var exportPath = _temp.File("nested.json");
        using (var source = new ConnectionStore(_temp.File("source.json")))
        {
            await source.UpsertGroupAsync(parent, Token);
            await source.UpsertGroupAsync(child, Token);
            await source.UpsertAsync(profile, Token);
            await source.ExportAsync(exportPath, cancellationToken: Token);
        }

        using (var document = JsonDocument.Parse(await File.ReadAllTextAsync(exportPath, Token)))
        {
            var root = document.RootElement;
            Assert.Equal(2, root.GetProperty("formatVersion").GetInt32());
            var connection = root.GetProperty("connections")[0];
            var groups = root.GetProperty("groups");
            Assert.Equal(2, groups.GetArrayLength());
            Assert.Equal(groups[1].GetProperty("ref").GetString(), connection.GetProperty("groupRef").GetString());
            Assert.Equal(groups[0].GetProperty("ref").GetString(), groups[1].GetProperty("parentRef").GetString());
            Assert.False(connection.TryGetProperty("groupName", out _));
        }

        using var target = new ConnectionStore(_temp.File("target.json"));
        var result = await target.ImportAsync(exportPath, Token);

        Assert.Equal(2, result.CreatedGroups.Count);
        var importedParent = result.CreatedGroups.Single(g => g.Name == "Production");
        var importedChild = result.CreatedGroups.Single(g => g.Name == "Europe");
        Assert.Equal(importedParent.Id, importedChild.ParentId);
        Assert.Equal(ConnectionColor.Red, importedParent.Color);
        Assert.Equal(importedChild.Key, Assert.Single(result.Imported).Group);
    }

    [Fact]
    public async Task EncryptedExportCarriesPasswordsAndNeedsThePassphrase()
    {
        var profile = new ConnectionProfile
        {
            Name = "Orders",
            Engine = DatabaseEngine.PostgreSql,
            Host = "db",
            Ssh = new SshTunnelSettings { Enabled = true, Host = "bastion", AuthMethod = SshAuthMethod.Password },
        };
        var exportPath = _temp.File("sealed.tablepro");
        using (var source = new ConnectionStore(_temp.File("source.json")))
        {
            await source.UpsertAsync(profile, Token);
            await source.ExportAsync(exportPath, new ConnectionExportOptions
            {
                Passphrase = "correct horse",
                Secrets = _ => new ConnectionSecrets { Password = "db-pass", SshSecret = "ssh-pass" },
            }, Token);
        }

        var bytes = await File.ReadAllBytesAsync(exportPath, Token);
        Assert.Equal("TPRO"u8.ToArray(), bytes[..4]);
        Assert.Equal(1, bytes[4]);
        Assert.DoesNotContain("db-pass", Encoding.UTF8.GetString(bytes), StringComparison.Ordinal);
        Assert.True(ConnectionStore.IsEncryptedExport(exportPath));

        using var target = new ConnectionStore(_temp.File("target.json"));
        var missing = await Assert.ThrowsAsync<ConnectionExportPassphraseException>(() => target.ImportAsync(exportPath, Token));
        Assert.True(missing.PassphraseMissing);
        var wrong = await Assert.ThrowsAsync<ConnectionExportPassphraseException>(() => target.ImportAsync(exportPath, "wrong", Token));
        Assert.False(wrong.PassphraseMissing);

        var result = await target.ImportAsync(exportPath, "correct horse", Token);

        var imported = Assert.Single(result.Imported);
        var secrets = result.Secrets[imported.Id];
        Assert.Equal("db-pass", secrets.Password);
        Assert.Equal("ssh-pass", secrets.SshSecret);
    }

    [Fact]
    public void EnvelopeMatchesTheMacLayoutAndRoundTrips()
    {
        var plaintext = "{\"formatVersion\":1}"u8.ToArray();

        var sealedBytes = ConnectionExportCrypto.Encrypt(plaintext, "pass");

        // magic + version + 32-byte salt + 12-byte nonce + ciphertext + 16-byte tag
        Assert.Equal(4 + 1 + 32 + 12 + plaintext.Length + 16, sealedBytes.Length);
        Assert.Equal(plaintext, ConnectionExportCrypto.Decrypt(sealedBytes, "pass"));
        Assert.Throws<ConnectionExportPassphraseException>(() => ConnectionExportCrypto.Decrypt(sealedBytes, "Pass"));
    }

    [Fact]
    public void RefusesAnEnvelopeFromANewerEncryptionVersion()
    {
        var sealedBytes = ConnectionExportCrypto.Encrypt("{}"u8, "pass");
        sealedBytes[4] = 2;

        var error = Assert.Throws<InvalidDataException>(() => ConnectionExportCrypto.Decrypt(sealedBytes, "pass"));

        Assert.Contains("version 2", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PlainExportRefusesSecrets()
    {
        using var store = new ConnectionStore(_temp.Paths);

        await Assert.ThrowsAsync<InvalidOperationException>(() => store.ExportAsync(_temp.File("x.json"), new ConnectionExportOptions
        {
            Secrets = _ => new ConnectionSecrets { Password = "p" },
        }, Token));
    }

    [Fact]
    public async Task PlainFileCredentialsAreIgnored()
    {
        var path = _temp.File("plain-creds.json");
        await File.WriteAllTextAsync(path, """
            { "formatVersion" : 1, "appVersion" : "1", "exportedAt" : "2026-10-01T10:00:00Z",
              "connections" : [ { "name" : "A", "host" : "h", "port" : 5432, "database" : "", "username" : "u", "type" : "PostgreSQL" } ],
              "credentials" : { "0" : { "password" : "leaked" } } }
            """, Token);
        using var store = new ConnectionStore(_temp.Paths);

        var result = await store.ImportAsync(path, Token);

        Assert.Single(result.Imported);
        Assert.Empty(result.Secrets);
    }

    [Fact]
    public async Task SqlServerSignInExportsInTheMacFieldNames()
    {
        var profile = new ConnectionProfile
        {
            Name = "Azure",
            Engine = DatabaseEngine.SqlServer,
            Host = "x.database.windows.net",
            Auth = new ConnectionAuthSettings { Method = SignInMethod.EntraId, EntraTenantId = "t", EntraClientId = "c" },
        };
        var path = _temp.File("entra.json");
        using (var store = new ConnectionStore(_temp.Paths))
        {
            await store.UpsertAsync(profile, Token);
            await store.ExportAsync(path, cancellationToken: Token);
        }

        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path, Token));
        var fields = document.RootElement.GetProperty("connections")[0].GetProperty("additionalFields");
        Assert.Equal("entra", fields.GetProperty("mssqlAuthMethod").GetString());
        Assert.Equal("t", fields.GetProperty("entraTenantId").GetString());
        Assert.Equal("c", fields.GetProperty("entraClientId").GetString());
    }

    [Fact]
    public async Task EnabledTunnelCommandExportsAndOthersStayHome()
    {
        var profile = new ConnectionProfile
        {
            Name = "K8s",
            Engine = DatabaseEngine.PostgreSql,
            TunnelCommand = new TunnelCommandSettings { Enabled = true, Method = TunnelCommandMethod.Custom, Command = "kubectl port-forward svc/pg {port}:5432" },
            Proxy = new ProxySettings { Enabled = false, Host = "proxy" },
        };
        var path = _temp.File("cmd.json");
        using (var store = new ConnectionStore(_temp.Paths))
        {
            await store.UpsertAsync(profile, Token);
            await store.ExportAsync(path, cancellationToken: Token);
        }

        using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path, Token));
        var command = document.RootElement.GetProperty("connections")[0].GetProperty("tunnelCommand");
        Assert.Equal("custom", command.GetProperty("method").GetString());
        Assert.Equal("kubectl port-forward svc/pg {port}:5432", command.GetProperty("command").GetString());
    }

    [Fact]
    public async Task NewTransportAndSignInFieldsSurviveSaving()
    {
        var profile = new ConnectionProfile
        {
            Name = "Everything",
            Engine = DatabaseEngine.PostgreSql,
            Proxy = new ProxySettings { Enabled = true, Protocol = ProxyProtocol.HttpConnect, Host = "proxy", Port = 3128, Username = "me" },
            CloudSqlProxy = new CloudSqlProxySettings { InstanceConnectionName = "p:r:i", UseIamAuth = true, LocalPort = 6543 },
            CloudflareTunnel = new CloudflareTunnelSettings { AccessHostname = "db.example.com", AuthMethod = CloudflareAuthMethod.ServiceToken },
            TunnelCommand = new TunnelCommandSettings { Method = TunnelCommandMethod.AwsSsm, AwsTarget = "i-1" },
            Auth = new ConnectionAuthSettings { Method = SignInMethod.AwsIamProfile, AwsProfileName = "prod", GssEncryption = GssEncryptionMode.Require },
        };
        using (var store = new ConnectionStore(_temp.Paths))
        {
            await store.UpsertAsync(profile, Token);
        }

        using var reloaded = new ConnectionStore(_temp.Paths);
        await reloaded.LoadAsync(Token);

        var loaded = Assert.Single(reloaded.Connections);
        Assert.Equal(profile.Proxy, loaded.Proxy);
        Assert.Equal(profile.CloudSqlProxy, loaded.CloudSqlProxy);
        Assert.Equal(profile.CloudflareTunnel, loaded.CloudflareTunnel);
        Assert.Equal(profile.TunnelCommand, loaded.TunnelCommand);
        Assert.Equal(profile.Auth, loaded.Auth);
    }

    [Fact]
    public async Task OlderFilesLoadWithoutTheNewFieldsAndPartialObjectsGetTheirDefaults()
    {
        await File.WriteAllTextAsync(_temp.Paths.ConnectionsFile, """
            { "version" : 1, "connections" : [
              { "id" : "6f1c3a52-6a64-4c35-9f5e-0b8f4f2b7d11", "name" : "Old", "engine" : "PostgreSql", "host" : "db" },
              { "id" : "7f1c3a52-6a64-4c35-9f5e-0b8f4f2b7d11", "name" : "Partial", "engine" : "MySql", "proxy" : { "enabled" : true, "host" : "p" }, "auth" : { "method" : "Kerberos" } }
            ] }
            """, Token);
        using var store = new ConnectionStore(_temp.Paths);

        await store.LoadAsync(Token);

        var old = store.Connections.Single(c => c.Name == "Old");
        Assert.Null(old.Proxy);
        Assert.Null(old.Auth);
        Assert.Equal(ConnectionTransport.Direct, old.ActiveTransport());

        var partial = store.Connections.Single(c => c.Name == "Partial");
        Assert.Equal(1080, partial.Proxy!.Port);
        Assert.Equal(ProxyProtocol.Socks5, partial.Proxy.Protocol);
        Assert.Equal(GssEncryptionMode.Prefer, partial.Auth!.GssEncryption);
    }
}
