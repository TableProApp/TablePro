using TablePro.Core.Schema;
using TablePro.Drivers.Cassandra;

namespace TablePro.Drivers.WideColumn.Tests;

public sealed class CqlDdlTests
{
    private static readonly ObjectName Events = new("shop", "events");

    internal static CqlTableShape EventsShape() => new(Events, [
        new CqlColumnRow("payload", "map<text, int>", "regular", -1),
        new CqlColumnRow("ts", "timestamp", "clustering", 0, "desc"),
        new CqlColumnRow("tenant", "text", "partition_key", 0),
        new CqlColumnRow("day", "date", "partition_key", 1),
        new CqlColumnRow("seq", "int", "clustering", 1, "asc"),
        new CqlColumnRow("owner", "text", "static", -1),
        new CqlColumnRow("note", "text", "regular", -1),
    ]);

    [Fact]
    public void OrdersColumnsAsDescribeDoes()
    {
        var shape = EventsShape();

        Assert.Equal(["tenant", "day", "ts", "seq", "owner", "note", "payload"], shape.Columns.Select(c => c.Name));
        Assert.Equal(["tenant", "day"], shape.PartitionKey);
        Assert.Equal(["ts", "seq"], shape.ClusteringKey);
        Assert.Equal(["tenant", "day", "ts", "seq"], shape.PrimaryKey);
        Assert.True(shape.IsComposite("payload"));
        Assert.False(shape.IsComposite("note"));
    }

    [Fact]
    public void MarksKeyColumnsAndTheirRoleInTheStructure()
    {
        var columns = EventsShape().ToColumnInfos();

        Assert.Equal("text (partition key)", columns[0].DataType);
        Assert.Equal("timestamp (clustering DESC)", columns[2].DataType);
        Assert.Equal("int (clustering ASC)", columns[3].DataType);
        Assert.Equal("text (static)", columns[4].DataType);
        Assert.Equal("text", columns[5].DataType);
        Assert.True(columns[0].IsPrimaryKey);
        Assert.False(columns[0].IsNullable);
        Assert.False(columns[4].IsPrimaryKey);
        Assert.Equal(3, columns[3].Ordinal);
    }

    [Fact]
    public void WritesTheTableDefinitionFromSystemSchema()
    {
        IReadOnlyList<KeyValuePair<string, object?>> options =
        [
            new("keyspace_name", "shop"),
            new("table_name", "events"),
            new("id", Guid.Empty),
            new("gc_grace_seconds", 864000),
            new("comment", "It's events"),
            new("caching", new SortedDictionary<string, string> { ["rows_per_partition"] = "NONE", ["keys"] = "ALL" }),
            new("bloom_filter_fp_chance", 0.01d),
            new("flags", new List<string> { "compound" }),
            new("cdc", null),
        ];
        IReadOnlyList<CqlIndexRow> indexes =
        [
            new("events_note_idx", "COMPOSITES", new Dictionary<string, string> { ["target"] = "note" }),
            new("events_sai", "CUSTOM", new Dictionary<string, string> { ["target"] = "owner", ["class_name"] = "StorageAttachedIndex", ["case_sensitive"] = "false" }),
        ];

        var definition = CqlDdl.TableDefinition(EventsShape(), options, indexes);

        Assert.Equal(
            "CREATE TABLE \"shop\".\"events\" (\n"
            + "    \"tenant\" text,\n    \"day\" date,\n    \"ts\" timestamp,\n    \"seq\" int,\n    \"owner\" text static,\n    \"note\" text,\n    \"payload\" map<text, int>,\n"
            + "    PRIMARY KEY ((\"tenant\", \"day\"), \"ts\", \"seq\")\n"
            + ") WITH CLUSTERING ORDER BY (\"ts\" DESC, \"seq\" ASC)\n"
            + "    AND bloom_filter_fp_chance = 0.01\n"
            + "    AND caching = {'keys': 'ALL', 'rows_per_partition': 'NONE'}\n"
            + "    AND comment = 'It''s events'\n"
            + "    AND gc_grace_seconds = 864000;\n\n"
            + "CREATE INDEX \"events_note_idx\" ON \"shop\".\"events\" (note);\n\n"
            + "CREATE CUSTOM INDEX \"events_sai\" ON \"shop\".\"events\" (owner) USING 'StorageAttachedIndex' WITH OPTIONS = {'case_sensitive': 'false'};",
            definition);
    }

    [Fact]
    public void WritesASinglePartitionKeyWithoutParentheses()
    {
        var shape = new CqlTableShape(new ObjectName("ks", "users"), [new CqlColumnRow("id", "uuid", "partition_key", 0), new CqlColumnRow("name", "text", "regular", -1)]);

        Assert.Equal(
            "CREATE TABLE \"ks\".\"users\" (\n    \"id\" uuid,\n    \"name\" text,\n    PRIMARY KEY (\"id\")\n);",
            CqlDdl.TableDefinition(shape, [], []));
    }

    [Fact]
    public void WritesAMaterializedView()
    {
        var shape = new CqlTableShape(new ObjectName("ks", "by_name"), [
            new CqlColumnRow("name", "text", "partition_key", 0),
            new CqlColumnRow("id", "uuid", "clustering", 0, "asc"),
        ]);

        Assert.Equal(
            "CREATE MATERIALIZED VIEW \"ks\".\"by_name\" AS\n    SELECT * FROM \"ks\".\"users\"\n    WHERE name IS NOT NULL AND id IS NOT NULL\n"
            + "    PRIMARY KEY (\"name\", \"id\") WITH CLUSTERING ORDER BY (\"id\" ASC)\n    AND default_time_to_live = 0;",
            CqlDdl.ViewDefinition(shape, "users", "name IS NOT NULL AND id IS NOT NULL", includeAllColumns: true, [new("default_time_to_live", 0), new("base_table_name", "users")]));
    }

    [Fact]
    public void WritesKeyspaceTypeFunctionAndAggregateDefinitions()
    {
        Assert.Equal(
            "CREATE KEYSPACE \"shop\" WITH replication = {'class': 'NetworkTopologyStrategy', 'dc1': '3'} AND durable_writes = true;",
            CqlDdl.KeyspaceDefinition("shop", new Dictionary<string, string> { ["dc1"] = "3", ["class"] = "NetworkTopologyStrategy" }, durableWrites: true));
        Assert.Equal(
            "CREATE TYPE \"shop\".\"address\" (\n    \"street\" text,\n    \"zip\" int\n);",
            CqlDdl.TypeDefinition(new ObjectName("shop", "address"), ["street", "zip"], ["text", "int"]));
        Assert.Equal(
            "CREATE FUNCTION \"shop\".\"plus\"(\"a\" int, \"b\" int)\n    RETURNS NULL ON NULL INPUT\n    RETURNS int\n    LANGUAGE java\n    AS $$return a + b;$$;",
            CqlDdl.FunctionDefinition(new ObjectName("shop", "plus"), ["a", "b"], ["int", "int"], calledOnNullInput: false, "int", "java", "return a + b;"));
        Assert.Equal(
            "CREATE AGGREGATE \"shop\".\"total\"(int)\n    SFUNC \"plus\"\n    STYPE int\n    INITCOND 0;",
            CqlDdl.AggregateDefinition(new ObjectName("shop", "total"), ["int"], "plus", "int", null, "0"));
    }

    [Fact]
    public void CreatesATableWithTheFirstKeyColumnAsPartitionKey()
    {
        var ddl = CqlDdl.Build(Events, new CreateTable(new ObjectName(null, "logs"), [
            new ColumnDefinition("host", "text", IsPrimaryKey: true),
            new ColumnDefinition("at", "timestamp (clustering DESC)", IsPrimaryKey: true),
            new ColumnDefinition("line", "text"),
        ]));

        Assert.Equal(["CREATE TABLE \"shop\".\"logs\" (\n  \"host\" text,\n  \"at\" timestamp,\n  \"line\" text,\n  PRIMARY KEY (\"host\", \"at\")\n)"], ddl);
        Assert.Empty(CqlDdl.Build(Events, new CreateTable(new ObjectName("shop", "nokey"), [new ColumnDefinition("a", "int")])));
    }

    [Fact]
    public void WritesColumnIndexAndObjectStatements()
    {
        Assert.Equal(["ALTER TABLE \"shop\".\"events\" ADD \"extra\" set<text>"], CqlDdl.Build(Events, new AddColumn(new ColumnDefinition("extra", "set<text>"))));
        Assert.Equal(["ALTER TABLE \"shop\".\"events\" DROP \"note\""], CqlDdl.Build(Events, new DropColumn("note")));
        Assert.Equal(["ALTER TABLE \"shop\".\"events\" RENAME \"ts\" TO \"at\""], CqlDdl.Build(Events, new RenameColumn("ts", "at")));
        Assert.Equal(["CREATE INDEX \"ix\" ON \"shop\".\"events\" (\"note\")"], CqlDdl.Build(Events, new CreateIndex(new IndexDefinition("ix", ["note"]))));
        Assert.Equal(["DROP INDEX \"shop\".\"ix\""], CqlDdl.Build(Events, new DropIndex("ix")));
        Assert.Equal(["TRUNCATE TABLE \"shop\".\"events\""], CqlDdl.Build(Events, new TruncateTable()));
        Assert.Equal(["DROP TABLE \"shop\".\"events\""], CqlDdl.Build(Events, new DropObject(new DatabaseObject(Events, ObjectKind.Table))));
        Assert.Equal(["DROP MATERIALIZED VIEW \"shop\".\"v\""], CqlDdl.Build(Events, new DropObject(new DatabaseObject(new ObjectName("shop", "v"), ObjectKind.MaterializedView))));
        Assert.Equal(["DROP TYPE \"shop\".\"address\""], CqlDdl.Build(Events, new DropObject(CassandraObjects.UserType("shop", "address", ["street"], ["text"]))));
        Assert.Equal(["DROP AGGREGATE \"shop\".\"total\""], CqlDdl.Build(Events, new DropObject(CassandraObjects.Aggregate("shop", "total"))));
        Assert.Equal(["DROP FUNCTION \"shop\".\"plus\""], CqlDdl.Build(Events, new DropObject(new DatabaseObject(new ObjectName("shop", "plus"), ObjectKind.Function))));
    }

    [Fact]
    public void LeavesOutWhatCqlCannotExpress()
    {
        var before = new ColumnDefinition("note", "text");

        Assert.Empty(CqlDdl.Build(Events, new AlterColumn(before, before with { DataType = "varchar", IsNullable = false, DefaultExpression = "'x'" })));
        Assert.Equal(["ALTER TABLE \"shop\".\"events\" RENAME \"note\" TO \"memo\""], CqlDdl.Build(Events, new AlterColumn(before, before with { Name = "memo" })));
        Assert.Empty(CqlDdl.Build(Events, new CreateIndex(new IndexDefinition("ux", ["note"], IsUnique: true))));
        Assert.Empty(CqlDdl.Build(Events, new CreateIndex(new IndexDefinition("multi", ["a", "b"]))));
        Assert.Empty(CqlDdl.Build(Events, new RenameTable("events2")));
        Assert.Empty(CqlDdl.Build(Events, new DropForeignKey("fk")));
    }

    [Theory]
    [InlineData("text (partition key)", "text")]
    [InlineData("map<text, int> (static)", "map<text, int>")]
    [InlineData("timestamp (clustering DESC)", "timestamp")]
    [InlineData("frozen<address>", "frozen<address>")]
    public void StripsTheRoleFromAStructureType(string type, string expected) => Assert.Equal(expected, CqlTableShape.StripRole(type));

    [Fact]
    public void ListsUserTypesAndAggregatesAsFunctionsToldApartByComment()
    {
        var type = CassandraObjects.UserType("shop", "address", ["street", "zip"], ["text", "int"]);

        Assert.Equal(ObjectKind.Function, type.Kind);
        Assert.Equal("user-defined type (street text, zip int)", type.Comment);
        Assert.True(CassandraObjects.IsUserType(type));
        Assert.True(CassandraObjects.IsAggregate(CassandraObjects.Aggregate("shop", "total")));
        Assert.True(CassandraObjects.IsSystemKeyspace("system_schema"));
        Assert.True(CassandraObjects.IsSystemKeyspace("system"));
        Assert.False(CassandraObjects.IsSystemKeyspace("systems"));
    }
}
