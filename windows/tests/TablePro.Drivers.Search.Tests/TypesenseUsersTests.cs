using System.Text.Json;
using TablePro.Core.Connections;
using TablePro.Core.Principals;
using TablePro.Core.Results;
using TablePro.Drivers.Typesense;

namespace TablePro.Drivers.Search.Tests;

/// <summary>API keys as principals: listed with their grants, created and deleted, and never changed.</summary>
public sealed class TypesenseUsersTests
{
    private const string Keys = """
        {"keys":[
          {"id":3,"description":"Search only","actions":["documents:search"],"collections":["books","films"],"value_prefix":"abcd"},
          {"id":7,"description":"","actions":["*"],"collections":["*"]}
        ]}
        """;

    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static FakeHttp Node() =>
        new FakeHttp()
            .On("GET", "/debug", """{"state":1,"version":"27.1"}""")
            .On("GET", "/keys", Keys)
            .On("GET", "/collections", """[{"name":"films","fields":[]},{"name":"books","fields":[]}]""");

    private static Task<TypesenseSession> ConnectAsync(FakeHttp http) =>
        TypesenseSession.ConnectAsync(Profiles.Request(DatabaseEngine.Typesense, password: "xyz"), http, None);

    [Fact]
    public async Task KeysAreListedByDescriptionAndId()
    {
        await using var session = await ConnectAsync(Node());

        var snapshot = await session.LoadPrincipalsAsync(None);

        Assert.Equal(["Search only (#3)", "#7"], snapshot.Principals.Select(p => p.Ref.Name));
        Assert.All(snapshot.Principals, p => Assert.False(p.IsRole));
        Assert.Equal([TypesenseUserKeys.DatabaseName], snapshot.Databases);
        Assert.True(session.Features!.Immutable);
        Assert.False(session.Features.Passwords);
    }

    [Fact]
    public async Task AKeysGrantsAreItsActionsOnItsCollections()
    {
        await using var session = await ConnectAsync(Node());

        var named = await session.LoadGrantsAsync(new PrincipalRef("Search only (#3)"), None);
        var everything = await session.LoadGrantsAsync(new PrincipalRef("#7"), None);

        Assert.Equal(
            [
                new PrincipalGrant("documents:search", PrivilegeScope.ForTable(TypesenseUserKeys.DatabaseName, null, "books")),
                new PrincipalGrant("documents:search", PrivilegeScope.ForTable(TypesenseUserKeys.DatabaseName, null, "films")),
            ],
            named);
        Assert.Equal([new PrincipalGrant("*", PrivilegeScope.Server)], everything);
        Assert.Empty(await session.LoadGrantsAsync(new PrincipalRef("#99"), None));
    }

    [Fact]
    public async Task CollectionsAreTheDatabasesChildren()
    {
        await using var session = await ConnectAsync(Node());

        var children = await session.LoadChildScopesAsync(PrivilegeScope.ForDatabase(TypesenseUserKeys.DatabaseName), None);

        Assert.Equal(["books", "films"], children.Select(s => s.Table));
        Assert.Empty(await session.LoadChildScopesAsync(PrivilegeScope.Server, None));
    }

    [Fact]
    public async Task CreateAndDropAreRequestsAndEditsAreRefused()
    {
        await using var session = await ConnectAsync(Node());

        var statements = session.BuildStatements(
            [
                new DropPrincipal(new PrincipalRef("Search only (#3)"), PrincipalDropOptions.None),
                new CreatePrincipal(new PrincipalDefinition(new PrincipalRef("Front \"end\""))),
            ]);

        Assert.Equal(
            ["POST /keys\n{\"actions\":[\"documents:search\"],\"collections\":[\"*\"],\"description\":\"Front \\u0022end\\u0022\"}", "DELETE /keys/3"],
            statements.Select(s => s.Sql));
        Assert.Throws<UnsupportedPrincipalChangeException>(() => session.BuildStatements(
            [new ModifyGrants(new PrincipalGrantChanges(new PrincipalRef("#7"), [new PrincipalGrant("keys:*", PrivilegeScope.Server)], []))]));
        Assert.Throws<UnsupportedPrincipalChangeException>(() => session.BuildStatements([new SetPrincipalPassword(new PrincipalRef("#7"), "x")]));
    }

    [Fact]
    public async Task TheStatementsRunThroughTheSessionsChannel()
    {
        var http = Node().On("POST", "/keys", """{"id":9,"value":"secret"}""").On("DELETE", "/keys/3", """{"id":3}""");
        await using var session = await ConnectAsync(http);
        var statements = session.BuildStatements(
            [
                new CreatePrincipal(new PrincipalDefinition(new PrincipalRef("ci"))),
                new DropPrincipal(new PrincipalRef("Search only (#3)"), PrincipalDropOptions.None),
            ]);

        await using var channel = await session.OpenChannelAsync(None);
        foreach (var statement in statements)
        {
            await foreach (var result in channel.ExecuteAsync([statement.Sql], new ExecuteOptions(RowLimit: 100), None))
            {
                Assert.True(result.Succeeded, result.Error);
            }
        }

        using var body = JsonDocument.Parse(http.Last("POST", "/keys").Body!);
        Assert.Equal("ci", body.RootElement.GetProperty("description").GetString());
        Assert.Single(http.All("DELETE", "/keys/3"));
    }

    [Theory]
    [InlineData("Search only (#3)", 3L)]
    [InlineData("#7", 7L)]
    [InlineData("a # b (#12)", 12L)]
    [InlineData("new key", null)]
    public void TheIdComesBackOutOfTheName(string name, long? id) => Assert.Equal(id, TypesenseUserKeys.Id(name));
}
