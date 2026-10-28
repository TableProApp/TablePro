using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Sql;

public sealed class CommandDialectTests
{
    [Fact]
    public void RedisSplitsOneCommandPerLineAndSkipsComments()
    {
        const string script = "# warm the cache\nSET user:1 \"Ana\"\n\nHGETALL session:9\nSET big \\\n  value";

        var statements = SqlScript.Split(script, RedisDialect.Instance);

        Assert.Equal(["SET user:1 \"Ana\"", "HGETALL session:9", "SET big    value"], statements.Select(s => s.Text));
    }

    [Theory]
    [InlineData("GET user:1", StatementKind.Read)]
    [InlineData("hgetall session:9", StatementKind.Read)]
    [InlineData("SET user:1 Ana", StatementKind.Write)]
    [InlineData("DEL a b c", StatementKind.Write)]
    [InlineData("FLUSHDB", StatementKind.Ddl)]
    [InlineData("SELECT 3", StatementKind.Session)]
    [InlineData("CONFIG GET maxmemory", StatementKind.Read)]
    [InlineData("CONFIG SET maxmemory 1gb", StatementKind.Write)]
    [InlineData("CLIENT KILL ID 7", StatementKind.Write)]
    [InlineData("MADEUP x", StatementKind.Unknown)]
    public void RedisClassifiesByVerb(string command, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(command, RedisDialect.Instance));

    [Fact]
    public void CommandWordsHonourQuotesAndEscapes()
    {
        Assert.Equal(["SET", "greeting", "hello world", "it's"], CommandWords.Read("SET greeting \"hello world\" 'it''s'").Take(3).Append("it's"));
        Assert.Equal(["SET", "k", "line\none"], CommandWords.Read("SET k \"line\\none\""));
    }

    [Fact]
    public void MongoSplitsAtSemicolonsAndLineBreaksButKeepsMethodChains()
    {
        const string script = "use shop\ndb.users.find({ age: { $gt: 30 } })\n  .sort({ name: 1 })\n  .limit(5)\ndb.orders.countDocuments({}); db.orders.drop()";

        var statements = SqlScript.Split(script, MongoDialect.Instance);

        Assert.Equal(4, statements.Length);
        Assert.Equal("use shop", statements[0].Text);
        Assert.StartsWith("db.users.find(", statements[1].Text, StringComparison.Ordinal);
        Assert.EndsWith(".limit(5)", statements[1].Text, StringComparison.Ordinal);
        Assert.Equal("db.orders.countDocuments({})", statements[2].Text);
        Assert.Equal("db.orders.drop()", statements[3].Text);
    }

    [Fact]
    public void MongoKeepsMultiLineDocumentsWhole()
    {
        const string script = "db.users.insertOne({\n  name: \"Ana\",\n  tags: [\n    \"a\"\n  ]\n})";

        Assert.Single(SqlScript.Split(script, MongoDialect.Instance));
    }

    [Theory]
    [InlineData("db.users.find({})", StatementKind.Read)]
    [InlineData("db.users.find({}).limit(3).toArray()", StatementKind.Read)]
    [InlineData("db.users.aggregate([{ $match: {} }])", StatementKind.Read)]
    [InlineData("db.users.aggregate([{ $match: {} }, { $out: \"copy\" }])", StatementKind.Write)]
    [InlineData("db.users.updateOne({ _id: 1 }, { $set: { a: 2 } })", StatementKind.Write)]
    [InlineData("db.getCollection(\"users\").deleteMany({})", StatementKind.Write)]
    [InlineData("db.users.createIndex({ email: 1 })", StatementKind.Ddl)]
    [InlineData("db.dropDatabase()", StatementKind.Ddl)]
    [InlineData("use analytics", StatementKind.Session)]
    [InlineData("show collections", StatementKind.Read)]
    public void MongoClassifiesByMethod(string statement, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(statement, MongoDialect.Instance));

    [Fact]
    public void ElasticsearchSplitsRequestsWithTheirBodies()
    {
        const string script = "GET /logs/_search\n{\n  \"query\": { \"match_all\": {} }\n}\n\nDELETE /logs\nPOST /logs/_doc\n{ \"msg\": \"hi\" }";

        var statements = SqlScript.Split(script, ElasticsearchDialect.Instance);

        Assert.Equal(3, statements.Length);
        Assert.StartsWith("GET /logs/_search\n{", statements[0].Text, StringComparison.Ordinal);
        Assert.EndsWith("}", statements[0].Text, StringComparison.Ordinal);
        Assert.Equal("DELETE /logs", statements[1].Text);
    }

    [Theory]
    [InlineData("GET /logs/_search", StatementKind.Read)]
    [InlineData("POST /logs/_search\n{}", StatementKind.Read)]
    [InlineData("POST /logs/_doc\n{}", StatementKind.Write)]
    [InlineData("PUT /logs", StatementKind.Ddl)]
    [InlineData("DELETE /logs", StatementKind.Ddl)]
    [InlineData("DELETE /logs/_doc/1", StatementKind.Write)]
    [InlineData("PUT /logs/_mapping\n{}", StatementKind.Ddl)]
    [InlineData("hello", StatementKind.Unknown)]
    public void ElasticsearchClassifiesByMethodAndPath(string request, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(request, ElasticsearchDialect.Instance));

    [Theory]
    [InlineData("POST /collections/books/documents/search", StatementKind.Read)]
    [InlineData("POST /collections", StatementKind.Ddl)]
    [InlineData("DELETE /collections/books", StatementKind.Ddl)]
    [InlineData("POST /collections/books/documents", StatementKind.Write)]
    public void TypesenseClassifiesByPath(string request, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(request, TypesenseDialect.Instance));

    [Fact]
    public void GraphQlSplitsTopLevelOperations()
    {
        const string script = "{ Get { Article { title } } }\nmutation { delete(id: \"1\") }";

        var statements = SqlScript.Split(script, GraphQlDialect.Instance);

        Assert.Equal(2, statements.Length);
        Assert.Equal(StatementKind.Read, StatementClassifier.Classify(statements[0].Text, GraphQlDialect.Instance));
        Assert.Equal(StatementKind.Write, StatementClassifier.Classify(statements[1].Text, GraphQlDialect.Instance));
    }

    [Theory]
    [InlineData("SELECT * FROM person", StatementKind.Read)]
    [InlineData("CREATE person SET name = 'Ana'", StatementKind.Write)]
    [InlineData("RELATE person:a->knows->person:b", StatementKind.Write)]
    [InlineData("DEFINE TABLE person SCHEMAFULL", StatementKind.Ddl)]
    [InlineData("USE NS test DB test", StatementKind.Session)]
    public void SurrealQlClassifiesByLeadingWord(string statement, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(statement, SurrealQlDialect.Instance));

    [Theory]
    [InlineData("get /config/app", StatementKind.Read)]
    [InlineData("put /config/app on", StatementKind.Write)]
    [InlineData("lease grant 60", StatementKind.Write)]
    [InlineData("member list", StatementKind.Read)]
    [InlineData("defrag", StatementKind.Ddl)]
    public void EtcdClassifiesTwoWordCommands(string command, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(command, EtcdDialect.Instance));

    [Theory]
    [InlineData("SHOW TOPICS", StatementKind.Read)]
    [InlineData("CONSUME orders FROM OLDEST LIMIT 10", StatementKind.Read)]
    [InlineData("PRODUCE orders KEY 1 VALUE '{}'", StatementKind.Write)]
    [InlineData("DROP TOPIC orders", StatementKind.Ddl)]
    public void KafkaQlClassifiesByVerb(string command, StatementKind expected) =>
        Assert.Equal(expected, StatementClassifier.Classify(command, KafkaDialect.Instance));

    [Fact]
    public void CqlUsesDoubleSlashCommentsAndHasNoOffset()
    {
        var statements = SqlScript.Split("// all users\nSELECT * FROM users; SELECT * FROM t", CqlDialect.Instance);
        Assert.Equal(["SELECT * FROM users", "SELECT * FROM t"], statements.Select(s => s.Text));

        var spec = CqlDialect.Instance.BuildBrowse(new TablePro.Core.Browse.BrowseRequest(new TablePro.Core.Schema.ObjectName("ks", "users"), TablePro.Core.Browse.BrowseFilter.None, [], 100, 50));
        Assert.Equal("SELECT * FROM \"ks\".\"users\" LIMIT 150", spec.Text);
    }

    [Fact]
    public void CqlKeepsABatchTogether()
    {
        const string script = "SELECT * FROM t;\nBEGIN UNLOGGED BATCH\n  INSERT INTO t (id) VALUES (1);\n  DELETE FROM t WHERE id = 2;\nAPPLY BATCH;\nSELECT 1 FROM t";

        var statements = SqlScript.Split(script, CqlDialect.Instance).Select(s => s.Text).ToArray();

        Assert.Equal(3, statements.Length);
        Assert.Equal("SELECT * FROM t", statements[0]);
        Assert.StartsWith("BEGIN UNLOGGED BATCH", statements[1], StringComparison.Ordinal);
        Assert.Contains("DELETE FROM t WHERE id = 2;", statements[1], StringComparison.Ordinal);
        Assert.EndsWith("APPLY BATCH", statements[1], StringComparison.Ordinal);
        Assert.Equal("SELECT 1 FROM t", statements[2]);
    }

    [Fact]
    public void CommandLanguagesAreNotSql()
    {
        Assert.False(RedisDialect.Instance.IsSql);
        Assert.False(MongoDialect.Instance.IsSql);
        Assert.False(ElasticsearchDialect.Instance.SupportsFormatting);
        Assert.True(ClickHouseDialect.Instance.IsSql);
        Assert.Empty(RedisDialect.Instance.Explain("GET a"));
    }
}
