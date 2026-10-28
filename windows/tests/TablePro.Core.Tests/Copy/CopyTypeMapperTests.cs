using TablePro.Core.Connections;
using TablePro.Core.Copy;
using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Core.Tests.Copy;

public sealed class CopyTypeMapperTests
{
    [Theory]
    [InlineData("character varying(20)", DatabaseEngine.PostgreSql, SqlTypeCategory.Text, 20)]
    [InlineData("timestamp(3) with time zone", DatabaseEngine.PostgreSql, SqlTypeCategory.Timestamp, null)]
    [InlineData("int(11) unsigned", DatabaseEngine.MySql, SqlTypeCategory.Integer, null)]
    [InlineData("tinyint(1)", DatabaseEngine.MySql, SqlTypeCategory.Boolean, null)]
    [InlineData("nvarchar(max)", DatabaseEngine.SqlServer, SqlTypeCategory.Text, null)]
    [InlineData("rowversion", DatabaseEngine.SqlServer, SqlTypeCategory.ServerComputed, null)]
    [InlineData("timestamp", DatabaseEngine.SqlServer, SqlTypeCategory.ServerComputed, null)]
    [InlineData("VARCHAR2(30 CHAR)", DatabaseEngine.Oracle, SqlTypeCategory.Text, 30)]
    [InlineData("NUMBER(10)", DatabaseEngine.Oracle, SqlTypeCategory.Integer, null)]
    [InlineData("DATE", DatabaseEngine.Oracle, SqlTypeCategory.Timestamp, null)]
    [InlineData("integer[]", DatabaseEngine.PostgreSql, SqlTypeCategory.Other, null)]
    [InlineData("FLOATING POINT", DatabaseEngine.Sqlite, SqlTypeCategory.Integer, null)]
    [InlineData("", DatabaseEngine.Sqlite, SqlTypeCategory.Text, null)]
    [InlineData("STRING", DatabaseEngine.DuckDb, SqlTypeCategory.Text, null)]
    [InlineData("point", DatabaseEngine.PostgreSql, SqlTypeCategory.Other, null)]
    public void ReadsDeclaredTypes(string type, DatabaseEngine engine, SqlTypeCategory category, int? length)
    {
        var shape = SqlTypeShape.Parse(type, engine);

        Assert.Equal(category, shape.Category);
        Assert.Equal(length, shape.Length);
    }

    [Fact]
    public void ReadsTimeZonesSizesAndSigns()
    {
        Assert.True(SqlTypeShape.Parse("timestamp(3) with time zone", DatabaseEngine.PostgreSql).HasTimeZone);
        Assert.False(SqlTypeShape.Parse("timestamp without time zone", DatabaseEngine.PostgreSql).HasTimeZone);
        var unsigned = SqlTypeShape.Parse("int(11) unsigned", DatabaseEngine.MySql);
        Assert.Equal((4, true), (unsigned.IntegerBytes, unsigned.IsUnsigned));
        var money = SqlTypeShape.Parse("numeric(10, 2)", DatabaseEngine.PostgreSql);
        Assert.Equal((10, 2), (money.Precision, money.Scale));
        Assert.Equal((0L, 255L), SqlTypeShape.Parse("tinyint", DatabaseEngine.SqlServer).IntegerRange);
    }

    private static ColumnInfo Column(string name, string type, bool key = false, bool identity = false, string? defaultValue = null, bool nullable = true) =>
        new(name, type, nullable, defaultValue, key, identity, 0);

    private static string TypeOn(string type, DatabaseEngine source, DatabaseEngine target, bool keyed = false) =>
        CopyTypeMapper.Translate(Column("c", type), source, target, null, keyed, writesRows: true).Column.DataType;

    [Fact]
    public void WithinOneFamilyTheTypeIsCopiedAsWritten()
    {
        Assert.Equal("character varying(20)", TypeOn("character varying(20)", DatabaseEngine.PostgreSql, DatabaseEngine.CockroachDb));
        Assert.Equal("enum('a','b')", TypeOn("enum('a','b')", DatabaseEngine.MySql, DatabaseEngine.MariaDb));
        Assert.True(CopyTypeMapper.SharesTypes(DatabaseEngine.Sqlite, DatabaseEngine.LibSql));
        Assert.False(CopyTypeMapper.SharesTypes(DatabaseEngine.Sqlite, DatabaseEngine.PostgreSql));
    }

    [Theory]
    [InlineData("integer", "INT")]
    [InlineData("bigint", "BIGINT")]
    [InlineData("character varying(20)", "VARCHAR(20)")]
    [InlineData("text", "LONGTEXT")]
    [InlineData("numeric(10,2)", "DECIMAL(10,2)")]
    [InlineData("boolean", "TINYINT(1)")]
    [InlineData("jsonb", "JSON")]
    [InlineData("uuid", "CHAR(36)")]
    [InlineData("timestamp with time zone", "DATETIME(6)")]
    [InlineData("bytea", "LONGBLOB")]
    [InlineData("double precision", "DOUBLE")]
    public void PostgresTypesReadAsMySql(string type, string expected) => Assert.Equal(expected, TypeOn(type, DatabaseEngine.PostgreSql, DatabaseEngine.MySql));

    [Theory]
    [InlineData("tinyint(1)", "BOOLEAN")]
    [InlineData("int unsigned", "BIGINT")]
    [InlineData("datetime", "TIMESTAMP")]
    [InlineData("varchar(50)", "VARCHAR(50)")]
    [InlineData("longtext", "TEXT")]
    [InlineData("enum('new','paid')", "VARCHAR(4)")]
    [InlineData("mediumint", "INTEGER")]
    [InlineData("decimal", "NUMERIC")]
    public void MySqlTypesReadAsPostgres(string type, string expected) => Assert.Equal(expected, TypeOn(type, DatabaseEngine.MySql, DatabaseEngine.PostgreSql));

    [Theory]
    [InlineData("INTEGER", DatabaseEngine.SqlServer, "BIGINT")]
    [InlineData("TEXT", DatabaseEngine.SqlServer, "NVARCHAR(MAX)")]
    [InlineData("VARCHAR(30)", DatabaseEngine.SqlServer, "NVARCHAR(30)")]
    [InlineData("REAL", DatabaseEngine.Oracle, "BINARY_DOUBLE")]
    [InlineData("BOOLEAN", DatabaseEngine.Oracle, "VARCHAR2(5 CHAR)")]
    [InlineData("TEXT", DatabaseEngine.DuckDb, "VARCHAR")]
    [InlineData("DATETIME", DatabaseEngine.DuckDb, "TIMESTAMP")]
    public void SqliteTypesReadElsewhere(string type, DatabaseEngine target, string expected) => Assert.Equal(expected, TypeOn(type, DatabaseEngine.Sqlite, target));

    [Fact]
    public void AKeyedTextColumnFitsAnIndex()
    {
        Assert.Equal("VARCHAR(255)", TypeOn("text", DatabaseEngine.PostgreSql, DatabaseEngine.MySql, keyed: true));
        Assert.Equal("NVARCHAR(450)", TypeOn("text", DatabaseEngine.PostgreSql, DatabaseEngine.SqlServer, keyed: true));
    }

    [Fact]
    public void ApproximationsAreNoted()
    {
        var (_, notes) = CopyTypeMapper.Translate(Column("at", "timestamptz"), DatabaseEngine.PostgreSql, DatabaseEngine.MySql, null, false, true);

        Assert.Contains(notes, n => n.Contains("UTC", StringComparison.Ordinal));
    }

    [Fact]
    public void SqlServerIdentityIsDroppedWhenRowsAreCopiedAndSequenceDefaultsBecomeIdentity()
    {
        var (mssql, mssqlNotes) = CopyTypeMapper.Translate(Column("id", "integer", key: true, identity: true), DatabaseEngine.PostgreSql, DatabaseEngine.SqlServer, null, true, writesRows: true);
        var (structureOnly, _) = CopyTypeMapper.Translate(Column("id", "integer", key: true, identity: true), DatabaseEngine.PostgreSql, DatabaseEngine.SqlServer, null, true, writesRows: false);
        var (serial, serialNotes) = CopyTypeMapper.Translate(Column("id", "integer", key: true, defaultValue: "nextval('t_id_seq'::regclass)"), DatabaseEngine.PostgreSql, DatabaseEngine.PostgreSql, null, true, true);

        Assert.False(mssql.IsIdentity);
        Assert.Contains(mssqlNotes, n => n.Contains("IDENTITY", StringComparison.Ordinal));
        Assert.True(structureOnly.IsIdentity);
        Assert.True(serial.IsIdentity);
        Assert.Null(serial.DefaultExpression);
        Assert.Single(serialNotes);
    }

    [Theory]
    [InlineData("'draft'::character varying", "text", DatabaseEngine.MySql, "'draft'")]
    [InlineData("((0))", "int", DatabaseEngine.PostgreSql, "0")]
    [InlineData("now()", "timestamp", DatabaseEngine.SqlServer, "CURRENT_TIMESTAMP")]
    [InlineData("getdate()", "datetime", DatabaseEngine.PostgreSql, "CURRENT_TIMESTAMP")]
    [InlineData("true", "boolean", DatabaseEngine.SqlServer, "1")]
    [InlineData("b'1'", "bit(1)", DatabaseEngine.PostgreSql, "TRUE")]
    [InlineData("N'x''y'", "nvarchar(10)", DatabaseEngine.PostgreSql, "'x''y'")]
    [InlineData("gen_random_uuid()", "uuid", DatabaseEngine.MySql, null)]
    [InlineData("NULL", "text", DatabaseEngine.MySql, null)]
    public void OnlyPortableDefaultsCross(string expression, string type, DatabaseEngine target, string? expected)
    {
        var source = type is "datetime" or "int" or "bit(1)" or "nvarchar(10)" ? DatabaseEngine.SqlServer : DatabaseEngine.PostgreSql;
        var shape = SqlTypeShape.Parse(type, type == "bit(1)" ? DatabaseEngine.MySql : source);

        Assert.Equal(expected, CopyTypeMapper.PortableDefault(expression, shape, target));
    }

    [Fact]
    public void RefusesEnginesWithNoKnownTypeSystem()
    {
        Assert.NotNull(CopyTypeMapper.Refusal(DatabaseEngine.PostgreSql, DatabaseEngine.Snowflake));
        Assert.Null(CopyTypeMapper.Refusal(DatabaseEngine.Snowflake, DatabaseEngine.Snowflake));
        Assert.Null(CopyTypeMapper.Refusal(DatabaseEngine.MySql, DatabaseEngine.SqlServer));
    }

    [Fact]
    public void AdaptsValuesForTheTargetFamily()
    {
        var uuid = Guid.NewGuid();
        var text = new SqlTypeShape(SqlTypeCategory.Text);
        var uuidShape = new SqlTypeShape(SqlTypeCategory.Uuid);

        Assert.Equal(uuid.ToString("D"), CopyValueAdapter.Adapt(uuid, text, TypeFamily.Sqlite, false));
        Assert.Equal(uuid, CopyValueAdapter.Adapt(uuid, uuidShape, TypeFamily.PostgreSql, false));
        Assert.Equal(new DateTime(2024, 1, 1, 10, 0, 0, DateTimeKind.Utc), CopyValueAdapter.Adapt(new DateTimeOffset(2024, 1, 1, 12, 0, 0, TimeSpan.FromHours(2)), new SqlTypeShape(SqlTypeCategory.Timestamp), TypeFamily.MySql, false));
        Assert.Equal(7L, CopyValueAdapter.Adapt(7u, text, TypeFamily.MySql, false));
        Assert.Equal(uuid, CopyValueAdapter.Adapt(uuid, text, TypeFamily.Sqlite, sharesTypes: true));
        Assert.Null(CopyValueAdapter.Adapt(DBNull.Value, text, TypeFamily.MySql, false));
    }

    [Fact]
    public void RetargetsSchemaQualifiersOnly()
    {
        const string view = "CREATE VIEW public.v AS SELECT 'public.x' AS s, p.id FROM \"public\".t p -- public.t\nJOIN public . u ON true";

        var moved = DefinitionRetargeter.Retarget(view, PostgreSqlDialect.Instance, "public", "archive");
        var dropped = DefinitionRetargeter.Retarget("CREATE VIEW `shop`.`v` AS SELECT * FROM `shop`.`t`", MySqlDialect.Instance, "shop", null);

        Assert.Equal("CREATE VIEW \"archive\".v AS SELECT 'public.x' AS s, p.id FROM \"archive\".t p -- public.t\nJOIN \"archive\" . u ON true", moved);
        Assert.Equal("CREATE VIEW `v` AS SELECT * FROM `t`", dropped);
    }
}
