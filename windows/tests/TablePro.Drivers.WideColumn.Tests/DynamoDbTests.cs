using System.Net;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Editing;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Drivers.DynamoDb;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class DynamoDbTests
{
    private static readonly DynamoKeySchema OrderKeys = new([new("customer", "S"), new("order", "N")]);
    private static readonly string[] IdKey = ["id"];

    [Fact]
    public void MapsScalarAttributesToNativeCells()
    {
        Assert.Equal("x", DynamoAttributeMapper.ToCell(new AttributeValue { S = "x" }));
        Assert.Equal(12.50m, DynamoAttributeMapper.ToCell(new AttributeValue { N = "12.50" }));
        Assert.Equal(true, DynamoAttributeMapper.ToCell(new AttributeValue { BOOL = true }));
        Assert.Null(DynamoAttributeMapper.ToCell(new AttributeValue { NULL = true }));
        Assert.Equal(new byte[] { 1, 2 }, DynamoAttributeMapper.ToCell(new AttributeValue { B = new MemoryStream([1, 2]) }));

        // 38 significant digits exceed System.Decimal; the number stays exact as text.
        var wide = "1234567890123456789012345678901234567.8";
        Assert.Equal(wide, DynamoAttributeMapper.ToCell(new AttributeValue { N = wide }));
    }

    [Fact]
    public void MapsDocumentsAndSetsToJsonText()
    {
        var item = new AttributeValue
        {
            M = new Dictionary<string, AttributeValue>
            {
                ["tags"] = new() { SS = ["a", "b"] },
                ["scores"] = new() { NS = ["1", "2.5"] },
                ["blobs"] = new() { BS = [new MemoryStream([0xFF])] },
                ["list"] = new() { L = [new() { S = "x" }, new() { N = "3" }, new() { BOOL = false }, new() { NULL = true }] },
                ["empty"] = new() { L = [] },
            },
        };

        Assert.Equal(
            "{\"blobs\":[\"/w==\"],\"empty\":[],\"list\":[\"x\",3,false,null],\"scores\":[1,2.5],\"tags\":[\"a\",\"b\"]}",
            DynamoAttributeMapper.ToCell(item));
        Assert.Equal("M", DynamoAttributeMapper.TypeOf(item));
        Assert.Equal("L", DynamoAttributeMapper.TypeOf(new AttributeValue { L = [] }));
    }

    [Fact]
    public void ReadsEditedCellsBackAsTheAttributeTypeTheyHeld()
    {
        var map = DynamoAttributeMapper.FromCell("{\"a\":1,\"b\":[\"x\",true,null],\"c\":{\"d\":\"e\"}}", "M");
        Assert.Equal("1", map.M["a"].N);
        Assert.Equal("x", map.M["b"].L[0].S);
        Assert.True(map.M["b"].L[1].BOOL);
        Assert.True(map.M["b"].L[2].NULL);
        Assert.Equal("e", map.M["c"].M["d"].S);

        Assert.Equal(["a", "b"], DynamoAttributeMapper.FromCell("[\"a\",\"b\"]", "SS").SS);
        Assert.Equal(["1", "2.5"], DynamoAttributeMapper.FromCell("[1,\"2.5\"]", "NS").NS);
        Assert.Equal(new byte[] { 0xFF }, DynamoAttributeMapper.FromCell("[\"/w==\"]", "BS").BS[0].ToArray());
        Assert.Equal(2, DynamoAttributeMapper.FromCell("[1,2]", "L").L.Count);
        Assert.Equal("42", DynamoAttributeMapper.FromCell("42", "N").N);
        Assert.Equal("42", DynamoAttributeMapper.FromCell("42").S);
        Assert.Equal("12.5", DynamoAttributeMapper.FromCell(12.5m).N);
        Assert.True(DynamoAttributeMapper.FromCell(true).BOOL);
        Assert.True(DynamoAttributeMapper.FromCell(null).NULL);
        Assert.Equal(new byte[] { 0xCA, 0xFE }, DynamoAttributeMapper.FromCell("0xCAFE", "B").B.ToArray());
        Assert.Throws<FormatException>(() => DynamoAttributeMapper.FromCell("[1]", "M"));
    }

    [Fact]
    public void TypesKeyAttributesByTheTableDefinition()
    {
        Assert.Equal("7", DynamoAttributeMapper.KeyFromCell(7m, "N").N);
        Assert.Equal("7.25", DynamoAttributeMapper.KeyFromCell(" 7.25 ", "N").N);
        Assert.Equal("7", DynamoAttributeMapper.KeyFromCell(7m, "S").S);
        Assert.Equal(new byte[] { 1 }, DynamoAttributeMapper.KeyFromCell(new byte[] { 1 }, "B").B.ToArray());
        Assert.Throws<FormatException>(() => DynamoAttributeMapper.KeyFromCell("seven", "N"));
        Assert.Throws<InvalidOperationException>(() => DynamoAttributeMapper.KeyFromCell(null, "S"));
    }

    [Fact]
    public void LaysOutItemsWithKeysFirstAndEveryTypeSeen()
    {
        List<Dictionary<string, AttributeValue>> items =
        [
            new() { ["customer"] = new() { S = "c1" }, ["order"] = new() { N = "1" }, ["total"] = new() { N = "9.5" }, ["note"] = new() { S = "hi" } },
            new() { ["customer"] = new() { S = "c2" }, ["order"] = new() { N = "2" }, ["note"] = new() { N = "5" }, ["active"] = new() { BOOL = true } },
        ];

        var result = DynamoItemTable.Build(items, OrderKeys.Names);

        Assert.Equal(["customer", "order", "active", "note", "total"], result.Columns.Select(c => c.Name));
        Assert.Equal(["S", "N", "BOOL", "S|N", "N"], result.Columns.Select(c => c.DataType));
        Assert.Equal([typeof(string), typeof(decimal), typeof(bool), typeof(string), typeof(decimal)], result.Columns.Select(c => c.ClrType));
        Assert.Null(result[0, 2]);
        Assert.Equal(9.5m, result[0, 4]);
    }

    [Fact]
    public void ResolvesTheRegionAndEndpoint()
    {
        var aws = DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "eu-central-1", user: "AKID", password: "secret"));
        Assert.Equal("eu-central-1", aws.Region);
        Assert.Null(aws.ServiceUrl);
        Assert.Equal(DynamoDbCredentialSource.AccessKey, aws.CredentialSource);
        Assert.Equal(Amazon.RegionEndpoint.EUCentral1, aws.CreateConfig().RegionEndpoint);
        Assert.DoesNotContain("secret", aws.ToString(), StringComparison.Ordinal);

        var local = DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "localhost", port: 8000, user: null, password: null));
        Assert.Equal("http://localhost:8000/", local.ServiceUrl);
        Assert.Equal(DynamoDbConnectionSettings.DefaultRegion, local.Region);
        Assert.Equal(DynamoDbCredentialSource.Local, local.CredentialSource);
        Assert.True(local.IsLocal);
        Assert.Equal("us-east-1", local.CreateConfig().AuthenticationRegion);

        var option = DynamoDbConnectionSettings.From(Requests.For(
            DatabaseEngine.DynamoDb,
            host: "",
            user: null,
            options: new Dictionary<string, string> { ["region"] = "ap-southeast-2", ["endpoint"] = "https://vpce.example.com", ["profile"] = "work" }));
        Assert.Equal("ap-southeast-2", option.Region);
        Assert.Equal("https://vpce.example.com", option.ServiceUrl);
        Assert.Equal(DynamoDbCredentialSource.Profile, option.CredentialSource);

        var chain = DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "us-west-2", user: null));
        Assert.Equal(DynamoDbCredentialSource.DefaultChain, chain.CredentialSource);
        Assert.Null(chain.CreateCredentials());
    }

    [Fact]
    public void ATunnelToDynamoDbLocalDialsTheTunnelEnd()
    {
        var settings = DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "dynamo.internal", port: 8000, user: null, dialHost: "127.0.0.1", dialPort: 50123));

        Assert.Equal("http://127.0.0.1:50123/", settings.ServiceUrl);
    }

    [Fact]
    public void RefusesUnsafeOrMalformedSettings()
    {
        Assert.Throws<ArgumentException>(() => DynamoDbConnectionSettings.From(Requests.For(
            DatabaseEngine.DynamoDb, host: "us-east-1", options: new Dictionary<string, string> { ["endpoint"] = "http://remote.example.com:8000" })));
        Assert.Throws<ArgumentException>(() => DynamoDbConnectionSettings.From(Requests.For(
            DatabaseEngine.DynamoDb, host: "us-east-1", options: new Dictionary<string, string> { ["region"] = "us-east-1/evil" })));
        Assert.Throws<ArgumentException>(() => DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "us-east-1", user: "AKID", password: null)));
    }

    [Fact]
    public void SessionTokensMakeTemporaryCredentials()
    {
        var settings = DynamoDbConnectionSettings.From(Requests.For(
            DatabaseEngine.DynamoDb, host: "us-east-1", user: "ASIA", options: new Dictionary<string, string> { ["sessionToken"] = "token" }));

        Assert.IsType<Amazon.Runtime.SessionAWSCredentials>(settings.CreateCredentials());
    }

    [Theory]
    [InlineData("us-east-1", true)]
    [InlineData("us-gov-west-1", true)]
    [InlineData("cn-north-1", true)]
    [InlineData("localhost", false)]
    [InlineData("US-EAST-1", false)]
    [InlineData("us-east-1.example.com", false)]
    public void RecognizesRegionNames(string text, bool expected) => Assert.Equal(expected, DynamoDbConnectionSettings.IsRegion(text));

    [Fact]
    public void ComparesNonKeyTextAsStringAndNumber()
    {
        var plan = Translate(new FilterRule("total", FilterOperator.Equals, "10"));

        Assert.Equal("(#n0 = :v0 OR #n0 = :v1)", plan.Expression);
        Assert.Equal("total", plan.Names["#n0"]);
        Assert.Equal("10", plan.Values[":v0"].S);
        Assert.Equal("10", plan.Values[":v1"].N);
        Assert.Null(plan.ClientFilter);
    }

    [Fact]
    public void ComparesKeyAttributesByTheirDeclaredType()
    {
        var plan = Translate(new FilterRule("order", FilterOperator.GreaterThan, "5"));
        Assert.Equal("#n0 > :v0", plan.Expression);
        Assert.Equal("5", plan.Values[":v0"].N);

        Assert.True(Translate(new FilterRule("order", FilterOperator.Equals, "five")).MatchesNothing);
    }

    [Fact]
    public void ChecksCaseInsensitiveMatchesOnTheItemsRead()
    {
        var plan = Translate(new FilterRule("note", FilterOperator.Contains, "Hello"), new FilterRule("note", FilterOperator.EndsWith, "1"));

        Assert.Null(plan.Expression);
        Assert.Empty(plan.Names);
        Assert.Equal(2, plan.ClientFilter!.Rules.Count);
        Assert.Single(plan.Notices);

        var digits = Translate(new FilterRule("code", FilterOperator.StartsWith, "12"));
        Assert.Equal("begins_with(#n0, :v0)", digits.Expression);
    }

    [Fact]
    public void TranslatesNullEmptyAndListOperators()
    {
        Assert.Equal("(attribute_not_exists(#n0) OR attribute_type(#n0, :v0))", Translate(new FilterRule("a", FilterOperator.IsNull)).Expression);
        Assert.Equal("(attribute_exists(#n0) AND NOT attribute_type(#n0, :v0) AND #n0 <> :v1)", Translate(new FilterRule("a", FilterOperator.IsNotEmpty)).Expression);

        var notIn = Translate(new FilterRule("order", FilterOperator.NotIn, "1, 2"));
        Assert.Equal("(attribute_exists(#n0) AND NOT #n0 IN (:v0, :v1))", notIn.Expression);

        var many = Translate(new FilterRule("order", FilterOperator.In, string.Join(",", Enumerable.Range(1, 150))));
        Assert.Equal(2, many.Expression!.Split(" IN ").Length - 1);
        Assert.Equal(150, many.Values.Count);
    }

    [Fact]
    public void BetweenSkipsReversedBoundsInsteadOfFailing()
    {
        var plan = Translate(new FilterRule("score", FilterOperator.Between, "10", "9"));

        // As text "10" sorts before "9"; as numbers the range is reversed and is left out.
        Assert.Equal("#n0 BETWEEN :v0 AND :v1", plan.Expression);
        Assert.Equal("10", plan.Values[":v0"].S);
        Assert.True(Translate(new FilterRule("order", FilterOperator.Between, "10", "9")).MatchesNothing);
    }

    [Fact]
    public void MatchAnyWithAClientRuleChecksEverythingOnTheItemsRead()
    {
        var plan = DynamoFilterTranslator.Translate(
            new BrowseFilter([new FilterRule("order", FilterOperator.Equals, "1"), new FilterRule("note", FilterOperator.EndsWith, "x")], MatchAll: false),
            OrderKeys.Types);

        Assert.Null(plan.Expression);
        Assert.Empty(plan.Values);
        Assert.Equal(2, plan.ClientFilter!.Rules.Count);

        var server = DynamoFilterTranslator.Translate(
            new BrowseFilter([new FilterRule("order", FilterOperator.Equals, "1"), new FilterRule("order", FilterOperator.Equals, "2")], MatchAll: false),
            OrderKeys.Types);
        Assert.Equal("(#n0 = :v0 OR #n0 = :v1)", server.Expression);
    }

    [Fact]
    public void AppendsARawConditionAndDropsUnusedPlaceholders()
    {
        var plan = DynamoFilterTranslator.Translate(
            new BrowseFilter([new FilterRule("note", FilterOperator.EndsWith, "x"), new FilterRule("order", FilterOperator.LessThan, "3")], RawWhere: "attribute_exists(paid)"),
            OrderKeys.Types);

        Assert.Equal("#n1 < :v0 AND (attribute_exists(paid))", plan.Expression);
        Assert.Equal(["#n1"], plan.Names.Keys);
    }

    [Fact]
    public void ClientRulesUseTheSqlEnginesMeaning()
    {
        var item = new Dictionary<string, AttributeValue> { ["note"] = new() { S = "Hello World" }, ["n"] = new() { N = "10" } };

        Assert.True(new DynamoItemFilter([new FilterRule("note", FilterOperator.EndsWith, "WORLD")], true, []).Matches(item));
        Assert.True(new DynamoItemFilter([new FilterRule("n", FilterOperator.GreaterOrEqual, "9.99")], true, []).Matches(item));
        Assert.True(new DynamoItemFilter([new FilterRule(null, FilterOperator.Contains, "lo wo")], true, []).Matches(item));
        Assert.True(new DynamoItemFilter([new FilterRule("missing", FilterOperator.IsNull)], true, []).Matches(item));
        Assert.False(new DynamoItemFilter([new FilterRule("missing", FilterOperator.IsNull), new FilterRule("n", FilterOperator.LessThan, "5")], true, []).Matches(item));
    }

    [Fact]
    public void UpdatesWithSetAndRemoveConditionedOnTheItemExisting()
    {
        var items = DynamoSaveBuilder.Build(
            "orders",
            OrderKeys,
            [new RowUpdate(new Dictionary<string, object?> { ["customer"] = "c1", ["order"] = 7m, ["total"] = 1m }, new Dictionary<string, object?> { ["total"] = "12.5", ["note"] = null, ["tags"] = "[\"a\"]" })],
            new Dictionary<string, string> { ["total"] = "N", ["tags"] = "SS" });

        var update = Assert.Single(items).Update;
        Assert.Equal("orders", update.TableName);
        Assert.Equal("SET #a0 = :v0, #a2 = :v1 REMOVE #a1", update.UpdateExpression);
        Assert.Equal("attribute_exists(#k)", update.ConditionExpression);
        Assert.Equal("customer", update.ExpressionAttributeNames["#k"]);
        Assert.Equal("total", update.ExpressionAttributeNames["#a0"]);
        Assert.Equal("12.5", update.ExpressionAttributeValues[":v0"].N);
        Assert.Equal(["a"], update.ExpressionAttributeValues[":v1"].SS);
        Assert.Equal(["customer", "order"], update.Key.Keys);
        Assert.Equal("7", update.Key["order"].N);
    }

    [Fact]
    public void InsertsAndDeletesWithExistenceConditions()
    {
        var items = DynamoSaveBuilder.Build("orders", OrderKeys, [
            new RowInsert(new Dictionary<string, object?> { ["customer"] = "c1", ["order"] = "8", ["note"] = "new", ["gone"] = null }),
            new RowDelete(new Dictionary<string, object?> { ["customer"] = "c1", ["order"] = 7m }),
        ]);

        Assert.Equal("attribute_not_exists(#k)", items[0].Put.ConditionExpression);
        Assert.Equal(["customer", "order", "note"], items[0].Put.Item.Keys);
        Assert.Equal("8", items[0].Put.Item["order"].N);
        Assert.Equal("attribute_exists(#k)", items[1].Delete.ConditionExpression);
    }

    [Fact]
    public void RefusesWritesDynamoDbCannotMake()
    {
        var key = new Dictionary<string, object?> { ["customer"] = "c1", ["order"] = 7m };

        Assert.Throws<InvalidOperationException>(() => DynamoSaveBuilder.Build("orders", OrderKeys, [new RowUpdate(key, new Dictionary<string, object?> { ["order"] = 8m })]));
        Assert.Throws<InvalidOperationException>(() => DynamoSaveBuilder.Build("orders", OrderKeys, [new RowDelete(new Dictionary<string, object?> { ["customer"] = "c1" })]));
        Assert.Throws<InvalidOperationException>(() => DynamoSaveBuilder.Build(
            "orders", OrderKeys, [.. Enumerable.Range(0, 101).Select(i => new RowDelete(new Dictionary<string, object?> { ["customer"] = "c", ["order"] = (decimal)i }))]));
    }

    [Fact]
    public async Task PartiQlFollowsNextTokenAcrossEmptyPagesAndReportsCapacity()
    {
        var api = new FakeDynamoDbApi
        {
            OnStatement = request => request.NextToken switch
            {
                null => new ExecuteStatementResponse { Items = [Item(1)], NextToken = "a", ConsumedCapacity = new ConsumedCapacity { CapacityUnits = 0.5 } },
                "a" => new ExecuteStatementResponse { Items = [], NextToken = "b", ConsumedCapacity = new ConsumedCapacity { CapacityUnits = 1 } },
                _ => new ExecuteStatementResponse { Items = [Item(2)], ConsumedCapacity = new ConsumedCapacity { CapacityUnits = 1 } },
            },
        };

        var result = await DynamoPartiQlRunner.RunAsync(api, "SELECT * FROM \"orders\";", new ExecuteOptions(RowLimit: 10), TestContext.Current.CancellationToken);

        Assert.True(result.Succeeded);
        Assert.Equal(["SELECT * FROM \"orders\"", "SELECT * FROM \"orders\"", "SELECT * FROM \"orders\""], api.Statements.Select(s => s.Statement));
        Assert.All(api.Statements, s => Assert.Equal(ReturnConsumedCapacity.TOTAL, s.ReturnConsumedCapacity));
        var set = Assert.Single(result.ResultSets);
        Assert.Equal(2, set.RowCount);
        Assert.False(set.IsTruncated);
        Assert.Equal("Consumed capacity: 2.5 units over 3 request(s).", Assert.Single(result.Messages!));
    }

    [Fact]
    public async Task PartiQlStopsAtTheRowLimit()
    {
        var api = new FakeDynamoDbApi
        {
            OnStatement = request => new ExecuteStatementResponse { Items = [Item(1), Item(2), Item(3)], NextToken = "more" },
        };

        var result = await DynamoPartiQlRunner.RunAsync(api, "SELECT * FROM t", new ExecuteOptions(RowLimit: 2), TestContext.Current.CancellationToken);

        Assert.Single(api.Statements);
        Assert.Equal(2, result.ResultSets[0].RowCount);
        Assert.True(result.ResultSets[0].IsTruncated);
    }

    [Fact]
    public async Task PartiQlWritesReportOneItemAndErrorsCarryTheCode()
    {
        var write = await DynamoPartiQlRunner.RunAsync(new FakeDynamoDbApi(), "UPDATE t SET a = 1 WHERE pk = 'x'", new ExecuteOptions(), TestContext.Current.CancellationToken);
        Assert.Equal(1, write.RecordsAffected);
        Assert.Empty(write.ResultSets);

        var failing = new FakeDynamoDbApi
        {
            OnStatement = _ => throw new AmazonDynamoDBException("Statement wasn't well formed") { ErrorCode = "ValidationException", StatusCode = HttpStatusCode.BadRequest },
        };
        var error = await DynamoPartiQlRunner.RunAsync(failing, "SELEC", new ExecuteOptions(), TestContext.Current.CancellationToken);
        Assert.Equal("ValidationException: Statement wasn't well formed", error.Error);
    }

    [Fact]
    public async Task ScanSkipsToTheOffsetThenResumesFromTheRememberedKey()
    {
        var api = new FakeDynamoDbApi { OnScan = FakeDynamoDbApi.NumberedTable(500) };
        var points = new DynamoResumePoints();
        var plan = DynamoFilterTranslator.Translate(BrowseFilter.None, new Dictionary<string, string> { ["id"] = "N" });

        var first = await DynamoScanReader.ReadAsync(api, "t", IdKey, plan, 0, 100, points, TestContext.Current.CancellationToken);
        Assert.Equal(100, first.Items.Count);
        Assert.True(first.HasMore);

        var third = await DynamoScanReader.ReadAsync(api, "t", IdKey, plan, 200, 100, points, TestContext.Current.CancellationToken);
        Assert.Equal("200", third.Items[0]["id"].N);
        Assert.Equal("299", third.Items[^1]["id"].N);

        var scansBefore = api.Scans.Count;
        var fourth = await DynamoScanReader.ReadAsync(api, "t", IdKey, plan, 300, 100, points, TestContext.Current.CancellationToken);
        Assert.Equal("300", fourth.Items[0]["id"].N);
        Assert.NotNull(api.Scans[scansBefore].ExclusiveStartKey);

        var last = await DynamoScanReader.ReadAsync(api, "t", IdKey, plan, 450, 100, points, TestContext.Current.CancellationToken);
        Assert.Equal(50, last.Items.Count);
        Assert.False(last.HasMore);
    }

    [Fact]
    public async Task ScanAppliesClientRulesBeforeCountingTheOffset()
    {
        var api = new FakeDynamoDbApi { OnScan = FakeDynamoDbApi.NumberedTable(100) };
        var plan = DynamoFilterTranslator.Translate(new BrowseFilter([new FilterRule("even", FilterOperator.EndsWith, "rue")]), new Dictionary<string, string> { ["id"] = "N" });

        var page = await DynamoScanReader.ReadAsync(api, "t", IdKey, plan, 10, 5, new DynamoResumePoints(), TestContext.Current.CancellationToken);

        Assert.Equal(["20", "22", "24", "26", "28"], page.Items.Select(i => i["id"].N));
        Assert.True(page.HasMore);
        Assert.All(api.Scans, s => Assert.Null(s.FilterExpression));
    }

    [Fact]
    public async Task ScanSendsTheFilterExpressionAndSkipsWhenNothingCanMatch()
    {
        var api = new FakeDynamoDbApi { OnScan = FakeDynamoDbApi.NumberedTable(10) };
        var keys = new Dictionary<string, string> { ["id"] = "N" };

        await DynamoScanReader.ReadAsync(api, "t", IdKey, DynamoFilterTranslator.Translate(new BrowseFilter([new FilterRule("id", FilterOperator.LessThan, "3")]), keys), 0, 10, new DynamoResumePoints(), TestContext.Current.CancellationToken);
        Assert.Equal("#n0 < :v0", api.Scans[0].FilterExpression);
        Assert.Equal("id", api.Scans[0].ExpressionAttributeNames["#n0"]);

        var none = await DynamoScanReader.ReadAsync(api, "t", IdKey, DynamoFilterTranslator.Translate(new BrowseFilter([new FilterRule("id", FilterOperator.Equals, "x")]), keys), 0, 10, new DynamoResumePoints(), TestContext.Current.CancellationToken);
        Assert.Empty(none.Items);
        Assert.Single(api.Scans);
    }

    [Fact]
    public void BuildsTheStructureFromTheDescriptionAndASample()
    {
        var description = Description();
        var keys = DynamoDbSession.KeysOf(description);
        List<Dictionary<string, AttributeValue>> sample =
        [
            new() { ["customer"] = new() { S = "c" }, ["order"] = new() { N = "1" }, ["status"] = new() { S = "new" } },
            new() { ["customer"] = new() { S = "c" }, ["order"] = new() { N = "2" }, ["status"] = new() { N = "3" }, ["extra"] = new() { NULL = true } },
        ];

        var structure = DynamoDbSession.BuildStructure(new ObjectName(null, "orders"), description, keys, sample);

        Assert.Equal(["customer", "order"], keys.Names);
        Assert.Equal(["customer", "order"], structure.PrimaryKey);
        Assert.Equal(["S (partition key)", "N (sort key)", "NULL", "S|N"], structure.Columns.Select(c => c.DataType));
        Assert.Equal(["PRIMARY", "by_status", "by_total"], structure.Indexes.Select(i => i.Name));
        Assert.Equal("GSI (KEYS_ONLY)", structure.Indexes[1].Method);
        Assert.Equal(["status", "order"], structure.Indexes[1].Columns);
        Assert.Equal("LSI (ALL)", structure.Indexes[2].Method);
    }

    [Fact]
    public void WritesTheDescriptionAsTheDefinition()
    {
        var json = DynamoDbSession.DescribeJson(Description());

        Assert.Contains("\"TableName\": \"orders\"", json, StringComparison.Ordinal);
        Assert.Contains("\"KeyType\": \"RANGE\"", json, StringComparison.Ordinal);
        Assert.Contains("\"IndexName\": \"by_status\"", json, StringComparison.Ordinal);
        Assert.Contains("\"ItemCount\": 42", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SaveTurnsAFailedConditionIntoARowCountMismatch()
    {
        var api = new ThrowingTransactions { OnDescribe = _ => new DescribeTableResponse { Table = Description() } };
        await using var session = new DynamoDbSession(
            new ConnectionProfile { Name = "t", Engine = DatabaseEngine.DynamoDb, Host = "us-east-1" },
            DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "us-east-1", user: null)),
            api);

        var ex = await Assert.ThrowsAsync<RowCountMismatchException>(() => session.SaveChangesAsync(
            new ObjectName(null, "orders"),
            [new RowDelete(new Dictionary<string, object?> { ["customer"] = "c", ["order"] = 1m })],
            TestContext.Current.CancellationToken));

        Assert.Equal(0, ex.Actual);
        Assert.Contains("no longer exists", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CountIsTheTablesApproximateItemCount()
    {
        var api = new FakeDynamoDbApi { OnDescribe = _ => new DescribeTableResponse { Table = Description() } };
        await using var session = new DynamoDbSession(
            new ConnectionProfile { Name = "t", Engine = DatabaseEngine.DynamoDb, Host = "us-east-1" },
            DynamoDbConnectionSettings.From(Requests.For(DatabaseEngine.DynamoDb, host: "us-east-1", user: null)),
            api);

        Assert.Equal(42, await session.CountAsync(new ObjectName(null, "orders"), BrowseFilter.None, TestContext.Current.CancellationToken));
        Assert.Equal(-1, await session.CountAsync(new ObjectName(null, "orders"), new BrowseFilter([new FilterRule("a", FilterOperator.IsNull)]), TestContext.Current.CancellationToken));
    }

    private static DynamoFilterPlan Translate(params FilterRule[] rules) => DynamoFilterTranslator.Translate(new BrowseFilter(rules), OrderKeys.Types);

    private static Dictionary<string, AttributeValue> Item(int id) => new() { ["id"] = new() { N = id.ToString(System.Globalization.CultureInfo.InvariantCulture) } };

    private static TableDescription Description() => new()
    {
        TableName = "orders",
        TableStatus = TableStatus.ACTIVE,
        ItemCount = 42,
        KeySchema = [new KeySchemaElement("order", KeyType.RANGE), new KeySchemaElement("customer", KeyType.HASH)],
        AttributeDefinitions = [new AttributeDefinition("customer", ScalarAttributeType.S), new AttributeDefinition("order", ScalarAttributeType.N), new AttributeDefinition("status", ScalarAttributeType.S)],
        GlobalSecondaryIndexes =
        [
            new GlobalSecondaryIndexDescription
            {
                IndexName = "by_status",
                KeySchema = [new KeySchemaElement("status", KeyType.HASH), new KeySchemaElement("order", KeyType.RANGE)],
                Projection = new Projection { ProjectionType = ProjectionType.KEYS_ONLY },
            },
        ],
        LocalSecondaryIndexes =
        [
            new LocalSecondaryIndexDescription
            {
                IndexName = "by_total",
                KeySchema = [new KeySchemaElement("customer", KeyType.HASH), new KeySchemaElement("total", KeyType.RANGE)],
                Projection = new Projection { ProjectionType = ProjectionType.ALL },
            },
        ],
    };

    private sealed class ThrowingTransactions : IDynamoDbApi
    {
        public Func<DescribeTableRequest, DescribeTableResponse> OnDescribe { get; set; } = _ => new DescribeTableResponse();

        public Task<ListTablesResponse> ListTablesAsync(ListTablesRequest request, CancellationToken cancellationToken) => Task.FromResult(new ListTablesResponse());

        public Task<DescribeTableResponse> DescribeTableAsync(DescribeTableRequest request, CancellationToken cancellationToken) => Task.FromResult(OnDescribe(request));

        public Task<ScanResponse> ScanAsync(ScanRequest request, CancellationToken cancellationToken) => Task.FromResult(new ScanResponse());

        public Task<ExecuteStatementResponse> ExecuteStatementAsync(ExecuteStatementRequest request, CancellationToken cancellationToken) => Task.FromResult(new ExecuteStatementResponse());

        public Task<TransactWriteItemsResponse> TransactWriteItemsAsync(TransactWriteItemsRequest request, CancellationToken cancellationToken) =>
            throw new TransactionCanceledException("Transaction cancelled") { CancellationReasons = [new CancellationReason { Code = "ConditionalCheckFailed" }] };

        public void Dispose()
        {
        }
    }
}
