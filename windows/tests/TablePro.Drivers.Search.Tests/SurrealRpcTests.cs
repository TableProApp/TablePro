using System.Buffers.Binary;
using System.Net;
using System.Text;
using TablePro.Core.Browse;
using TablePro.Core.Connections;
using TablePro.Core.Schema;
using TablePro.Drivers.SurrealDb;

namespace TablePro.Drivers.Search.Tests;

/// <summary>SurrealDB 2's RPC over HTTP in CBOR, which keeps datetimes, decimals and record ids typed.</summary>
public sealed class SurrealRpcTests
{
    private static CancellationToken None => TestContext.Current.CancellationToken;

    [Fact]
    public void DecodesTheTypesJsonFlattens()
    {
        var value = Assert.IsType<SurrealObject>(SurrealCbor.Decode(Cbor.Map(
            ("born", Cbor.Tag(12, Cbor.Array(Cbor.Int(1_700_000_000), Cbor.Int(123_456_789)))),
            ("iso", Cbor.Tag(0, Cbor.Text("2024-05-01T10:00:00.5Z"))),
            ("price", Cbor.Tag(10, Cbor.Text("12.50"))),
            ("id", Cbor.Tag(8, Cbor.Array(Cbor.Text("person"), Cbor.Text("tobie")))),
            ("odd", Cbor.Tag(8, Cbor.Array(Cbor.Text("person"), Cbor.Text("jaime lannister")))),
            ("n", Cbor.Tag(8, Cbor.Array(Cbor.Text("person"), Cbor.Int(42)))),
            ("key", Cbor.Tag(37, Cbor.Bytes(Guid.Parse("0190d0a5-2c1a-7c3e-9a8b-1234567890ab").ToByteArray(bigEndian: true)))),
            ("gone", Cbor.Tag(6, Cbor.Null)),
            ("wait", Cbor.Tag(14, Cbor.Array(Cbor.Int(5_400), Cbor.Int(2_000_000)))),
            ("big", Cbor.Int(-5)),
            ("half", Cbor.Half(1.5f)),
            ("ok", Cbor.True))));

        object? Field(string name) => value.TryGetValue(name, out var field) ? field : throw new KeyNotFoundException(name);

        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1_700_000_000).AddTicks(1_234_567), Field("born"));
        Assert.Equal(new DateTimeOffset(2024, 5, 1, 10, 0, 0, 500, TimeSpan.Zero), Field("iso"));
        Assert.Equal(12.50m, Field("price"));
        Assert.Equal("person:tobie", Field("id")!.ToString());
        Assert.Equal("person:\x27E8jaime lannister\x27E9", Field("odd")!.ToString());
        Assert.Equal("person:42", Field("n")!.ToString());
        Assert.Equal(Guid.Parse("0190d0a5-2c1a-7c3e-9a8b-1234567890ab"), Field("key"));
        Assert.Null(Field("gone"));
        Assert.Equal("1h30m2ms", Field("wait")!.ToString());
        Assert.Equal(-5L, Field("big"));
        Assert.Equal(1.5, Field("half"));
        Assert.Equal(true, Field("ok"));
    }

    [Fact]
    public void RecordIdsReadBackAsTheRecordTheyName()
    {
        var literal = new SurrealRecord("person", "jaime lannister").ToString();
        var parsed = SurrealRecordId.Parse(literal)!.Value;

        Assert.Equal(("person", "jaime lannister", false), (parsed.Table, parsed.IdText, parsed.IsComplex));
        Assert.True(SurrealRecordId.Parse(new SurrealRecord("temp", new List<object?> { "london", 2L }).ToString())!.Value.IsComplex);
    }

    [Fact]
    public void QueryRequestIsTheRpcEnvelope()
    {
        var request = Assert.IsType<SurrealObject>(SurrealCbor.Decode(SurrealCbor.QueryRequest(7, "RETURN 1;")));

        Assert.Equal(["id", "method", "params"], request.Fields.Select(f => f.Key));
        Assert.Equal(7L, request.Fields[0].Value);
        Assert.Equal("query", request.Fields[1].Value);
        Assert.Equal(["RETURN 1;"], Assert.IsType<List<object?>>(request.Fields[2].Value));
    }

    [Fact]
    public void ShapesBecomeGeoJson()
    {
        var line = SurrealCbor.Decode(Cbor.Tag(89, Cbor.Array(
            Cbor.Tag(88, Cbor.Array(Cbor.Double(1), Cbor.Double(2))),
            Cbor.Tag(88, Cbor.Array(Cbor.Double(3.5), Cbor.Double(4))))));

        Assert.Equal("""{"type":"LineString","coordinates":[[1,2],[3.5,4]]}""", SurrealValues.ToCell(line));
    }

    [Fact]
    public void IntegersBeyondLongKeepEveryDigit()
    {
        Assert.Equal(18_446_744_073_709_551_615m, SurrealCbor.Decode([0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]));
        Assert.Equal(long.MinValue, SurrealCbor.Decode([0x3B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]));
        Assert.Equal(42L, SurrealCbor.Decode([0x18, 42]));
    }

    [Fact]
    public void TruncatedOrIndefiniteCborIsRefused()
    {
        Assert.Throws<FormatException>(() => SurrealCbor.Decode([0x63, (byte)'a']));
        Assert.Throws<FormatException>(() => SurrealCbor.Decode([0x9F, 0xFF]));
    }

    [Theory]
    [InlineData("2.1.4", true)]
    [InlineData("3.0.0-beta", true)]
    [InlineData("1.5.4", false)]
    [InlineData("", false)]
    public void RpcIsUsedFromSurrealDbTwo(string version, bool expected)
    {
        Assert.Equal(expected, SurrealDbSession.SpeaksRpc(version));
    }

    [Fact]
    public async Task ConnectPostsCborToRpcWithScopeHeaders()
    {
        var server = new RpcServer(_ => Statements(Cbor.Int(1)));
        await using var session = await ConnectAsync(server);

        Assert.True(session.UsesRpc);
        var check = server.Requests.Last();
        Assert.Equal("http://search.test:8000/rpc", check.Uri.ToString());
        Assert.Equal("application/cbor", check.Header("Accept"));
        Assert.Equal("application/cbor", check.Header("Content-Type"));
        Assert.Equal("app", check.Header("Surreal-NS"));
        Assert.Equal("main", check.Header("Surreal-DB"));
        Assert.StartsWith("Basic ", check.Header("Authorization"), StringComparison.Ordinal);
        Assert.Equal("RETURN 1;", check.Sql);
    }

    [Fact]
    public async Task BrowseKeepsDatetimesAndDecimalsTyped()
    {
        var server = new RpcServer(request => request.Sql.StartsWith("INFO FOR TABLE", StringComparison.Ordinal)
            ? Statements(
                Cbor.Map(("fields", Cbor.Map(
                    ("born", Cbor.Text("DEFINE FIELD born ON person TYPE datetime PERMISSIONS FULL")),
                    ("price", Cbor.Text("DEFINE FIELD price ON person TYPE decimal PERMISSIONS FULL")))), ("indexes", Cbor.Map())),
                Cbor.Array())
            : request.Sql.StartsWith("SELECT", StringComparison.Ordinal)
                ? Statements(Cbor.Array(Cbor.Map(
                    ("id", Cbor.Tag(8, Cbor.Array(Cbor.Text("person"), Cbor.Text("tobie")))),
                    ("born", Cbor.Tag(12, Cbor.Array(Cbor.Int(0), Cbor.Int(0)))),
                    ("price", Cbor.Tag(10, Cbor.Text("9.99"))),
                    ("seen", Cbor.Tag(12, Cbor.Array(Cbor.Int(86_400), Cbor.Int(0)))))))
                : Statements(Cbor.Int(1)));
        await using var session = await ConnectAsync(server);

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName("main", "person"), BrowseFilter.None, [], 0, 10), None);

        Assert.Equal("person:tobie", Profiles.Cell(page, 0, "id"));
        Assert.Equal(DateTimeOffset.UnixEpoch, Profiles.Cell(page, 0, "born"));
        Assert.Equal(typeof(DateTimeOffset), page.Columns[page.ColumnIndex("born")].ClrType);
        Assert.Equal(9.99m, Profiles.Cell(page, 0, "price"));
        Assert.Equal(typeof(decimal), page.Columns[page.ColumnIndex("price")].ClrType);
        Assert.Equal(DateTimeOffset.UnixEpoch.AddDays(1), Profiles.Cell(page, 0, "seen"));
    }

    [Fact]
    public async Task QueryResultsTypeUniformColumns()
    {
        var server = new RpcServer(request => request.Sql.StartsWith("SELECT", StringComparison.Ordinal)
            ? Statements(Cbor.Array(
                Cbor.Map(("at", Cbor.Tag(12, Cbor.Array(Cbor.Int(60), Cbor.Int(0)))), ("amount", Cbor.Tag(10, Cbor.Text("1.5"))), ("note", Cbor.Text("a"))),
                Cbor.Map(("at", Cbor.Tag(6, Cbor.Null)), ("amount", Cbor.Tag(10, Cbor.Text("2"))), ("note", Cbor.Int(3)))))
            : Statements(Cbor.Int(1)));
        await using var session = await ConnectAsync(server);

        var results = await Profiles.RunAsync(session, "SELECT * FROM ledger");

        var set = Assert.Single(results[0].ResultSets);
        Assert.Equal(typeof(DateTimeOffset), set.Columns[set.ColumnIndex("at")].ClrType);
        Assert.Equal(typeof(decimal), set.Columns[set.ColumnIndex("amount")].ClrType);
        Assert.Equal(2m, Profiles.Cell(set, 1, "amount"));
        Assert.Null(Profiles.Cell(set, 1, "at"));
        Assert.Equal(typeof(string), set.Columns[set.ColumnIndex("note")].ClrType);
    }

    [Fact]
    public async Task CatalogReadsRpcAnswersThroughTheirJson()
    {
        var server = new RpcServer(request => request.Sql == "INFO FOR DB;"
            ? Statements(Cbor.Map(("tables", Cbor.Map(("person", Cbor.Text("DEFINE TABLE person TYPE NORMAL SCHEMAFULL PERMISSIONS NONE"))))))
            : Statements(Cbor.Int(1)));
        await using var session = await ConnectAsync(server);

        var objects = await session.GetObjectsAsync(null, None);

        Assert.Equal("person", Assert.Single(objects).Name.Name);
        Assert.Equal("schemafull", objects[0].Comment);
    }

    [Fact]
    public async Task StatementErrorsAndRequestErrorsAreReported()
    {
        var failing = false;
        var server = new RpcServer(request => !failing
            ? Statements(Cbor.Int(1))
            : request.Sql.StartsWith("INFO", StringComparison.Ordinal)
                ? Cbor.Map(("id", Cbor.Int(2)), ("error", Cbor.Map(("code", Cbor.Int(-32000)), ("message", Cbor.Text("There was a problem with the database")))))
                : Cbor.Map(("id", Cbor.Int(3)), ("result", Cbor.Array(Cbor.Map(("status", Cbor.Text("ERR")), ("result", Cbor.Text("The table 'nope' does not exist")))))));
        await using var session = await ConnectAsync(server);
        failing = true;

        var request = await Assert.ThrowsAnyAsync<InvalidOperationException>(() => session.GetObjectsAsync(null, None));
        Assert.Contains("problem with the database", request.Message, StringComparison.Ordinal);

        var results = await Profiles.RunAsync(session, "SELECT * FROM nope");
        Assert.Contains("does not exist", results[0].Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task JsonBrowseReadsDeclaredDatetimesAndDecimalsTyped()
    {
        var http = new FakeHttp()
            .On("GET", "/version", "surrealdb-1.5.4", contentType: "text/plain")
            .On("POST", "/sql", """[{"result":1,"status":"OK","time":"1µs"}]""");
        await using var session = await SurrealDbSession.ConnectAsync(Profiles.Request(DatabaseEngine.SurrealDb, "root", "pw", "app/main"), http, None);
        http.On("POST", "/sql", """
            [{"result":{"fields":{"born":"DEFINE FIELD born ON t TYPE datetime","price":"DEFINE FIELD price ON t TYPE decimal"},"indexes":{}},"status":"OK","time":"1ms"},
             {"result":[],"status":"OK","time":"1ms"}]
            """);
        await session.GetStructureAsync(new ObjectName("main", "t"), None);
        http.On("POST", "/sql", """[{"result":[{"id":"t:1","born":"2024-05-01T10:00:00Z","price":"12.5"}],"status":"OK","time":"1ms"}]""");

        var page = await session.BrowseAsync(new BrowseRequest(new ObjectName("main", "t"), BrowseFilter.None, [], 0, 10), None);

        Assert.Equal(new DateTimeOffset(2024, 5, 1, 10, 0, 0, TimeSpan.Zero), Profiles.Cell(page, 0, "born"));
        Assert.Equal(12.5m, Profiles.Cell(page, 0, "price"));
    }

    private static Task<SurrealDbSession> ConnectAsync(RpcServer server) =>
        SurrealDbSession.ConnectAsync(Profiles.Request(DatabaseEngine.SurrealDb, "root", "pw", "app/main"), server, None);

    private static byte[] Statements(params byte[][] results) =>
        Cbor.Map(("id", Cbor.Int(1)), ("result", Cbor.Array([.. results.Select(r => Cbor.Map(("result", r), ("status", Cbor.Text("OK")), ("time", Cbor.Text("1ms"))))])));

    private sealed record RpcRequest(Uri Uri, IReadOnlyDictionary<string, string> Headers, string Sql)
    {
        public string Header(string name) => Headers.TryGetValue(name, out var value) ? value : string.Empty;
    }

    /// <summary>Answers /version as SurrealDB 2 and every /rpc request with what <paramref name="answer"/> gives.</summary>
    private sealed class RpcServer(Func<RpcRequest, byte[]> answer) : HttpMessageHandler
    {
        public List<RpcRequest> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Method == HttpMethod.Get)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("surrealdb-2.1.4") };
            }

            var body = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            var envelope = Assert.IsType<SurrealObject>(SurrealCbor.Decode(body));
            envelope.TryGetValue("params", out var parameters);
            var headers = request.Headers.Concat(request.Content.Headers).ToDictionary(h => h.Key, h => string.Join(",", h.Value), StringComparer.OrdinalIgnoreCase);
            var recorded = new RpcRequest(request.RequestUri!, headers, (string)((List<object?>)parameters!)[0]!);
            Requests.Add(recorded);
            var content = new ByteArrayContent(answer(recorded));
            content.Headers.ContentType = new("application/cbor");
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        }
    }

    /// <summary>Hand-written CBOR, so the tests check the decoder against the format rather than against itself.</summary>
    private static class Cbor
    {
        public static readonly byte[] Null = [0xF6];
        public static readonly byte[] True = [0xF5];

        public static byte[] Int(long value) => value >= 0 ? Head(0, (ulong)value) : Head(1, (ulong)(-1 - value));

        public static byte[] Text(string value)
        {
            var bytes = Encoding.UTF8.GetBytes(value);
            return [.. Head(3, (ulong)bytes.Length), .. bytes];
        }

        public static byte[] Bytes(byte[] value) => [.. Head(2, (ulong)value.Length), .. value];

        public static byte[] Double(double value)
        {
            var bytes = new byte[9];
            bytes[0] = 0xFB;
            BinaryPrimitives.WriteDoubleBigEndian(bytes.AsSpan(1), value);
            return bytes;
        }

        public static byte[] Half(float value)
        {
            var bytes = new byte[3];
            bytes[0] = 0xF9;
            BinaryPrimitives.WriteHalfBigEndian(bytes.AsSpan(1), (System.Half)value);
            return bytes;
        }

        public static byte[] Array(params byte[][] items) => [.. Head(4, (ulong)items.Length), .. items.SelectMany(i => i)];

        public static byte[] Map(params (string Key, byte[] Value)[] fields) =>
            [.. Head(5, (ulong)fields.Length), .. fields.SelectMany(f => Text(f.Key).Concat(f.Value))];

        public static byte[] Tag(ulong tag, byte[] inner) => [.. Head(6, tag), .. inner];

        private static byte[] Head(byte major, ulong argument)
        {
            var prefix = (byte)(major << 5);
            if (argument < 24)
            {
                return [(byte)(prefix | (byte)argument)];
            }

            if (argument <= byte.MaxValue)
            {
                return [(byte)(prefix | 24), (byte)argument];
            }

            var bytes = new byte[9];
            bytes[0] = (byte)(prefix | 27);
            BinaryPrimitives.WriteUInt64BigEndian(bytes.AsSpan(1), argument);
            return bytes;
        }
    }
}
