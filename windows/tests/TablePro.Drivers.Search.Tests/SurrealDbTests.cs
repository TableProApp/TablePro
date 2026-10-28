using System.Net;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Schema;
using TablePro.Drivers.SurrealDb;

namespace TablePro.Drivers.Search.Tests;

public sealed class SurrealDbTests
{
    private const string PersonInfo = """
        [{"result":{"events":{},"fields":{
            "name":"DEFINE FIELD name ON person TYPE string PERMISSIONS FULL",
            "age":"DEFINE FIELD age ON person TYPE option<int> DEFAULT 0 PERMISSIONS FULL",
            "score":"DEFINE FIELD score ON person TYPE float PERMISSIONS FULL",
            "manager":"DEFINE FIELD manager ON person TYPE option<record<person>> PERMISSIONS FULL",
            "address.city":"DEFINE FIELD address.city ON person TYPE string PERMISSIONS FULL"},
          "indexes":{"email_idx":"DEFINE INDEX email_idx ON person FIELDS email UNIQUE"},"lives":{},"tables":{}},"status":"OK","time":"1ms"},
         {"result":[{"id":"person:tobie","name":"Tobie","age":30,"email":"t@x.io","address":{"city":"London"}}],"status":"OK","time":"1ms"}]
        """;

    private static CancellationToken None => TestContext.Current.CancellationToken;

    private static FakeHttp Server() =>
        new FakeHttp()
            .On("GET", "/version", "surrealdb-2.1.4", contentType: "text/plain")
            .On("POST", "/sql", """[{"result":1,"status":"OK","time":"1µs"}]""");

    private static Task<SurrealDbSession> ConnectAsync(FakeHttp http, string database = "app/main", Dictionary<string, string>? options = null) =>
        SurrealDbSession.ConnectAsync(Profiles.Request(DatabaseEngine.SurrealDb, "root", "pw", database, options: options), http, None);

    /// <summary>Answers the structure request with the person table, then everything else with <paramref name="sql"/>.</summary>
    private static FakeHttp WithPerson(FakeHttp http, string sql)
    {
        http.On("POST", "/sql", sql);
        return http;
    }

    private static readonly Dictionary<string, SurrealKind> Kinds = new()
    {
        ["name"] = SurrealKind.Parse("string"),
        ["age"] = SurrealKind.Parse("option<int>"),
        ["score"] = SurrealKind.Parse("float"),
        ["manager"] = SurrealKind.Parse("option<record<person>>"),
    };

    [Fact]
    public async Task ConnectReadsTheVersionAndChecksTheLoginWithNamespaceAndDatabaseHeaders()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);

        Assert.Equal("2.1.4", session.ServerVersion);
        var check = http.Last("POST", "/sql");
        Assert.Equal("http://search.test:8000/sql", check.Uri.ToString());
        Assert.Equal("RETURN 1;", check.Body);
        Assert.Equal("app", check.Header("Surreal-NS"));
        Assert.Equal("main", check.Header("Surreal-DB"));
        Assert.Equal("application/json", check.Header("Accept"));
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("root:pw")), check.Header("Authorization"));
        Assert.Equal(("app", "main"), (session.CurrentDatabase, session.DefaultSchema));
    }

    [Theory]
    [InlineData("app/main", null, "app", "main")]
    [InlineData("main", "app", "app", "main")]
    [InlineData("app", null, "app", null)]
    public void NamespaceAndDatabaseComeFromTheOptionOrTheDatabaseField(string database, string? ns, string expectedNs, string? expectedDb)
    {
        var options = ns is null ? new Dictionary<string, string>() : new Dictionary<string, string> { ["namespace"] = ns };
        var profile = Profiles.Request(DatabaseEngine.SurrealDb, database: database, options: options).Profile;

        var settings = SurrealSettings.From(profile, database);

        Assert.Equal((expectedNs, expectedDb), (settings.Namespace, settings.Database));
    }

    [Fact]
    public async Task ADatabaseUserNamesItsLevelInAuthHeaders()
    {
        var http = Server();
        await using var session = await ConnectAsync(http, options: new() { ["authLevel"] = "database" });

        var check = http.Last("POST", "/sql");
        Assert.Equal("app", check.Header("Surreal-Auth-NS"));
        Assert.Equal("main", check.Header("Surreal-Auth-DB"));
    }

    [Theory]
    [InlineData("person:tobie", null, "person", "tobie", false, """type::thing("person", "tobie")""")]
    [InlineData("person:42", null, "person", "42", true, """type::thing("person", 42)""")]
    [InlineData("person:⟨jaime lannister⟩", null, "person", "jaime lannister", false, """type::thing("person", "jaime lannister")""")]
    [InlineData("person:`a\"b`", null, "person", "a\"b", false, """type::thing("person", "a\"b")""")]
    [InlineData("⟨odd table⟩:x", null, "odd table", "x", false, """type::thing("odd table", "x")""")]
    [InlineData("tobie", "person", "person", "tobie", false, """type::thing("person", "tobie")""")]
    [InlineData("person:[1, 'a']", null, "person", "[1, 'a']", false, """<record> "person:[1, 'a']" """)]
    public void RecordIdsRoundTripFromTheirTextIntoBoundExpressions(string text, string? fallback, string table, string id, bool isInteger, string expression)
    {
        var record = SurrealRecordId.Parse(text, fallback);

        Assert.NotNull(record);
        Assert.Equal((table, id, isInteger), (record.Value.Table, record.Value.IdText, record.Value.IsInteger));
        Assert.Equal(expression.TrimEnd(), record.Value.Expression(text));
    }

    [Fact]
    public void TextWithoutATableOrFallbackIsNotARecord()
    {
        Assert.Null(SurrealRecordId.Parse("tobie"));
        Assert.Null(SurrealRecordId.Parse("  "));
    }

    [Fact]
    public async Task ObjectsAreTheTablesOfTheDatabaseAndSchemasTheDatabasesOfTheNamespace()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        http.On("POST", "/sql", """[{"result":{"accesses":{},"analyzers":{},"functions":{},"params":{},"tables":{"person":"DEFINE TABLE person TYPE NORMAL SCHEMAFULL PERMISSIONS NONE","likes":"DEFINE TABLE likes TYPE RELATION IN person OUT post SCHEMALESS"}},"status":"OK","time":"1ms"}]""");

        var objects = await session.GetObjectsAsync("other", None);

        Assert.Equal("INFO FOR DB;", http.Last("POST", "/sql").Body);
        Assert.Equal("other", http.Last("POST", "/sql").Header("Surreal-DB"));
        Assert.Equal([("likes", "relation"), ("person", "schemafull")], objects.Select(o => (o.Name.Name, o.Comment!)));
        Assert.All(objects, o => Assert.Equal((ObjectKind.Collection, "other"), (o.Kind, o.Name.Schema)));

        http.On("POST", "/sql", """[{"result":{"accesses":{},"databases":{"main":"DEFINE DATABASE main","test":"DEFINE DATABASE test"},"users":{}},"status":"OK","time":"1ms"}]""");
        Assert.Equal(["main", "test"], await session.GetSchemasAsync(None));
        Assert.Equal("INFO FOR NS;", http.Last("POST", "/sql").Body);
    }

    [Fact]
    public async Task StructureJoinsDeclaredFieldsWithASampleOfTheRows()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        WithPerson(http, PersonInfo);

        var structure = await session.GetStructureAsync(new ObjectName("main", "person"), None);

        Assert.Equal("INFO FOR TABLE `person`;\nSELECT * FROM `person` LIMIT 100;", http.Last("POST", "/sql").Body);
        Assert.Equal(["id"], structure.PrimaryKey);
        Assert.Equal(["id", "age", "manager", "name", "score", "email", "address"], structure.Columns.Select(c => c.Name));
        Assert.True(structure.Columns.Single(c => c.Name == "age").IsNullable);
        Assert.Equal("0", structure.Columns.Single(c => c.Name == "age").DefaultValue);
        Assert.Equal("not declared", structure.Columns.Single(c => c.Name == "email").Comment);
        Assert.Contains(structure.Indexes, i => i.Name == "email_idx" && i.IsUnique && i.Columns.SequenceEqual(["email"]));
    }

    [Fact]
    public void BrowseBindsEveryValueAsAVariableAndPagesWithLimitStart()
    {
        var filter = new BrowseFilter([new FilterRule("age", FilterOperator.GreaterOrEqual, "18"), new FilterRule("name", FilterOperator.Contains, "O'Brien")]);

        var sql = SurrealDbSession.BuildBrowse(new BrowseRequest(new ObjectName("main", "person"), filter, [new SortColumn("name", true)], 100, 50), Kinds);

        Assert.Equal(
            """
            LET $p0 = 18;
            LET $p1 = "o'brien";
            SELECT * FROM `person` WHERE `age` >= $p0 AND string::contains(string::lowercase(<string> `name`), $p1) ORDER BY `name` DESC, id ASC LIMIT 50 START 100;
            """.ReplaceLineEndings("\n"),
            sql);
    }

    [Fact]
    public async Task BrowseSendsTheStatementAndKeepsRecordIdsAsText()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        WithPerson(http, PersonInfo);
        await session.GetStructureAsync(new ObjectName("main", "person"), None);
        http.On("POST", "/sql", """[{"result":[{"id":"person:tobie","name":"Tobie","age":30,"manager":"person:⟨jaime lannister⟩","address":{"city":"London"}}],"status":"OK","time":"1ms"}]""");

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName("main", "person"), BrowseFilter.None, [], 0, 10), None);

        Assert.Equal("SELECT * FROM `person` ORDER BY id ASC LIMIT 10 START 0;", http.Last("POST", "/sql").Body);
        Assert.Equal("person:tobie", Profiles.Cell(page, 0, "id"));
        Assert.Equal("person:⟨jaime lannister⟩", Profiles.Cell(page, 0, "manager"));
        Assert.Equal(30L, Profiles.Cell(page, 0, "age"));
        Assert.Equal(typeof(long), page.Columns[page.ColumnIndex("age")].ClrType);
        Assert.Equal("""{"city":"London"}""", Profiles.Cell(page, 0, "address"));
    }

    [Theory]
    [InlineData("age", FilterOperator.Equals, "5", null, "`age` = $p0", "5")]
    [InlineData("id", FilterOperator.Equals, "person:tobie", null, "`id` = $p0", """type::thing("person", "tobie")""")]
    [InlineData("manager", FilterOperator.NotEquals, "person:1", null, "`manager` != $p0", """type::thing("person", 1)""")]
    [InlineData("score", FilterOperator.GreaterThan, "2", null, "`score` > $p0", "2f")]
    [InlineData("age", FilterOperator.LessThan, "5", null, "`age` < $p0", "5")]
    [InlineData("age", FilterOperator.LessOrEqual, "5", null, "`age` <= $p0", "5")]
    [InlineData("name", FilterOperator.NotContains, "A", null, "!string::contains(string::lowercase(<string> `name`), $p0)", "\"a\"")]
    [InlineData("name", FilterOperator.StartsWith, "A", null, "string::starts_with(string::lowercase(<string> `name`), $p0)", "\"a\"")]
    [InlineData("name", FilterOperator.EndsWith, "A", null, "string::ends_with(string::lowercase(<string> `name`), $p0)", "\"a\"")]
    [InlineData("name", FilterOperator.IsNull, null, null, "(`name` = NONE OR `name` = NULL)", null)]
    [InlineData("name", FilterOperator.IsNotNull, null, null, "(`name` != NONE AND `name` != NULL)", null)]
    [InlineData("name", FilterOperator.IsEmpty, null, null, "(`name` = NONE OR `name` = NULL OR `name` = '')", null)]
    [InlineData("name", FilterOperator.IsNotEmpty, null, null, "(`name` != NONE AND `name` != NULL AND `name` != '')", null)]
    [InlineData("age", FilterOperator.In, "1, 2", null, "`age` INSIDE $p0", "[1, 2]")]
    [InlineData("name", FilterOperator.NotIn, "a,b", null, "`name` NOTINSIDE $p0", "[\"a\", \"b\"]")]
    [InlineData("extra", FilterOperator.Equals, "true", null, "`extra` = $p0", "true")]
    public void EveryFilterOperatorBecomesAConditionOverVariables(string column, FilterOperator op, string? value, string? second, string condition, string? firstValue)
    {
        var parameters = new SurrealParams();

        var actual = SurrealFilter.Condition(new FilterRule(column, op, value, second), "person", Kinds, [], parameters);

        Assert.Equal(condition, actual);
        Assert.Equal(firstValue is null ? string.Empty : $"LET $p0 = {firstValue};\n", parameters.Prefix);
    }

    [Fact]
    public void BetweenAndTheSearchBoxBindTheirValues()
    {
        var parameters = new SurrealParams();
        var between = SurrealFilter.Condition(new FilterRule("age", FilterOperator.Between, "1", "9"), "person", Kinds, [], parameters);
        var search = SurrealFilter.Condition(new FilterRule(null, FilterOperator.Contains, "Lon"), "person", Kinds, ["name", "address"], parameters);

        Assert.Equal("(`age` >= $p0 AND `age` <= $p1)", between);
        Assert.Equal("(string::contains(string::lowercase(<string> `name`), $p2) OR string::contains(string::lowercase(<string> `address`), $p2))", search);
        Assert.Equal("LET $p0 = 1;\nLET $p1 = 9;\nLET $p2 = \"lon\";\n", parameters.Prefix);
    }

    [Fact]
    public async Task CountGroupsAllAndAnEmptyTableIsZero()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        WithPerson(http, PersonInfo);
        await session.GetStructureAsync(new ObjectName("main", "person"), None);
        http.On("POST", "/sql", """[{"result":[{"total":7}],"status":"OK","time":"1ms"}]""");

        var count = await session.CountAsync(new ObjectName("main", "person"), new BrowseFilter([new FilterRule("age", FilterOperator.Equals, "3")]), None);

        Assert.Equal(7, count);
        Assert.Equal("LET $p0 = 3;\nSELECT count() AS total FROM `person` WHERE `age` = $p0 GROUP ALL;", http.Last("POST", "/sql").Body);
        http.On("POST", "/sql", """[{"result":[],"status":"OK","time":"1ms"}]""");
        Assert.Equal(0, await session.CountAsync(new ObjectName("main", "person"), BrowseFilter.None, None));
    }

    [Fact]
    public void SaveIsOneTransactionThatChecksEachRecordBeforeChangingIt()
    {
        var script = SurrealDbSession.BuildSave("person",
        [
            new RowUpdate(new Dictionary<string, object?> { ["id"] = "person:tobie" }, new Dictionary<string, object?> { ["age"] = "31", ["manager"] = "person:42", ["name"] = null }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = "jaime", ["name"] = "Jaime", ["score"] = 2.0, ["age"] = null }),
            new RowInsert(new Dictionary<string, object?> { ["id"] = null, ["name"] = "Anon" }),
            new RowDelete(new Dictionary<string, object?> { ["id"] = "person:⟨old one⟩" }),
        ], Kinds);

        Assert.Equal(
            """
            BEGIN TRANSACTION;
            LET $p0 = type::thing("person", "tobie");
            LET $p1 = { "age": 31, "manager": type::thing("person", 42), "name": NULL };
            LET $p2 = type::thing("person", "jaime");
            LET $p3 = { "name": "Jaime", "score": 2f };
            LET $p4 = { "name": "Anon" };
            LET $p5 = type::thing("person", "old one");
            IF array::len(SELECT id FROM $p0) != 1 { THROW "tablepro:row-count:0" };
            UPDATE $p0 MERGE $p1;
            CREATE $p2 CONTENT $p3;
            CREATE `person` CONTENT $p4;
            IF array::len(SELECT id FROM $p5) != 1 { THROW "tablepro:row-count:3" };
            DELETE $p5;
            COMMIT TRANSACTION;
            """.ReplaceLineEndings("\n"),
            script);
    }

    [Fact]
    public void EditingARecordIdIsRefused()
    {
        Assert.Throws<InvalidOperationException>(() => SurrealDbSession.BuildSave("person", [new RowUpdate(new Dictionary<string, object?> { ["id"] = "person:a" }, new Dictionary<string, object?> { ["id"] = "person:b" })], Kinds));
    }

    [Fact]
    public async Task AMissingRecordCancelsTheSaveAsARowCountMismatch()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        WithPerson(http, PersonInfo);
        await session.GetStructureAsync(new ObjectName("main", "person"), None);
        http.On("POST", "/sql", """
            [{"result":"The query was not executed due to a failed transaction","status":"ERR","time":"1ms"},
             {"result":"An error occurred: tablepro:row-count:0","status":"ERR","time":"1ms"},
             {"result":"The query was not executed due to a failed transaction","status":"ERR","time":"1ms"}]
            """);

        var error = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(new ObjectName("main", "person"), [new RowDelete(new Dictionary<string, object?> { ["id"] = "person:gone" })], None));

        Assert.Equal(0, error.Actual);
    }

    [Fact]
    public async Task AFailedTransactionReportsTheErrorThatCausedIt()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        WithPerson(http, PersonInfo);
        await session.GetStructureAsync(new ObjectName("main", "person"), None);
        http.On("POST", "/sql", """
            [{"result":"The query was not executed due to a failed transaction","status":"ERR","time":"1ms"},
             {"result":"Found 'x' for field `age`, with record `person:a`, but expected a option<int>","status":"ERR","time":"1ms"}]
            """);

        var error = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => session.SaveChangesAsync(new ObjectName("main", "person"), [new RowInsert(new Dictionary<string, object?> { ["name"] = "a" })], None));

        Assert.Equal("Found 'x' for field `age`, with record `person:a`, but expected a option<int>", error.Message);
    }

    [Fact]
    public async Task ARefusedRequestReportsTheServerInformation()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        http.On("POST", "/sql", """{"code":400,"details":"Request problems detected","description":"There is a problem with your request.","information":"Parse error: Unexpected token `FORM`"}""", HttpStatusCode.BadRequest);

        var result = (await Profiles.RunAsync(session, "SELECT * FORM person"))[0];

        Assert.Equal("Parse error: Unexpected token `FORM`", result.Error);
    }

    [Fact]
    public async Task ChannelRendersRecordsInfoAndScalars()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        http.On("POST", "/sql", """[{"result":[{"id":"person:1","name":"A","tags":["x"]},{"id":"person:2","name":"B","age":4}],"status":"OK","time":"1ms"}]""", once: true)
            .On("POST", "/sql", """[{"result":{"fields":{"name":"DEFINE FIELD name ON person TYPE string"}},"status":"OK","time":"1ms"}]""", once: true)
            .On("POST", "/sql", """[{"result":42,"status":"OK","time":"1ms"}]""", once: true)
            .On("POST", "/sql", """[{"result":[{"id":"person:9"}],"status":"OK","time":"1ms"}]""", once: true);

        var results = await Profiles.RunAsync(session, "SELECT * FROM person", "INFO FOR TABLE person", "RETURN 42", "CREATE person:9");

        var rows = results[0].ResultSets[0];
        Assert.Equal(["id", "name", "tags", "age"], rows.Columns.Select(c => c.Name));
        Assert.Equal("person:2", Profiles.Cell(rows, 1, "id"));
        Assert.Equal("""["x"]""", Profiles.Cell(rows, 0, "tags"));
        Assert.Equal(new object?[] { "fields.name", "DEFINE FIELD name ON person TYPE string" }, results[1].ResultSets[0].Rows[0]);
        Assert.Equal(42L, results[2].ResultSets[0][0, 0]);
        Assert.Equal(1, results[3].RecordsAffected);
    }

    [Fact]
    public async Task ChannelKeepsUseAndReadOnlyLetForLaterStatements()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        http.On("POST", "/sql", """[{"result":null,"status":"OK","time":"1ms"},{"result":[],"status":"OK","time":"1ms"}]""");

        var results = await Profiles.RunAsync(session, "USE NS other DB `second db`", "LET $min = 18", "LET $made = (CREATE person)", "SELECT * FROM person WHERE age > $min");

        Assert.Null(results.FirstOrDefault(r => r.Error is not null));
        var last = http.Last("POST", "/sql");
        Assert.Equal("LET $min = 18;\nSELECT * FROM person WHERE age > $min;\n", last.Body);
        Assert.Equal(("other", "second db"), (last.Header("Surreal-NS"), last.Header("Surreal-DB")));
        Assert.Contains("not replayed", results[2].Messages![0], StringComparison.Ordinal);
    }

    [Fact]
    public async Task ChannelSendsATransactionAsOneRequestAtCommit()
    {
        var http = Server();
        await using var session = await ConnectAsync(http);
        http.On("POST", "/sql", """[{"result":null,"status":"OK","time":"1ms"},{"result":[{"id":"a:1"}],"status":"OK","time":"1ms"},{"result":[{"id":"b:1"}],"status":"OK","time":"1ms"},{"result":null,"status":"OK","time":"1ms"}]""");
        var before = http.Requests.Count;

        var results = await Profiles.RunAsync(session, "BEGIN TRANSACTION", "CREATE a:1", "CREATE b:1", "COMMIT TRANSACTION");

        Assert.Equal(before + 1, http.Requests.Count);
        Assert.Equal("BEGIN TRANSACTION;\nCREATE a:1;\nCREATE b:1;\nCOMMIT TRANSACTION;\n", http.Last("POST", "/sql").Body);
        Assert.Empty(results[1].ResultSets);
        Assert.Equal(2, results[3].ResultSets.Count);
        Assert.Equal(2, results[3].RecordsAffected);
    }

    [Fact]
    public void FieldKindsReadOptionalUnionAndRecordTypes()
    {
        Assert.Equal(("int", true, (string?)null), Parts(SurrealKind.Parse("option<int>")));
        Assert.Equal(("record", true, "user"), Parts(SurrealKind.Parse("none | record<user | team>")));
        Assert.Equal(("geometry", false, (string?)null), Parts(SurrealKind.Parse("geometry<point>")));
        Assert.Equal(("any", true, (string?)null), Parts(SurrealKind.Parse("")));

        static (string, bool, string?) Parts(SurrealKind kind) => (kind.Base, kind.IsOptional, kind.RecordTable);
    }

    [Fact]
    public void QuotingEscapesBackticksAndStringsEscapeQuotes()
    {
        Assert.Equal("`a\\`b`", SurrealQl.Ident("a`b"));
        Assert.Equal("\"it's \\\"x\\\"\\n\"", SurrealQl.String("it's \"x\"\n"));
    }
}
