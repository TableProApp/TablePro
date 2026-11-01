using TablePro.Core.Schema;
using TablePro.Core.Sql;

namespace TablePro.Drivers.Odbc.Tests;

public sealed class OdbcSharedTests
{
    [Theory]
    [InlineData("plain", "plain")]
    [InlineData("a;b", "{a;b}")]
    [InlineData("a}b", "{a}}b}")]
    [InlineData("{start", "{{start}")]
    [InlineData("k=v", "{k=v}")]
    [InlineData(" lead", "{ lead}")]
    [InlineData("DM8 ODBC DRIVER", "{DM8 ODBC DRIVER}")]
    [InlineData("", "{}")]
    public void EscapeBracesWhatTheDriverManagerWouldSplit(string value, string expected) =>
        Assert.Equal(expected, OdbcConnectionString.Escape(value));

    [Fact]
    public void AnEscapedPasswordReadsBackWholeAndAddsNoKeyword()
    {
        const string hostile = "x};UID=root;PWD={y";
        var text = new OdbcConnectionString().Set("UID", "app").Set("PWD", hostile).ToString();

        var pairs = Profiles.Parse(text);

        Assert.Equal(2, pairs.Count);
        Assert.Equal("app", pairs["UID"]);
        Assert.Equal(hostile, pairs["PWD"]);
    }

    [Theory]
    [InlineData("")]
    [InlineData(" KEY")]
    [InlineData("A=B")]
    [InlineData("A;B")]
    [InlineData("A{B")]
    [InlineData("A@B")]
    public void ReservedCharactersAreRefusedInKeys(string key) =>
        Assert.Throws<ArgumentException>(() => new OdbcConnectionString().Set(key, "v"));

    [Fact]
    public void SetReplacesAKeyWhateverItsCase()
    {
        var text = new OdbcConnectionString().Set("Encrypt", "FALSE").Set("ENCRYPT", "TRUE").ToString();

        Assert.Equal("Encrypt=TRUE;", text);
    }

    [Fact]
    public void PassThroughSkipsConsumedOptionsAndRefusesManagedKeys()
    {
        var options = new Dictionary<string, string> { ["odbcDriver"] = "X", ["CHAR_CODE"] = "PG_UTF8" };
        var connection = new OdbcConnectionString();

        connection.AddPassThrough(options, ["odbcDriver"], ["UID"]);

        Assert.Equal("CHAR_CODE=PG_UTF8;", connection.ToString());
        Assert.Throws<ArgumentException>(() => connection.AddPassThrough(new Dictionary<string, string> { ["uid"] = "root" }, [], ["UID"]));
    }

    [Fact]
    public void NamedMarkersBecomeQuestionMarksInMarkerOrder()
    {
        var spec = new SqlCommandSpec(
            "UPDATE \"T\" SET \"A\" = :p0, \"B\" = ':p1' WHERE \"ID\" = :p1 AND \"X\" = :p10",
            [new(":p0", "a"), new(":p1", 7), new(":p10", "ten")]);

        var bound = OdbcParameters.Bind(spec, OracleDialect.Instance);

        Assert.Equal("UPDATE \"T\" SET \"A\" = ?, \"B\" = ':p1' WHERE \"ID\" = ? AND \"X\" = ?", bound.Text);
        Assert.Equal(["a", 7, "ten"], bound.Values);
    }

    [Fact]
    public void ANameUsedTwiceBindsTwice()
    {
        var spec = new SqlCommandSpec("SELECT :p0, :p0", [new(":p0", 1)]);

        var bound = OdbcParameters.Bind(spec, OracleDialect.Instance);

        Assert.Equal("SELECT ?, ?", bound.Text);
        Assert.Equal([1, 1], bound.Values);
    }

    [Fact]
    public void PositionalDialectsPassThroughInOrder()
    {
        var spec = new SqlCommandSpec("DELETE FROM \"T\" WHERE \"A\" = ? AND \"B\" = ?", [new("?", 1), new("?", "two")]);

        var bound = OdbcParameters.Bind(spec, HanaDialect.Instance);

        Assert.Same(spec.Text, bound.Text);
        Assert.Equal([1, "two"], bound.Values);
    }

    [Fact]
    public void CoreBrowseFiltersBindOverOdbc()
    {
        var filter = new Core.Browse.BrowseFilter([new Core.Browse.FilterRule("NAME", Core.Browse.FilterOperator.Equals, "o'brien")]);
        var spec = OracleDialect.Instance.BuildBrowse(new Core.Browse.BrowseRequest(new ObjectName("S", "T"), filter, [], 0, 50));

        var bound = OdbcParameters.Bind(spec, OracleDialect.Instance);

        Assert.DoesNotContain(":p", bound.Text, StringComparison.Ordinal);
        Assert.Equal(spec.Parameters.Count, bound.Values.Count);
        Assert.Equal(bound.Values.Count, bound.Text.Count(c => c == '?'));
    }

    [Fact]
    public void PreviewWritesEachPositionalValueAsALiteral()
    {
        var preview = OdbcParameters.Preview(new OdbcStatement("UPDATE \"T\" SET \"A\" = ?, \"B\" = '?' WHERE \"ID\" = ?", ["it's", 3]), HanaDialect.Instance);

        Assert.Equal("UPDATE \"T\" SET \"A\" = 'it''s', \"B\" = '?' WHERE \"ID\" = 3", preview);
    }

    [Fact]
    public void ValuesOdbcCannotBindTravelAsTheNearestType()
    {
        Assert.Equal(System.Data.Odbc.OdbcType.Date, OdbcParameters.Parameter(new DateOnly(2024, 2, 29)).OdbcType);
        Assert.Equal(new DateTime(2024, 2, 29), OdbcParameters.Parameter(new DateOnly(2024, 2, 29)).Value);
        Assert.Equal(System.Data.Odbc.OdbcType.Time, OdbcParameters.Parameter(new TimeOnly(13, 5)).OdbcType);
        Assert.Equal("0f8fad5b-d9cb-469f-a165-70867728950e", OdbcParameters.Parameter(Guid.Parse("0f8fad5b-d9cb-469f-a165-70867728950e")).Value);
        Assert.Equal(4_000_000_000L, OdbcParameters.Parameter(4_000_000_000U).Value);
        Assert.Equal(DBNull.Value, OdbcParameters.Parameter(null).Value);
        Assert.Equal("2024-01-02 03:04:05 +02:00", OdbcParameters.Parameter(new DateTimeOffset(2024, 1, 2, 3, 4, 5, TimeSpan.FromHours(2))).Value);
    }

    [Theory]
    [InlineData(
        "ERROR [42S02] [SAP AG][LIBODBCHDB DLL][HDBODBC] Base table or view not found;259 invalid table name:  Could not find table/view T in schema S",
        "invalid table name:  Could not find table/view T in schema S (error 259)")]
    [InlineData("ERROR [HY000] [DM][ODBC DM8 DRIVER]Invalid table or view name [T]", "Invalid table or view name [T]")]
    [InlineData("plain message", "plain message")]
    public void CleanRemovesTheDriverManagersDecoration(string raw, string expected) =>
        Assert.Equal(expected, OdbcErrors.Clean(raw));

    [Fact]
    public void CleanKeepsEachDistinctDiagnosticOnItsOwnLine()
    {
        var raw = "ERROR [01000] [X][Y] first\r\nERROR [01000] [X][Y] first\r\nERROR [HY000] [X] second";

        Assert.Equal("first\nsecond", OdbcErrors.Clean(raw));
    }

    [Theory]
    [InlineData("TRUE", true)]
    [InlineData("false", false)]
    [InlineData("Y", true)]
    [InlineData("N", false)]
    [InlineData(null, false)]
    public void FlagsReadBothEnginesSpellings(string? value, bool expected) => Assert.Equal(expected, CatalogValues.Flag(value));

    [Fact]
    public void NumbersReadWhateverTypeTheDriverReturned()
    {
        Assert.Equal(42L, CatalogValues.Int64(42m));
        Assert.Equal(42L, CatalogValues.Int64(" 42 "));
        Assert.Null(CatalogValues.Int64("n/a"));
        Assert.Equal(7, CatalogValues.Int32((short)7));
        Assert.Null(CatalogValues.Int32(long.MaxValue));
    }
}
