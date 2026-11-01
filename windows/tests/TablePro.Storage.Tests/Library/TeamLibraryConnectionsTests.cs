using System.Text.Json.Nodes;
using TablePro.Core.Connections;
using TablePro.Storage.Library.Team;

namespace TablePro.Storage.Tests.Library;

public sealed class TeamLibraryConnectionsTests
{
    private static TeamLibraryConnection Connection(string id, string payload) =>
        new(id, null, JsonNode.Parse(payload)!.AsObject(), "owner@example.com", "2026-07-08T00:00:00Z");

    [Fact]
    public void ATeamConnectionGetsTheSameStableIdTheMacAppGivesIt()
    {
        // SHA-256 of "00000000-0000-0000-0000-000000000000|01ABC", stamped as a version 5 UUID, as LinkedFolderWatcher does.
        Assert.Equal(Guid.Parse("9de8aa7d-8b9e-5446-9024-9f76ce100157"), TeamLibraryConnections.StableId(Guid.Empty, "01ABC"));
    }

    [Fact]
    public void APayloadOpensAsAnUnsavedProfileThatAsksForItsPassword()
    {
        var connection = Connection("01ABC", """{"name":"Prod","host":"db.example.com","port":5433,"database":"app","username":"deploy","type":"PostgreSQL","groupName":"Ops","sslConfig":{"mode":"Required"}}""");

        var profile = TeamLibraryConnections.ToProfile(connection)!;

        Assert.Equal(TeamLibraryConnections.StableId(Guid.Empty, "01ABC"), profile.Id);
        Assert.Equal("Prod", profile.Name);
        Assert.Equal(DatabaseEngine.PostgreSql, profile.Engine);
        Assert.Equal("db.example.com", profile.Host);
        Assert.Equal(5433, profile.Port);
        Assert.Equal("deploy", profile.Username);
        Assert.Null(profile.Group);
        Assert.False(profile.SavePassword);
    }

    [Fact]
    public void ImportRulesApplyAndAnExtensionListIsKeptForTheConnectPrompt()
    {
        var connection = Connection("02", """{"name":"Local","host":"","port":0,"database":"C:\\data\\app.db","username":"","type":"SQLite","additionalFields":{"preConnectScript":"calc.exe","sqliteExtensions":"[{\"path\":\"C:\\\\Tools\\\\vec0.dll\"}]"}}""");

        var profile = TeamLibraryConnections.ToProfile(connection)!;

        Assert.Equal(@"C:\data\app.db", profile.FilePath);
        Assert.DoesNotContain(profile.AdditionalOptions.Keys, k => k.Equals("preConnectScript", StringComparison.OrdinalIgnoreCase));
        Assert.Equal(@"C:\Tools\vec0.dll", Assert.Single(LoadableExtensionList.Declared(profile)).Path);
    }

    [Fact]
    public void ConnectionsThisBuildCannotOpenAreLeftOutAndRepeatedIdsListOnce()
    {
        var library = TeamLibraryPullResponse.Empty with
        {
            Connections =
            [
                Connection("a", """{"name":"One","host":"h","port":5432,"database":"","username":"u","type":"PostgreSQL"}"""),
                Connection("b", """{"name":"Unknown","host":"h","port":1,"database":"","username":"u","type":"NoSuchEngine"}"""),
                Connection("c", """{"name":3}"""),
                Connection("a", """{"name":"One again","host":"h","port":5432,"database":"","username":"u","type":"PostgreSQL"}"""),
            ],
        };

        var connections = TeamLibraryConnections.From(library);

        Assert.Equal("One", Assert.Single(connections).Profile.Name);
    }

    [Fact]
    public void APublishedPayloadIsTheMacExportFormatWithoutGroupsOrPasswords()
    {
        var profile = new ConnectionProfile
        {
            Name = "Prod",
            Engine = DatabaseEngine.MySql,
            Host = "db",
            Port = 3307,
            Database = "app",
            Username = "deploy",
            Group = "ops",
        };

        var payload = TeamLibraryConnections.Payload(profile);

        Assert.Equal("Prod", payload["name"]!.GetValue<string>());
        Assert.Equal("MySQL", payload["type"]!.GetValue<string>());
        Assert.Equal(3307, payload["port"]!.GetValue<int>());
        Assert.False(payload.ContainsKey("groupName"));
        Assert.False(payload.ContainsKey("password"));
        var reopened = TeamLibraryConnections.ToProfile(Connection("x", payload.ToJsonString()))!;
        Assert.Equal(("db", 3307, "app"), (reopened.Host, reopened.Port, reopened.Database));
    }
}
